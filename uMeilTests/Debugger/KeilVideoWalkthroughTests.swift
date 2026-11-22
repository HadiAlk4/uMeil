import AppKit
import Foundation
import Testing
@testable import uMeil

/// Replays the Keil µVision "Using the debugger" video on a real board,
/// through the editor window, and checks uMeil shows what Keil shows.
///
/// The video debugs `program` on a TM4C129. Its line numbers are kept, so
/// the lines below are the video's. Only the device header's name differs:
/// TivaWare calls it `inc/tm4c1294ncpdt.h`, Keil `TM4C129.h`.
///
/// Where uMeil differs from Keil on purpose, GDB's way is kept: it stops
/// after a function's prologue, so on line 16 for `main` rather than 15,
/// and on line 10 for `add` rather than 8.
///
/// Every stop is written to `logFile` too, to compare by eye with the
/// video. Needs the board: `TEST_RUNNER_UMEIL_HIL=1 xcodebuild test ...`.
@MainActor
@Suite(.serialized)
struct KeilVideoWalkthroughTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated private static let hasBoard = environment["UMEIL_HIL"] == "1"
        && ToolLocator.standard().locate(.compiler) != nil
        && ToolLocator.standard().locate(.debugger) != nil
        && ToolLocator.standard().locate(.openOCD) != nil

    nonisolated static let program = """
    #include "inc/tm4c1294ncpdt.h" // Device header
    #include <stdint.h>
    #include <stdlib.h>
    #include <stdbool.h>
    #include <stdio.h>


    int add(int a, int b) {
        int c;
        c=a+b;
        return(c);
    }


    int main(void) {
        int result=-99;
        int num=0;
        int *p ;

        p=&result;

        num=5;
        result=add(num,num); // equivalent to 2* num

        while(1) {} ;

        return 0;
    }


    """

    @Test(.enabled(if: hasBoard), .timeLimit(TestTiming.minutes(4)))
    func theDebuggerDoesWhatTheKeilVideoShows() async throws {
        FileManager.default.createFile(atPath: Self.logFile.path(percentEncoded: false), contents: nil)
        let folder = try TemporaryFolder()
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        try controller.createProject(named: "Debug", in: folder.url)
        let mainC = try #require(controller.editor.document?.url)
        try Self.program.write(to: mainC, atomically: true, encoding: .utf8)
        #expect(controller.openFile(mainC))

        try await buildAndStart(controller)
        await runToCursorAndHover(controller)
        await resetAndStepThroughMain(controller, mainC: mainC)
        await inspectPointerAndMemory(controller)
        await stepIntoAddAndBack(controller)
        await breakAfterReset(controller, mainC: mainC)
        try await changeToNumAndRebuild(controller, mainC: mainC)
        try await leaveBlinkyRunning(controller, in: folder.url)
    }

    // MARK: - The video, in order

    /// 0:20 Build: no errors. 0:40 Start Debug Session: stops in `main`.
    private func buildAndStart(_ controller: MainWindowController) async throws {
        let build = try #require(await controller.build())
        log("== Build: succeeded=\(build.succeeded)")
        for line in build.log.split(separator: "\n").suffix(3) { log("  \(line)") }
        try #require(build.succeeded)

        try #require(await controller.startDebugging())
        #expect(controller.debugPanels.isDebugLayoutVisible)
        #expect(controller.editor.isReadOnly)
        await expectStop(controller, line: 16, function: "main", "Start debug session (Keil: line 15)")

        await wait("lines with code are marked") { !controller.editor.executableLines.isEmpty }
        log("executable lines: \(controller.editor.executableLines.sorted())")
        // The grey marks in the video's gutter.
        #expect(controller.editor.executableLines == [8, 10, 11, 12, 15, 16, 17, 20, 22, 23, 25])

        let locals = controller.debugPanels.callStackLocals
        #expect(locals.frameNodes.map(\.name) == ["main"])
        #expect(locals.frameNodes.first?.children.map(\.name) == ["result", "num", "p"])
        let state = controller.debugPanels.registers.nodes.last?.children.map { "\($0.name) \($0.value)" }
        log("Registers > Internal: \(state?.joined(separator: ", ") ?? "none")")
        #expect(state == ["Mode Thread", "Privilege Privileged", "Stack MSP"])
    }

    /// 2:10 Run to Cursor Line 20. 3:40 Hover shows a variable's value.
    private func runToCursorAndHover(_ controller: MainWindowController) async {
        putCursor(onLine: 20, of: controller)
        controller.debugRunToCursor(nil)
        await expectStop(controller, line: 20, function: "main", "Run to Cursor Line 20")
        #expect(controller.debugger.breakpoints.isEmpty, "Run to cursor leaves no breakpoint behind")

        let text = controller.editor.textView.string as NSString
        let index = text.range(of: "result=-99").location + 1
        let hover = await controller.editor.showHoverValue(atCharacterIndex: index)
        log("hover over result on line 16: \(hover ?? "nothing")")
        #expect(hover == "result = -99")
    }

    /// 4:20 Reset, back to the top of `main`, and F11 line by line: hex, then decimal.
    private func resetAndStepThroughMain(_ controller: MainWindowController, mainC: URL) async {
        let locals = controller.debugPanels.callStackLocals
        await reset(controller)
        #expect(controller.openFile(mainC))
        putCursor(onLine: 16, of: controller)
        controller.debugRunToCursor(nil)
        await expectStop(controller, line: 16, function: "main", "Run to line 16 after reset")

        controller.debugStepInto(nil)
        await expectStop(controller, line: 17, function: "main", "Step (F11) -> 17")
        #expect(shownValue("result", in: locals) == "0xFFFFFF9D")
        #expect(locals.changedKeys.contains("0:result"))

        locals.toggleHexadecimalDisplay(nil)
        log("Hexadecimal Display off: result shows \(shownValue("result", in: locals) ?? "?")")
        #expect(shownValue("result", in: locals) == "-99")

        controller.debugStepInto(nil)
        await expectStop(controller, line: 20, function: "main", "Step (F11) -> 20")
        #expect(shownValue("num", in: locals) == "0")

        controller.debugStepInto(nil)
        await expectStop(controller, line: 22, function: "main", "Step (F11) -> 22")
    }

    /// 5:35 `p` holds `result`'s address and expands to -99. 6:00 Memory 1
    /// at that address shows -99 in little-endian order.
    private func inspectPointerAndMemory(_ controller: MainWindowController) async {
        let panels = controller.debugPanels
        let pointer = shownValue("p", in: panels.callStackLocals) ?? "?"
        let address = await controller.debugger.evaluate("&result") ?? "?"
        log("p = \(pointer), &result = \(address)")
        #expect(address.lowercased().hasPrefix(pointer.lowercased()))
        #expect(await expandPointer("p", in: panels.callStackLocals) == "-99")

        panels.memory.onRequestAddress?(pointer)
        await wait("Memory 1 shows p's address") { !panels.memory.rows.isEmpty }
        for row in panels.memory.rows.prefix(2) { log("Memory 1: \(row.addressText): \(row.hexText)") }
        #expect(panels.memory.rows.first.map { Array($0.bytes.prefix(4)) } == [0x9D, 0xFF, 0xFF, 0xFF])
    }

    /// 7:00 F11 into `add`, which is pushed above `main`; 8:00 back in
    /// `main`, `result` and `*p` are 10.
    private func stepIntoAddAndBack(_ controller: MainWindowController) async {
        let panels = controller.debugPanels
        let locals = panels.callStackLocals
        controller.debugStepInto(nil)
        await expectStop(controller, line: 23, function: "main", "Step (F11) -> 23")
        #expect(shownValue("num", in: locals) == "5")

        controller.debugStepInto(nil)
        await expectStop(controller, line: 10, function: "add", "Step (F11) into add (Keil: line 8)")
        #expect(locals.frameNodes.map(\.name) == ["add", "main"])
        #expect(shownValue("a", in: locals) == "5")
        #expect(shownValue("b", in: locals) == "5")

        controller.debugStepInto(nil)
        await expectStop(controller, line: 11, function: "add", "Step (F11) -> 11")
        #expect(shownValue("c", in: locals) == "10")

        controller.debugStepOut(nil)
        await wait("back in main") { locals.frameNodes.first?.name == "main" && controller.debugger.isStopped }
        if controller.editor.executionLine == 23 {
            // Out of add, with the result still to be stored.
            controller.debugStepInto(nil)
        }
        await expectStop(controller, line: 25, function: "main", "Back in main -> 25 while(1)")
        #expect(locals.frameNodes.map(\.name) == ["main"])
        #expect(shownValue("result", in: locals) == "10")
        #expect(await expandPointer("p", in: locals) == "10")
        for row in panels.memory.rows.prefix(1) { log("Memory 1: \(row.addressText): \(row.hexText)") }
        #expect(panels.memory.rows.first.map { Array($0.bytes.prefix(4)) } == [0x0A, 0x00, 0x00, 0x00])
    }

    /// 8:30 Breakpoint on line 22, Reset into the startup code, Run (F5): stops on 22.
    private func breakAfterReset(_ controller: MainWindowController, mainC: URL) async {
        controller.editor.onClickGutterLine?(22)
        await wait("the breakpoint is set") { controller.editor.breakpointLines == [22] }
        await reset(controller)
        controller.debugContinue(nil)
        await expectStop(controller, line: 22, function: "main", "Run (F5) -> breakpoint on 22")
        let shown = controller.editor.document?.url.resolvingSymlinksInPath()
        #expect(shown == mainC.resolvingSymlinksInPath())
        #expect(controller.editor.breakpointLines == [22])
        #expect(shownValue("num", in: controller.debugPanels.callStackLocals) == "0")
    }

    /// 9:20 Stop the session, change line 20 to `p=&num`, build again. The
    /// video ends there; this also runs it to show `p` now points at `num`.
    private func changeToNumAndRebuild(_ controller: MainWindowController, mainC: URL) async throws {
        await controller.debugger.stop()
        await wait("the session is over") { !controller.debugger.isActive }
        #expect(!controller.debugPanels.isDebugLayoutVisible)
        #expect(!controller.editor.isReadOnly)
        #expect(controller.editor.breakpointLines == [22])

        try Self.program.replacingOccurrences(of: "p=&result;", with: "p=&num;")
            .write(to: mainC, atomically: true, encoding: .utf8)
        #expect(controller.openFile(mainC))
        let rebuild = try #require(await controller.build())
        log("== Rebuild after p=&num: succeeded=\(rebuild.succeeded)")
        try #require(rebuild.succeeded)

        try #require(await controller.startDebugging())
        await expectStop(controller, line: 16, function: "main", "Start again")
        controller.debugContinue(nil)
        await expectStop(controller, line: 22, function: "main", "Run (F5) -> breakpoint on 22")
        #expect(await expandPointer("p", in: controller.debugPanels.callStackLocals) == "0")
        #expect(await controller.debugger.evaluate("p == &num") == "1")
        await controller.debugger.stop()
        await wait("the session is over") { !controller.debugger.isActive }
    }

    /// The other board tests expect Blinky on the board. With this program
    /// left in its `while(1)`, GDB first finds the chip in a `main`.
    private func leaveBlinkyRunning(_ controller: MainWindowController, in folder: URL) async throws {
        try controller.createProject(named: "Blinky", in: folder)
        try #require(await controller.startDebugging())
        await wait("Blinky stops at main", seconds: 30) { controller.debugger.isStopped }
        await controller.debugger.stop()
        await wait("the session is over") { !controller.debugger.isActive }
    }
}
