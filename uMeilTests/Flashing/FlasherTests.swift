import Foundation
import Testing
@testable import uMeil

struct FlasherTests {
    /// A plan for an image that exists, in a scratch folder.
    private func makePlan(in folder: TemporaryFolder, openOCD: URL? = nil) throws -> FlashPlan {
        let image = folder.url.appending(path: "Blinky.elf")
        try Data("not really firmware".utf8).write(to: image)
        return FlashPlan(
            openOCD: openOCD ?? URL(filePath: "/tools/bin/openocd"),
            image: image,
            chip: .tm4c1294ncpdt
        )
    }

    // MARK: - With canned output

    @Test func aSuccessfulFlashReportsEveryStageInOrder() async throws {
        let folder = try TemporaryFolder()
        let plan = try makePlan(in: folder)
        let openOCD = FakeOpenOCD(log: FlashLog.success)
        let recorder = StageRecorder()

        let result = await Flasher(runner: openOCD).flash(plan) { recorder.record($0) }

        #expect(result.succeeded)
        #expect(result.failure == nil)
        #expect(result.bytesWritten == 16384)
        #expect(recorder.stages == [.connecting, .connected, .writing, .verifying, .resetting, .done])
        #expect(openOCD.calls.withLock { $0 } == [plan.arguments])
    }

