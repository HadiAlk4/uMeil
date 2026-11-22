import AppKit
import os
import Testing
@testable import uMeil

private struct FolderSwitchingRunner: ProcessRunning {
    let onRun: @MainActor @Sendable () -> Void
    func run(_ executable: URL, arguments: [String], currentDirectory: URL?) async throws -> ProcessOutput {
        await onRun()
        return try await ProcessRunner().run(executable, arguments: arguments, currentDirectory: currentDirectory)
    }
}

extension DebugInEditorTests {
    @Test func appQuitAndWindowCloseStopGDBBeforeFinishing() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        await startAtMain(window)

        let delegate = AppDelegate()
        delegate.mainWindowController = controller
        var replied: Bool?
        delegate.replyToTerminate = { replied = $0 }
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        await waitUntil("quit reply") { replied == true }
        #expect(!controller.debugger.isActive && window.gdb.commands.suffix(2) == ["-exec-continue", "-gdb-exit"])

        // New FakeDebugger for the window-close stop check (previous FakeDebugger ended its stream).
        let gdb2 = FakeBlinky.debugger()
        controller.debugger.connect = { _ in gdb2 }
        await startAtMain(Window(controller: controller, gdb: gdb2, mainC: window.mainC))
        let nsWindow = try #require(controller.window)
        #expect(!controller.windowShouldClose(nsWindow))
        await waitUntil("window close stopped GDB") {
            !controller.debugger.isActive && !controller.debugTasks.isClosingAfterDebugStop
        }
        #expect(gdb2.commands.suffix(2) == ["-exec-continue", "-gdb-exit"])

