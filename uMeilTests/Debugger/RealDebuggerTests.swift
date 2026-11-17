import AppKit
import Foundation
import Testing
@testable import uMeil

/// The real GDB on this machine, debugging a freshly built Blinky.
///
/// Skipped when the compiler or GDB is not installed, unless
/// `UMEIL_REQUIRE_TOOLS=1` (as in CI).
@Suite(.serialized)
struct RealDebuggerTests {
    private static let environment = ProcessInfo.processInfo.environment
    private static let hasTools = environment["UMEIL_REQUIRE_TOOLS"] == "1"
        || (ToolLocator.standard().locate(.compiler) != nil && ToolLocator.standard().locate(.debugger) != nil)

    /// The tests that need a board write to it, so they only run when asked
    /// for: `TEST_RUNNER_UMEIL_HIL=1 xcodebuild test ...` with an
    /// EK-TM4C1294XL plugged in.
    private static let hasBoard = hasTools && environment["UMEIL_HIL"] == "1"
        && ToolLocator.standard().locate(.openOCD) != nil

    /// A built Blinky, and a GDB session that has not connected to anything.
    private struct Debugging {
        var folder: TemporaryFolder
        var mainC: URL
        var plan: DebugPlan
        var session: GDBSession
    }

    private func startGDB() async throws -> Debugging {
        let folder = try TemporaryFolder()
        let template = try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
        let projectFile = try template.createProject(named: "Blinky", in: folder.url)
        let build = try await BuildEngine().build(BuildEngine.plan(forProjectFile: projectFile))
        let image = try #require(build.elf, "Build failed:\n\(build.log)")

        let locator = ToolLocator.standard()
        let plan = DebugPlan(
            gdb: try #require(locator.locate(.debugger)),
            // Only used by the tests that have a board.
            openOCD: locator.locate(.openOCD) ?? URL(filePath: "/usr/bin/false"),
            image: image,
            chip: .tm4c1294ncpdt
        )
        let session = GDBSession(connection: try GDBProcess(plan.gdb, arguments: plan.gdbArguments))
        return Debugging(
            folder: folder,
            mainC: projectFile.deletingLastPathComponent().appending(path: "src/main.c"),
            plan: plan,
            session: session
        )
    }

    /// Waits for the program to stop, skipping everything else.
    private func nextStop(_ events: inout AsyncStream<DebugEvent>.Iterator) async throws -> StopEvent {
        while let event = await events.next() {
            if case .stopped(let stop) = event { return stop }
        }
        throw DebugError.sessionEnded
    }

    // MARK: - Without a board