    @Test func theLogShowsTheCommandAndItsOutput() async throws {
        let folder = try TemporaryFolder()
        let plan = try makePlan(in: folder)

        let result = await Flasher(runner: FakeOpenOCD(log: FlashLog.success)).flash(plan) { _ in }

        #expect(result.log.hasPrefix(
            "$ openocd -f board/ek-tm4c1294xl.cfg -c bindto localhost -c gdb_port disabled"
                + " -c telnet_port disabled -c tcl_port disabled -c init "
        ))
        #expect(result.log.hasSuffix(FlashLog.success))
    }

    @Test func noBoardStopsAtConnecting() async throws {
        let folder = try TemporaryFolder()
        let plan = try makePlan(in: folder)
        let recorder = StageRecorder()

        let result = await Flasher(runner: FakeOpenOCD(log: FlashLog.noBoard, exitCode: 1))
            .flash(plan) { recorder.record($0) }

        #expect(result.failure == .boardNotConnected)
        #expect(result.bytesWritten == nil)
        #expect(recorder.stages == [.connecting])
    }

    @Test func theWrongChipIsReportedAndNothingIsWritten() async throws {
        let folder = try TemporaryFolder()
        let plan = try makePlan(in: folder)
        let recorder = StageRecorder()

        let result = await Flasher(runner: FakeOpenOCD(log: FlashLog.wrongChip, exitCode: 1))
            .flash(plan) { recorder.record($0) }

        #expect(result.failure == .wrongChip(found: "TM4C123GH6PM", expected: .tm4c1294ncpdt))
        #expect(!recorder.stages.contains(.writing))
    }

    @Test func aFailedVerifyIsReportedWithWhatWasWritten() async throws {
        let folder = try TemporaryFolder()
        let plan = try makePlan(in: folder)

        let result = await Flasher(runner: FakeOpenOCD(log: FlashLog.verifyFailed, exitCode: 1)).flash(plan) { _ in }

        #expect(result.failure == .verifyFailed)
        #expect(result.bytesWritten == 16384)
    }

    @Test func aMissingImageIsReportedWithoutRunningOpenOCD() async throws {
        let folder = try TemporaryFolder()
        var plan = try makePlan(in: folder)
        plan.image = folder.url.appending(path: "Missing.elf")
        let openOCD = FakeOpenOCD(log: FlashLog.success)
        let recorder = StageRecorder()

        let result = await Flasher(runner: openOCD).flash(plan) { recorder.record($0) }

        #expect(result.failure == .imageNotFound(plan.image))
        #expect(openOCD.calls.withLock { $0 }.isEmpty)
        #expect(recorder.stages.isEmpty)
    }

    @Test func stoppingAFlashReportsItAsStopped() async throws {
        let folder = try TemporaryFolder()
        let plan = try makePlan(in: folder)
        let recorder = StageRecorder()
        let flasher = Flasher(runner: FakeOpenOCD(log: "", hangsUntilStopped: true))
        let task = Task { await flasher.flash(plan) { recorder.record($0) } }

        while recorder.stages.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let result = await task.value

        #expect(result.failure == .stopped)
    }

    @Test func aFlashStoppedBeforeItStartsNeverRunsOpenOCD() async throws {
        let folder = try TemporaryFolder()
        let plan = try makePlan(in: folder)
        let openOCD = FakeOpenOCD(log: FlashLog.success)
        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            return await Flasher(runner: openOCD).flash(plan) { _ in }
        }
        task.cancel()

        let result = await task.value

        #expect(result.failure == .stopped)
        #expect(openOCD.calls.withLock { $0 }.isEmpty)
    }

    // MARK: - Planning

    @Test func planningFindsOpenOCDAndTheProjectsChip() throws {
        let folder = try TemporaryFolder()
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let openOCD = try FakeTool.install(.openOCD, in: bin, script: "exit 0")
        let template = try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
        let projectFile = try template.createProject(named: "Blinky", in: folder.url)
        let image = projectFile.deletingLastPathComponent().appending(path: "build/Blinky.elf")

        let plan = try Flasher.plan(
            forProjectFile: projectFile,
            image: image,
            locator: ToolLocator(searchDirectories: [bin])
        )

        #expect(plan.openOCD == openOCD)
        #expect(plan.image == image)
        #expect(plan.chip == .tm4c1294ncpdt)
    }

    @Test func planningFailsWhenOpenOCDIsNotInstalled() throws {
        let folder = try TemporaryFolder()
        let template = try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
        let projectFile = try template.createProject(named: "Blinky", in: folder.url)

        #expect(throws: FlashFailure.openOCDNotFound) {
            try Flasher.plan(
                forProjectFile: projectFile,
                image: folder.url.appending(path: "Blinky.elf"),
                locator: ToolLocator(searchDirectories: [])
            )
        }
    }

    // MARK: - With a real process

    /// A stand-in `openocd` script, run through the real process runner.
    @Test func followsARealProcessThatPrintsLikeOpenOCD() async throws {
        let folder = try TemporaryFolder()
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let log = temp.url.appending(path: "log.txt")
        try Data(FlashLog.success.utf8).write(to: log)
        // OpenOCD prints to standard error.
        let openOCD = try FakeTool.install(
            .openOCD,
            in: bin,
            script: "cat '\(log.path(percentEncoded: false))' >&2"
        )
        let plan = try makePlan(in: folder, openOCD: openOCD)
        let recorder = StageRecorder()

        let result = await Flasher().flash(plan) { recorder.record($0) }

        #expect(result.succeeded, "Flash failed:\n\(result.log)")
        #expect(recorder.stages == [.connecting, .connected, .writing, .verifying, .resetting, .done])
    }

    @Test func aToolThatCannotBeStartedIsAFailure() async throws {
        let folder = try TemporaryFolder()
        let plan = try makePlan(in: folder, openOCD: URL(filePath: "/nonexistent/openocd"))

        let result = await Flasher().flash(plan) { _ in }

        #expect(!result.succeeded)
        #expect(result.failure != .boardNotConnected)
    }
}

/// The real OpenOCD on this machine, without a board.
///
/// Skipped when OpenOCD is not installed, unless `UMEIL_REQUIRE_TOOLS=1` (as in CI).
struct RealOpenOCDWithoutABoardTests {
    private static let hasOpenOCD = ProcessInfo.processInfo.environment["UMEIL_REQUIRE_TOOLS"] == "1"
        || ToolLocator.standard().locate(.openOCD) != nil

