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
        var isClosed = false
        var stderrTail = Data()
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let writeQueue = DispatchQueue(label: "io.github.hadialk4.uMeil.lsp.write")
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

        state.withLockUnchecked { state in
            state.process = process
            state.writeHandle = inputPipe.fileHandleForWriting
        }

        // Drain stdout and stderr concurrently so neither pipe ever blocks clangd.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readStdoutLoop(from: outputPipe.fileHandleForReading)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.drainStderrLoop(from: errorPipe.fileHandleForReading)
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
        let resources: (Process?, FileHandle?) = state.withLockUnchecked { state in
            guard !state.isClosed else { return (nil, nil) }
            state.isClosed = true
            let process = state.process
            let handle = state.writeHandle
            state.process = nil
            state.writeHandle = nil
            return (process, handle)
        }

        try? resources.1?.close()
        if let process = resources.0, process.isRunning {
            process.terminate()
        }
        continuation.finish()
    }

    private func readStdoutLoop(from handle: FileHandle) {
        var framer = LSPFraming.MessageBuffer()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            do {
                for message in try framer.append(chunk) {
                    continuation.yield(message)
                }
            } catch {
                break
            }
        }
        try? handle.close()
        continuation.finish()
    }

    private func drainStderrLoop(from handle: FileHandle) {
        let maxBytes = 8192
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            state.withLockUnchecked { state in
                state.stderrTail.append(chunk)
                if state.stderrTail.count > maxBytes {
                    state.stderrTail = Data(state.stderrTail.suffix(maxBytes))
                }
            }
        }
        try? handle.close()
    }
}