    @Test(.enabled(if: hasTools), .timeLimit(.minutes(1)))
    func gdbReadsTheProgramAndAnswersWithoutABoard() async throws {
        let debugging = try await startGDB()
        let session = debugging.session
        // The symbols alone are enough for breakpoints and constant expressions.
        try await session.send(debugging.plan.connectCommands[2])

        let breakpoint = try await session.insertBreakpoint(line: 28, of: debugging.mainC)
        #expect(breakpoint.line == 28)
        #expect(breakpoint.function == "main")
        #expect(breakpoint.file?.resolvingSymlinksInPath() == debugging.mainC.resolvingSymlinksInPath())

        #expect(try await session.evaluate("sizeof(int)") == "4")
        await #expect(throws: DebugError.refused("No symbol \"nosuchvar\" in current context.")) {
            try await session.evaluate("nosuchvar")
        }
        await #expect(throws: DebugError.refused("The program is not being run.")) {
            try await session.resume()
        }

        await session.end()
        await #expect(throws: DebugError.sessionEnded) { try await session.frames() }
    }

    // MARK: - With a board

    @Test(.enabled(if: hasBoard), .timeLimit(.minutes(2)))
    func onTheBoardBlinkyRunsToMainThenStepsBreaksPausesAndResets() async throws {
        let debugging = try await startGDB()
        let session = debugging.session
        var events = session.events.makeAsyncIterator()

        // Start: connect, write Blinky, stop at the first line of main.
        try await session.start(debugging.plan)
        var stop = try await nextStop(&events)
        // GDB first reports the chip as it found it; the next stop is main.
        while stop.frame?.function != "main" { stop = try await nextStop(&events) }
        #expect(stop.frame?.line == 21)
        #expect(stop.frame?.file?.lastPathComponent == "main.c")

        let frames = try await session.frames()
        #expect(frames.map(\.function) == ["main"])
        let registers = try await session.registers()
        let named = Dictionary(uniqueKeysWithValues: registers.map { ($0.name, $0.value) })
        #expect(named["pc"] == stop.frame?.address)
        #expect(try #require(named["sp"] ?? nil) > 0x2000_0000)
        #expect(try await session.variables().isEmpty) // Blinky's main has none.

        // Step over one line.
        try await session.stepOver()
        stop = try await nextStop(&events)
        #expect(stop.reason == .stepFinished)
        #expect(stop.frame?.line == 22)

        // Run to a breakpoint in the blink loop.
        let breakpoint = try await session.insertBreakpoint(line: 28, of: debugging.mainC)
        try await session.resume()
        stop = try await nextStop(&events)
        #expect(stop.reason == .breakpoint(number: breakpoint.number))
        #expect(stop.frame?.line == 28)
        try await session.deleteBreakpoint(breakpoint)

        // Run to a line without leaving a breakpoint behind.
        try await session.run(toLine: 31, of: debugging.mainC)
        stop = try await nextStop(&events)
        #expect(stop.frame?.line == 31)

        // The vector table starts with the initial stack pointer: the top of RAM.
        #expect(try await session.readMemory(at: 0, count: 4) == [0x00, 0x00, 0x04, 0x20])

        // Let it run, then pause it in the delay loop.
        try await session.resume()
        try await Task.sleep(for: .milliseconds(300))
        try await session.pause()
        stop = try await nextStop(&events)
        #expect(stop.reason == .signal(name: "SIGINT", meaning: "Interrupt"))
        #expect(stop.frame?.function == "SysCtlDelay")

        // Reset goes back to the reset handler.
        let afterReset = try await session.reset()
        #expect(afterReset?.function == "ResetISR" || afterReset?.function == "Reset_Handler")

        // Leave the board running Blinky.
        try await session.send("-interpreter-exec console \"monitor reset run\"")
        await session.end()
    }

    @MainActor
    @Test(.enabled(if: hasBoard), .timeLimit(.minutes(2)))
    func theEditorWindowStartsOnTheBoardStepsHitsABreakpointAndStops() async throws {
        let folder = try TemporaryFolder()
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        try controller.createProject(named: "Blinky", in: folder.url)

        controller.editor.onClickGutterLine?(28)
        await waitUntil("the breakpoint is set") { controller.editor.breakpointLines == [28] }

        #expect(await controller.startDebugging())
        await waitUntil("the program stops at main") { controller.debugger.isStopped }

        #expect(controller.debugPanels.isDebugLayoutVisible)
        #expect(controller.editor.executionLine == 21)
        #expect(controller.editor.breakpointLines == [28])
        #expect(controller.editor.isReadOnly)
        #expect(controller.issues.statusLabel.stringValue == "Stopped at main.c:21 in main")
        await waitUntil("the lines with code are marked") { !controller.editor.executableLines.isEmpty }
        #expect(controller.editor.executableLines.contains(21))
        #expect(controller.editor.executableLines.contains(28))
        await waitUntil("the debug panels populate from the board") {
            !controller.debugPanels.registers.nodes.isEmpty
                && !controller.debugPanels.disassembly.rows.isEmpty
        }
        #expect(controller.debugPanels.callStackLocals.frameNodes.first?.name == "main")

        controller.debugStepOver(nil)
        await waitUntil("the program steps to line 22") { controller.editor.executionLine == 22 }
        #expect(controller.issues.statusLabel.stringValue == "Stopped at main.c:22 in main")

        controller.debugContinue(nil)
        await waitUntil("the program hits the breakpoint on line 28") { controller.editor.executionLine == 28 }
        #expect(controller.issues.statusLabel.stringValue == "Stopped at main.c:28 in main")

        await controller.debugger.stop()
        await waitUntil("the session is over") { !controller.debugger.isActive }
        #expect(!controller.debugPanels.isDebugLayoutVisible)
        #expect(!controller.editor.isReadOnly)
        #expect(controller.editor.executionLine == nil)
        #expect(controller.editor.breakpointLines == [28])
    }

    /// M7 on the board: the `Peripherals` panel reads GPIO port N, writing
    /// its `DATA` register turns LED D1 on and off (watch the board), and
    /// GDB reads back what was written. `Memory 1` writes RAM the same way.
    @MainActor
    @Test(.enabled(if: hasBoard), .timeLimit(.minutes(2)))
    func onTheBoardThePeripheralsPanelDrivesLEDD1AndMemory1WritesRAM() async throws {
        UserDefaults.standard.removeObject(forKey: PeripheralsViewController.selectionKey)
        let folder = try TemporaryFolder()
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        try controller.createProject(named: "Blinky", in: folder.url)
        // Line 28 runs after port N is clocked and PN1 is an output.
        controller.editor.onClickGutterLine?(28)
        await waitUntil("the breakpoint is set") { controller.editor.breakpointLines == [28] }

        #expect(await controller.startDebugging())
        await waitUntil("the program stops at main") { controller.debugger.isStopped }
        controller.debugContinue(nil)
        await waitUntil("the program hits the breakpoint on line 28") { controller.editor.executionLine == 28 }

        let panels = controller.debugPanels
        let view = panels.peripherals
        let port = try #require(view.selectedPeripheral)
        #expect(port.name == "GPIO_PORTN")
        await waitUntil("the Peripherals panel reads port N") {
            if case .value = view.readings["DIR"] { true } else { false }
        }
        #expect(view.isEditable)
        let direction = try #require(view.nodes.first { $0.name == "DIR" })
        #expect(view.valueText(for: try #require(direction.children.first { $0.name == "P1" })) == "1")

        let data = try #require(port.register(named: "DATA"))
        let pin1 = try #require(data.fields.first { $0.name == "P1" })
        let session = try #require(controller.debugger.session)

        // LED D1 on.
        #expect(await panels.writePeripheral(port, register: data, field: pin1, text: "1", using: controller.debugger)
            == nil)
        #expect(try await session.readMemory(at: 0x4006_43FC, count: 4) == [0x02, 0, 0, 0])
        #expect(view.readings["DATA"] == .value(0x02))
        try await Task.sleep(for: .milliseconds(500))

        // LED D1 off.
        #expect(await panels.writePeripheral(port, register: data, field: nil, text: "0x0", using: controller.debugger)
            == nil)
        #expect(try await session.readMemory(at: 0x4006_43FC, count: 4) == [0x00, 0, 0, 0])
        #expect(view.readings["DATA"] == .value(0))

        #expect(view.messageLabel.stringValue.isEmpty)

        // Blinky never turns UART3's clock on. Its registers then read as
        // zeros instead of failing, so the panel says why.
        view.select(peripheralNamed: "UART3")
        await waitUntil("the Peripherals panel reads UART3") {
            view.messageLabel.stringValue.contains("clock is off")
        }
        #expect(view.readings["CTL"] == .value(0))

        // Memory 1: write four bytes of RAM far below the stack and read them back.
        let address: UInt64 = 0x2003_0000
        #expect(await panels.writeMemory(at: address, bytes: [0x9D, 0xFF, 0xFF, 0xFF], using: controller.debugger)
            == nil)
        #expect(try await session.readMemory(at: address, count: 4) == [0x9D, 0xFF, 0xFF, 0xFF])
        #expect(try await session.evaluate("*(int *)0x20030000") == "-99")

        await controller.debugger.stop()
        await waitUntil("the session is over") { !controller.debugger.isActive }
        view.select(peripheralNamed: "GPIO_PORTN")
    }
}