        let gdb3 = FakeBlinky.debugger()
        controller.debugger.connect = { _ in gdb3 }
        await startAtMain(Window(controller: controller, gdb: gdb3, mainC: window.mainC))
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(!controller.debugger.isActive)
    }

    @Test func folderSwitchClearsBreakpointsAbortsMidBuildAndClearsConsole() async throws {
        let folderA = try TemporaryFolder()
        let folderB = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folderA)
        let controller = window.controller
        controller.editor.goTo(line: 28, column: 1)
        controller.toggleBreakpointAtCursor(nil)
        await waitUntil("bp set") { controller.editor.breakpointLines == [28] }

        controller.openFolder(folderB.url)
        #expect(controller.debugger.breakpoints.isEmpty && controller.editor.breakpointLines.isEmpty)

        // Switching folders mid-build prevents starting GDB for the old folder.
        let folderA2 = try TemporaryFolder()
        let window2 = try makeBlinkyWindow(in: folderA2)
        let ctrl2 = window2.controller
        let urlB = folderB.url
        ctrl2.buildEngine = BuildEngine(runner: FolderSwitchingRunner {
            if ctrl2.folder != urlB { ctrl2.openFolder(urlB) }
        })
        #expect(await !ctrl2.startDebugging())
        #expect(!ctrl2.debugger.isActive && window2.gdb.commands.isEmpty)

        // Starting a new debug session clears prior Command console output.
        let folderA3 = try TemporaryFolder()
        let window3 = try makeBlinkyWindow(in: folderA3)
        window3.controller.debugPanels.command.appendOutput("stale output\n")
        await startAtMain(window3)
        #expect(!window3.controller.debugPanels.command.textView.string.contains("stale output"))
    }

    @Test func hoverCancelsOnStateChangeAndIgnoresStaleOrCancelledReplies() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        await startAtMain(window)
        let startup = window.mainC.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "startup/startup.c")
        let idx = (controller.editor.textView.string as NSString).range(of: "main").location
        controller.editor.onHoverIdentifier = { _ in "0x20a" }
        _ = await controller.editor.showHoverValue(atCharacterIndex: idx)
        #expect(controller.editor.textView.toolTip == "main = 0x20a")

        controller.debugStepOver(nil)
        await waitUntil("running") { controller.debugger.state == .running }
        #expect(controller.editor.textView.toolTip == nil)

        // A late hover reply after switching files must not show a stale tooltip.
        var resumeHover: CheckedContinuation<String?, Never>?
        controller.editor.onHoverIdentifier = { _ in
            await withCheckedContinuation { resumeHover = $0 }
        }
        let hoverCall = Task { await controller.editor.showHoverValue(atCharacterIndex: idx) }
        await waitUntil("hover suspended") { resumeHover != nil }
        controller.openFile(startup)
        resumeHover?.resume(returning: "0xdead")
        #expect(await hoverCall.value == nil && controller.editor.textView.toolTip == nil)

        // A cancelled hover task must also drop its late reply.
        let startupIdx = (controller.editor.textView.string as NSString).range(of: "void").location
        #expect(startupIdx != NSNotFound)
        var resumeCancelled: CheckedContinuation<String?, Never>?
        controller.editor.onHoverIdentifier = { _ in
            await withCheckedContinuation { resumeCancelled = $0 }
        }
        let cancelledTask = Task { await controller.editor.showHoverValue(atCharacterIndex: startupIdx) }
        await waitUntil("cancelled hover suspended") { resumeCancelled != nil }
        cancelledTask.cancel()
        resumeCancelled?.resume(returning: "0xbeef")
        #expect(await cancelledTask.value == nil && controller.editor.textView.toolTip == nil)

        // Stopping in another file queries executable lines once (no duplicate from showStop).
        window.gdb.print(FakeBlinky.stop(atLine: 30, of: startup))
        await waitUntil("stopped in startup") { controller.debugger.isStopped }
        await waitUntil("lines marked") { controller.editor.executableLines == [21, 28, 31] }
        let startupPath = SourceLine(file: startup, line: 0).file.path(percentEncoded: false)
        let lineQueries = window.gdb.commands.filter { $0 == "-symbol-list-lines \"\(startupPath)\"" }
        #expect(lineQueries.count == 1)
    }

    @Test func memoryWriteAndConsoleCommandRefreshPanelsAndCancelAdHocTasks() async throws {
        let folder = try TemporaryFolder()
        let values = OSAllocatedUnfairLock(initialState: (local: "1", reg: "0x00000001"))
        let gdb = FakeDebugger { cmd in
            if cmd.hasPrefix("-data-write-memory-bytes") {
                values.withLock { $0.local = "42" }
                return ["^done"]
            }
            if cmd.contains("set $r0 = 0x1234") {
                values.withLock { $0.reg = "0x00001234" }
                return ["^done"]
            }
            let current = values.withLock { $0 }
            if cmd == "-stack-list-frames" {
                return ["^done,stack=[frame={level=\"0\",addr=\"0x20a\",func=\"main\"}]"]
            }
            if cmd.hasPrefix("-stack-list-variables") {
                return ["^done,variables=[{name=\"x\",type=\"int\",value=\"\(current.local)\"}]"]
            }
            if cmd == "-data-list-register-names" { return ["^done,register-names=[\"r0\"]"] }
            if cmd == "-data-list-register-values x" {
                return ["^done,register-values=[{number=\"0\",value=\"\(current.reg)\"}]"]
            }
            if cmd.hasPrefix("-data-evaluate-expression") { return ["^done,value=\"\(current.local)\""] }
            if cmd.hasPrefix("-data-read-memory-bytes") {
                return ["^done,memory=[{begin=\"0x20000000\",contents=\"2a000000\"}]"]
            }
            if cmd.hasPrefix("-data-disassemble") { return ["^done,asm_insns=[]"] }
            return ["^done"]
        }
        let window = try makeBlinkyWindow(in: folder, gdb: gdb)
        let controller = window.controller
        controller.debugPanels.watch.addExpression("x")
        await startAtMain(window)
        await waitUntil("initial watch") { controller.debugPanels.watch.entries.first?.value == "1" }

        controller.debugPanels.memory.onWriteBytes?(0x2000_0000, [0x2a, 0, 0, 0])
        await waitUntil("write refreshed watch and locals") {
            controller.debugPanels.watch.entries.first?.value == "42"
                && controller.debugPanels.callStackLocals.frameNodes.first?.children.first?.rawValue == "42"
        }

        controller.debugPanels.command.onSendCommand?("set $r0 = 0x1234")
        await waitUntil("console refreshed regs") {
            controller.debugPanels.registers.nodes.first { $0.key == "r0" }?.value == "0x00001234"
        }

        controller.debugPanels.watch.onExpressionsChanged?(["x"])
        let firstTask = controller.debugTasks.watchRefreshTask
        controller.debugPanels.watch.onExpressionsChanged?(["x"])
        #expect(firstTask?.isCancelled == true)
    }
}
