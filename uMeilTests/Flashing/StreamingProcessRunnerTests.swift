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
        let firstLineArrived = OSAllocatedUnfairLock(initialState: Date?.none)
        let started = Date()

        _ = try await StreamingProcessRunner().run(
            shell,
            arguments: ["-c", "echo early; sleep 1; echo late"],
            currentDirectory: nil
        ) { line in
            if line == "early" {
                firstLineArrived.withLock { $0 = Date() }
            }
        }

        let arrived = try #require(firstLineArrived.withLock { $0 })
        // Well before the process finished, a second later.
        #expect(arrived.timeIntervalSince(started) < 0.7)
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
                arguments: ["-c", "echo started; exec sleep 30"],
                currentDirectory: nil
            ) { lines.add($0) }
        }

        while lines.all.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let output = try await task.value

        #expect(Date().timeIntervalSince(started) < 10)
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
                arguments: ["-c", "exec sleep 30"],
                currentDirectory: nil
            ) { _ in }
        }
        task.cancel()

        let output = try await task.value

        #expect(Date().timeIntervalSince(started) < 10)
        #expect(output.exitCode != 0)
    }
}
