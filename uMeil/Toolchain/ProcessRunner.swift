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
    func run(_ executable: URL, arguments: [String], currentDirectory: URL?) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.runBlocking(executable, arguments: arguments, currentDirectory: currentDirectory)
                })
            }
        }
    }

    private static func runBlocking(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL?
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

        // Drain standard error on another thread while this one drains
        // standard output. Reading them one after the other can deadlock if
        // the process fills the pipe that is not being read.
        let errorData = OSAllocatedUnfairLock(initialState: Data())
        let errorDrained = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: errorDrained) {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorData.withLock { $0 = data }
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        errorDrained.wait()
        process.waitUntilExit()

        return ProcessOutput(
            exitCode: process.terminationStatus,
            standardOutput: text(from: outputData),
            standardError: text(from: errorData.withLock { $0 })
        )
    }

    /// Decodes tool output as UTF-8, replacing any invalid bytes. A failable
    /// conversion would throw away the whole output over one bad byte, which
    /// is worse for compiler messages that may quote arbitrary source text.
    private static func text(from data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
    }
}