    /// With a board plugged in there is nothing to fail.
    private static let canFailToConnect = hasOpenOCD && !USBBoardMonitor.isPresent(Board.ekTM4C1294XL.debugProbe)

    /// Runs the plan's chip check in the real OpenOCD, with `flash info`
    /// replaced by something that answers `chipInfo`. No board is involved.
    private func runChipCheck(answering chipInfo: String) async throws -> ProcessOutput {
        let openOCD = try #require(ToolLocator.standard().locate(.openOCD))
        let plan = FlashPlan(openOCD: openOCD, image: URL(filePath: "/tmp/Blinky.elf"), chip: .tm4c1294ncpdt)
        let check = try #require(plan.arguments.first { $0.contains("flash info 0") })
        let commands = [
            "proc flash {args} { return \(FlashPlan.tclQuoted(chipInfo)) }",
            check,
            "echo \(FlashPlan.tclQuoted(FlashPlan.marker(for: .writing)))",
            "shutdown"
        ]
        return try await ProcessRunner().run(openOCD, arguments: commands.flatMap { ["-c", $0] })
    }

    @Test(.enabled(if: hasOpenOCD))
    func theChipCheckLetsTheRightChipThrough() async throws {
        let output = try await runChipCheck(
            answering: "TI/LMI Stellaris information: Chip is class 10 (Snowflake) TM4C1294NCPDT rev A2"
        )
        let text = output.combinedOutput

        #expect(output.exitCode == 0, "OpenOCD said:\n\(text)")
        #expect(text.contains("uMeil: writing"))
        #expect(!text.contains(FlashPlan.wrongChipMarker))
        #expect(FlashOutput.chipName(in: text) == "TM4C1294NCPDT")
    }

    @Test(.enabled(if: hasOpenOCD))
    func theChipCheckStopsBeforeWritingToAnotherChip() async throws {
        let output = try await runChipCheck(
            answering: "TI/LMI Stellaris information: Chip is class 5 (Blizzard/TM4C123x) TM4C123GH6PM rev A1"
        )
        let text = output.combinedOutput
        let plan = FlashPlan(openOCD: URL(filePath: "/openocd"), image: URL(filePath: "/x.elf"), chip: .tm4c1294ncpdt)

        #expect(output.exitCode != 0)
        #expect(!text.contains("uMeil: writing"), "OpenOCD said:\n\(text)")
        #expect(FlashOutput.failure(in: text, exitCode: output.exitCode, plan: plan)
            == .wrongChip(found: "TM4C123GH6PM", expected: .tm4c1294ncpdt))
    }

    @Test(.enabled(if: hasOpenOCD))
    func theChipCheckLetsTheFlashGoAheadWhenOpenOCDDoesNotDescribeTheChip() async throws {
        let output = try await runChipCheck(answering: "#0 : tm4c1294ncpdt.flash (stellaris) at 0x00000000")

        #expect(output.exitCode == 0)
        #expect(output.combinedOutput.contains("uMeil: writing"))
    }

    @Test(.enabled(if: canFailToConnect))
    func reportsThatNoBoardIsConnected() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "Blinky.elf")
        try Data("not really firmware".utf8).write(to: image)
        let openOCD = try #require(ToolLocator.standard().locate(.openOCD))
        var plan = FlashPlan(openOCD: openOCD, image: image, chip: .tm4c1294ncpdt)
        // Only connect. If a board is plugged in after all, nothing is written to it.
        plan.arguments = ["-f", Chip.tm4c1294ncpdt.openOCDConfig, "-c", "init", "-c", "shutdown"]
        let recorder = StageRecorder()

        let result = await Flasher().flash(plan) { recorder.record($0) }

        #expect(result.failure == .boardNotConnected, "OpenOCD said:\n\(result.log)")
        #expect(recorder.stages == [.connecting])
    }
}
