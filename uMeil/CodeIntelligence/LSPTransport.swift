import Darwin
import Foundation
import os

/// Byte-level transport carrying framed JSON-RPC messages to and from a language server.
/// Abstracted so `LSPClient` can be tested with an in-memory fake transport.
protocol LSPTransporting: Sendable {
    var incoming: AsyncStream<Data> { get }
    func send(_ payload: Data) async throws
    func close() async
}

enum LSPTransportError: Error, Equatable, LocalizedError {
    case closed

    var errorDescription: String? {
        switch self {
        case .closed: "The language server connection is closed."
        }
    }
}

/// Runs a local language server process (such as `clangd`) over stdin/stdout pipes.
final class ProcessLSPTransport: LSPTransporting, @unchecked Sendable {
    let incoming: AsyncStream<Data>

    private struct State {
        var process: Process?
        var writeHandle: FileHandle?
        var stdoutHandle: FileHandle?
        var stderrHandle: FileHandle?
        var framer = LSPFraming.MessageBuffer()
        var stderrTail = Data()
        var isClosed = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let writeQueue = DispatchQueue(label: "io.github.hadialkhub.uMeil.lsp.write")
    private let continuation: AsyncStream<Data>.Continuation

    // Ignore SIGPIPE so a crashing language server returns a Swift error on write
    // instead of terminating the IDE process.
    private static let ignoreSigpipe: Void = {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
    }()

    init(executable: URL, arguments: [String], currentDirectory: URL?) throws {
        _ = Self.ignoreSigpipe

        var streamContinuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let stdoutHandle = outputPipe.fileHandleForReading
        let stderrHandle = errorPipe.fileHandleForReading

        state.withLockUnchecked { state in
            state.process = process
            state.writeHandle = inputPipe.fileHandleForWriting
            state.stdoutHandle = stdoutHandle
            state.stderrHandle = stderrHandle
        }

        // Event-driven readability handlers avoid tying up GCD global worker threads
        // while idle, preventing thread-pool starvation under concurrent sessions.
        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.handleStdoutReadable(handle)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            self?.handleStderrReadable(handle)
        }
    }

    deinit {
        closeSynchronously()
    }

    /// The last few kilobytes printed to standard error, for diagnostics if the server exits.
    var recentStandardError: String {
        state.withLockUnchecked { state in
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: state.stderrTail, as: UTF8.self)
        }
    }

    func send(_ payload: Data) async throws {
        let packet = LSPFraming.encode(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: LSPTransportError.closed)
                    return
                }
                let handle: FileHandle? = state.withLockUnchecked { state in
                    state.isClosed ? nil : state.writeHandle
                }
                guard let handle else {
                    continuation.resume(throwing: LSPTransportError.closed)
                    return
                }
                do {
                    try handle.write(contentsOf: packet)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        closeSynchronously()
    }

    private func closeSynchronously() {
        struct ClosedResources {
            let process: Process?
            let writeHandle: FileHandle?
            let stdoutHandle: FileHandle?
            let stderrHandle: FileHandle?
        }

        let resources: ClosedResources? = state.withLockUnchecked { state in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            let resources = ClosedResources(
                process: state.process,
                writeHandle: state.writeHandle,
                stdoutHandle: state.stdoutHandle,
                stderrHandle: state.stderrHandle
            )
            state.process = nil
            state.writeHandle = nil
            state.stdoutHandle = nil
            state.stderrHandle = nil
            return resources
        }
        guard let resources else { return }

        resources.stdoutHandle?.readabilityHandler = nil
        resources.stderrHandle?.readabilityHandler = nil
        try? resources.writeHandle?.close()
        try? resources.stdoutHandle?.close()
        try? resources.stderrHandle?.close()
        if let process = resources.process, process.isRunning {
            process.terminate()
        }
        continuation.finish()
    }

    private func handleStdoutReadable(_ handle: FileHandle) {
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            try? handle.close()
            continuation.finish()
            return
        }

        enum Outcome {
            case payloads([Data])
            case failed
        }
        let outcome: Outcome = state.withLockUnchecked { state in
            guard !state.isClosed else { return .failed }
            do {
                return .payloads(try state.framer.append(chunk))
            } catch {
                return .failed
            }
        }

        switch outcome {
        case .payloads(let messages):
            for message in messages {
                continuation.yield(message)
            }
        case .failed:
            handle.readabilityHandler = nil
            try? handle.close()
            continuation.finish()
        }
    }

    private func handleStderrReadable(_ handle: FileHandle) {
        let chunk = handle.availableData
        if chunk.isEmpty {
            handle.readabilityHandler = nil
            try? handle.close()
            return
        }
        let maxBytes = 8192
        state.withLockUnchecked { state in
            state.stderrTail.append(chunk)
            if state.stderrTail.count > maxBytes {
                state.stderrTail = Data(state.stderrTail.suffix(maxBytes))
            }
        }
    }
}
