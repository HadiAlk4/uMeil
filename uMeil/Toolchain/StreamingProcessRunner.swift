import Foundation
import os

/// Runs external tools and reports what they print while they are still
/// running. A protocol so tests can substitute canned output.
protocol LineStreamingProcessRunning: Sendable {
    /// Runs `executable` and waits for it to exit, calling `onLine` for each
    /// complete line it prints to either stream. `onLine` is called from a
    /// background thread.
    ///
    /// Cancelling the task that called this stops the process; the output
    /// collected so far is still returned.
    func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessOutput
}

/// Runs a real process, passing on its output line by line.
struct StreamingProcessRunner: LineStreamingProcessRunning {
    func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessOutput {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Both streams are read as data arrives, so no thread is held
                // for as long as the tool runs.
                let result = StreamingResult(continuation: continuation)
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let process = Self.makeProcess(
                    executable,
                    arguments: arguments,
                    currentDirectory: currentDirectory,
                    output: outputPipe,
                    error: errorPipe
                )
                process.terminationHandler = { result.exited($0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    result.fail(error)
                    return
                }
                handle.started(process)

                PipeLineReader.start(outputPipe.fileHandleForReading, onLine: onLine) { result.outputEnded($0) }
                PipeLineReader.start(errorPipe.fileHandleForReading, onLine: onLine) { result.errorEnded($0) }
            }
        } onCancel: {
            handle.stop()
        }
    }

    private static func makeProcess(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        output outputPipe: Pipe,
        error errorPipe: Pipe
    ) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        return process
    }
}

/// Collects the exit code and both streams, and resumes the waiting task
/// once all three are in.
private final class StreamingResult: Sendable {
    private struct State {
        var exitCode: Int32?
        var standardOutput: String?
        var standardError: String?
        var isFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let continuation: CheckedContinuation<ProcessOutput, Error>

    init(continuation: CheckedContinuation<ProcessOutput, Error>) {
        self.continuation = continuation
    }

    func exited(_ code: Int32) { finishIfReady { $0.exitCode = code } }
    func outputEnded(_ text: String) { finishIfReady { $0.standardOutput = text } }
    func errorEnded(_ text: String) { finishIfReady { $0.standardError = text } }

    func fail(_ error: Error) {
        let shouldResume = state.withLock { state -> Bool in
            defer { state.isFinished = true }
            return !state.isFinished
        }
        if shouldResume {
            continuation.resume(throwing: error)
        }
    }

    private func finishIfReady(_ update: @Sendable (inout State) -> Void) {
        let output: ProcessOutput? = state.withLock { state in
            update(&state)
            guard !state.isFinished,
                  let exitCode = state.exitCode,
                  let standardOutput = state.standardOutput,
                  let standardError = state.standardError
            else { return nil }
            state.isFinished = true
            return ProcessOutput(exitCode: exitCode, standardOutput: standardOutput, standardError: standardError)
        }
        if let output {
            continuation.resume(returning: output)
        }
    }
}

/// Lets the task that is waiting for a process stop it from another thread.
private final class ProcessHandle: Sendable {
    private struct State {
        var process: Process?
        var isStopped = false
    }

    // `Process` is not `Sendable`, but `terminate()` may be called from any
    // thread, and the lock makes sure only one thread touches it at a time.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// Records the running process. If `stop()` was already called, the
    /// process is stopped straight away.
    func started(_ process: Process) {
        state.withLockUnchecked { state in
            state.process = process
            if state.isStopped {
                process.terminate()
            }
        }
    }

    func stop() {
        state.withLockUnchecked { state in
            state.isStopped = true
            if let process = state.process, process.isRunning {
                process.terminate()
            }
        }
    }
}
