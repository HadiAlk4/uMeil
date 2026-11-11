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
    func run(_ executable: URL, arguments: [String]) async throws -> ProcessOutput
}

/// Runs a real process and collects everything it prints.
struct ProcessRunner: ProcessRunning {
    func run(_ executable: URL, arguments: [String]) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.runBlocking(executable, arguments: arguments) })
            }
        }
    }

    private static func runBlocking(_ executable: URL, arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
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
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData.withLock { $0 }, as: UTF8.self)
        )
    }
}
