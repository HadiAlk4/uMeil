import Foundation
import os
import Testing
@testable import uMeil

/// These run real processes through the real `StreamingProcessRunner`.
struct StreamingProcessRunnerTests {
    private let shell = URL(filePath: "/bin/sh")

    /// Collects lines from whatever thread reports them.
    private final class Lines: Sendable {
        private let collected = OSAllocatedUnfairLock(initialState: [String]())
        var all: [String] { collected.withLock { $0 } }
        func add(_ line: String) { collected.withLock { $0.append(line) } }
    }

    @Test func reportsEachLineAndTheExitCode() async throws {
        let lines = Lines()

        let output = try await StreamingProcessRunner().run(
            shell,
            arguments: ["-c", "echo one; echo two; exit 3"],
            currentDirectory: nil
        ) { lines.add($0) }

        #expect(lines.all == ["one", "two"])
        #expect(output.exitCode == 3)
        #expect(output.standardOutput == "one\ntwo\n")
    }

    @Test func reportsLinesFromBothStreams() async throws {
        let lines = Lines()

        let output = try await StreamingProcessRunner().run(
            shell,
            arguments: ["-c", "echo out; echo err >&2"],
            currentDirectory: nil
        ) { lines.add($0) }

        #expect(lines.all.sorted() == ["err", "out"])
        #expect(output.standardOutput == "out\n")
        #expect(output.standardError == "err\n")
    }

    @Test func reportsALastLineWithNoNewline() async throws {
        let lines = Lines()

        _ = try await StreamingProcessRunner().run(
            shell,
            arguments: ["-c", "printf 'first\\r\\nlast'"],
            currentDirectory: nil
        ) { lines.add($0) }

        #expect(lines.all == ["first", "last"])
    }

    @Test func reportsLinesWhileTheProcessIsStillRunning() async throws {
        // When each line was reported. Measured between the two lines, not
        // from launch: starting a process can take a while on a busy machine.
        let arrivals = OSAllocatedUnfairLock(initialState: [String: Date]())

        _ = try await StreamingProcessRunner().run(
            shell,
            arguments: ["-c", "echo early; sleep 1; echo late"],
            currentDirectory: nil
        ) { line in
            arrivals.withLock { $0[line] = Date() }
        }

        let early = try #require(arrivals.withLock { $0["early"] })
        let late = try #require(arrivals.withLock { $0["late"] })
        // A runner that waited for the process to exit would report both
        // lines together. The process sleeps a second between them.
        #expect(late.timeIntervalSince(early) > 0.5)
    }

    @Test func runsInTheGivenFolder() async throws {
        let folder = try TemporaryFolder()
        let lines = Lines()

        _ = try await StreamingProcessRunner().run(
            shell,
            arguments: ["-c", "pwd -P"],
            currentDirectory: folder.url
        ) { lines.add($0) }

        #expect(lines.all.map { URL(filePath: $0).lastPathComponent } == [folder.url.lastPathComponent])
    }

    @Test func throwsWhenTheToolCannotBeStarted() async {
        await #expect(throws: (any Error).self) {
            try await StreamingProcessRunner().run(
                URL(filePath: "/nonexistent/tool"),
                arguments: [],
                currentDirectory: nil
            ) { _ in }
        }
    }

    @Test func cancellingTheTaskStopsTheProcess() async throws {
        let started = Date()
        let lines = Lines()
        let task = Task {
            try await StreamingProcessRunner().run(
                shell,
                // `exec` so the signal goes to `sleep` itself, not a shell waiting on it.
                arguments: ["-c", "echo started; exec sleep 300"],
                currentDirectory: nil
            ) { lines.add($0) }
        }

        while lines.all.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let output = try await task.value

        // Far less than the 300 seconds `sleep` would take on its own.
        #expect(Date().timeIntervalSince(started) < TestTiming.seconds(10))
        #expect(output.exitCode != 0)
        #expect(output.standardOutput == "started\n")
    }

    @Test func aTaskCancelledBeforeItStartsStopsStraightAway() async throws {
        let started = Date()
        let task = Task {
            // Give the cancellation below time to land first.
            try? await Task.sleep(for: .seconds(60))
            return try await StreamingProcessRunner().run(
                shell,
                arguments: ["-c", "exec sleep 300"],
                currentDirectory: nil
            ) { _ in }
        }
        task.cancel()

        let output = try await task.value

        // Far less than the 300 seconds `sleep` would take on its own.
        #expect(Date().timeIntervalSince(started) < TestTiming.seconds(10))
        #expect(output.exitCode != 0)
    }

    @Test func pipeLineReaderRespectsCollectAllAndMaximumBytes() async throws {
        let pipe = Pipe()
        let lines = Lines()
        let finalText = OSAllocatedUnfairLock<String?>(initialState: nil)

        PipeLineReader.start(
            pipe.fileHandleForReading,
            collectAll: false,
            onLine: { lines.add($0) },
            onEnd: { text in finalText.withLock { $0 = text } }
        )
        try pipe.fileHandleForWriting.write(contentsOf: Data("first\nsecond\n".utf8))
        try pipe.fileHandleForWriting.close()

        while finalText.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(lines.all == ["first", "second"])
        #expect(finalText.withLock { $0 } == "")

        let cappedPipe = Pipe()
        let cappedLines = Lines()
        let cappedText = OSAllocatedUnfairLock<String?>(initialState: nil)

        PipeLineReader.start(
            cappedPipe.fileHandleForReading,
            collectAll: true,
            maximumBytes: 8,
            onLine: { cappedLines.add($0) },
            onEnd: { text in cappedText.withLock { $0 = text } }
        )
        try cappedPipe.fileHandleForWriting.write(contentsOf: Data("12345\n67890\n".utf8))
        try cappedPipe.fileHandleForWriting.close()

        while cappedText.withLock({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cappedLines.all == ["12345", "67890"])
        #expect(cappedText.withLock { $0 } == "12345\n67")
    }

    @Test func processRunnerCapsStdoutAndStderrWithoutDeadlocking() async throws {
        let runner = ProcessRunner(maximumOutputBytes: 1024)
        let output = try await runner.run(
            shell,
            arguments: [
                "-c",
                "head -c 5000 /dev/zero | tr '\\0' 'A'; head -c 5000 /dev/zero | tr '\\0' 'B' >&2"
            ]
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.utf8.count == 1024)
        #expect(output.standardError.utf8.count == 1024)
    }
}
