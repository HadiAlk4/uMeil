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
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.runBlocking(
                            executable,
                            arguments: arguments,
                            currentDirectory: currentDirectory,
                            handle: handle,
                            onLine: onLine
                        )
                    })
                }
            }
        } onCancel: {
            handle.stop()
        }
    }

    private static func runBlocking(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        handle: ProcessHandle,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> ProcessOutput {
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

        try process.run()
        handle.started(process)

        // Read both streams at once, each on its own thread, so that neither
        // pipe fills up while the other is being read.
        let errorText = OSAllocatedUnfairLock(initialState: "")
        let errorDrained = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: errorDrained) {
            let text = readLines(from: errorPipe.fileHandleForReading, onLine: onLine)
            errorText.withLock { $0 = text }
        }
        let outputText = readLines(from: outputPipe.fileHandleForReading, onLine: onLine)
        errorDrained.wait()
        process.waitUntilExit()

        return ProcessOutput(
            exitCode: process.terminationStatus,
            standardOutput: outputText,
            standardError: errorText.withLock { $0 }
        )
    }

    /// Reads `file` to its end, calling `onLine` as each line completes.
    /// Returns everything that was read.
    private static func readLines(from file: FileHandle, onLine: (String) -> Void) -> String {
        var all = Data()
        var pending = Data()
        let newline = UInt8(ascii: "\n")

        while true {
            let chunk = file.availableData
            if chunk.isEmpty { break } // End of file: the process closed its end.
            all.append(chunk)
            pending.append(chunk)
            while let end = pending.firstIndex(of: newline) {
                onLine(text(from: pending[pending.startIndex..<end]))
                pending.removeSubrange(pending.startIndex...end)
            }
        }
        if !pending.isEmpty {
            onLine(text(from: pending))
        }
        return text(from: all)
    }

    /// Decodes tool output as UTF-8, replacing any invalid bytes, and drops
    /// the carriage return of a Windows-style line ending.
    private static func text(from data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        return text.hasSuffix("\r") ? String(text.dropLast()) : text
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
