import Foundation
import os

/// What a finished process left behind.
struct ProcessOutput: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String

    /// Both streams joined. Some tools (OpenOCD) print their version to
    /// standard error, so callers that only want "the text" use this.
    var combinedOutput: String { standardOutput + standardError }
}

/// Runs external tools. A protocol so tests can substitute canned output.
protocol ProcessRunning: Sendable {
    /// Runs `executable` and waits for it to exit. `currentDirectory` is the
    /// folder relative paths in `arguments` are resolved against; `nil`
    /// keeps the app's own.
    func run(_ executable: URL, arguments: [String], currentDirectory: URL?) async throws -> ProcessOutput
}

extension ProcessRunning {
    func run(_ executable: URL, arguments: [String]) async throws -> ProcessOutput {
        try await run(executable, arguments: arguments, currentDirectory: nil)
    }
}

/// Runs a real process and collects everything it prints.
struct ProcessRunner: ProcessRunning {
    static let defaultMaximumOutputBytes = 32 * 1024 * 1024

    var maximumOutputBytes: Int = defaultMaximumOutputBytes

    func run(_ executable: URL, arguments: [String], currentDirectory: URL?) async throws -> ProcessOutput {
        let cap = max(0, maximumOutputBytes)
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            if let currentDirectory {
                process.currentDirectoryURL = currentDirectory
            }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let stdoutHandle = outputPipe.fileHandleForReading
            let stderrHandle = errorPipe.fileHandleForReading
            let capture = ProcessCapture(
                stdoutHandle: stdoutHandle,
                stderrHandle: stderrHandle,
                maximumBytes: cap,
                continuation: continuation
            )

            process.terminationHandler = { terminated in
                capture.markExited(terminated.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                capture.fail(error)
                return
            }

            // Event-driven pipe reads avoid blocking GCD global worker threads
            // under heavy concurrent build and toolchain load.
            stdoutHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    capture.markStdoutClosed()
                } else {
                    capture.appendStdout(chunk)
                }
            }
            stderrHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    capture.markStderrClosed()
                } else {
                    capture.appendStderr(chunk)
                }
            }
        }
    }
}

private final class ProcessCapture: @unchecked Sendable {
    private struct State {
        var stdout = Data()
        var stderr = Data()
        var stdoutClosed = false
        var stderrClosed = false
        var exitCode: Int32?
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let maximumBytes: Int
    private let continuation: CheckedContinuation<ProcessOutput, Error>

    init(
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        maximumBytes: Int,
        continuation: CheckedContinuation<ProcessOutput, Error>
    ) {
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.maximumBytes = maximumBytes
        self.continuation = continuation
    }

    func appendStdout(_ data: Data) {
        state.withLockUnchecked { state in
            let remaining = maximumBytes - state.stdout.count
            if remaining > 0 {
                state.stdout.append(data.prefix(remaining))
            }
        }
    }

    func appendStderr(_ data: Data) {
        state.withLockUnchecked { state in
            let remaining = maximumBytes - state.stderr.count
            if remaining > 0 {
                state.stderr.append(data.prefix(remaining))
            }
        }
    }

    func markStdoutClosed() {
        stdoutHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        finishIfReady { $0.stdoutClosed = true }
    }

    func markStderrClosed() {
        stderrHandle.readabilityHandler = nil
        try? stderrHandle.close()
        finishIfReady { $0.stderrClosed = true }
    }

    func markExited(_ code: Int32) {
        finishIfReady { $0.exitCode = code }
    }

    func fail(_ error: Error) {
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let shouldResume = state.withLockUnchecked { state -> Bool in
            guard !state.finished else { return false }
            state.finished = true
            return true
        }
        if shouldResume {
            continuation.resume(throwing: error)
        }
    }

    private func finishIfReady(_ update: (inout State) -> Void) {
        let output: ProcessOutput? = state.withLockUnchecked { state in
            update(&state)
            guard !state.finished,
                  state.stdoutClosed,
                  state.stderrClosed,
                  let exitCode = state.exitCode
            else { return nil }
            state.finished = true
            return ProcessOutput(
                exitCode: exitCode,
                // swiftlint:disable:next optional_data_string_conversion
                standardOutput: String(decoding: state.stdout, as: UTF8.self),
                // swiftlint:disable:next optional_data_string_conversion
                standardError: String(decoding: state.stderr, as: UTF8.self)
            )
        }
        if let output {
            continuation.resume(returning: output)
        }
    }
}
