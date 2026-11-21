import AppKit
import Testing
@testable import uMeil

/// Debugging from the editor window, with a stand-in for GDB.
///
/// Needs a real compiler, because a session starts with a build.
@MainActor
@Suite(.enabled(if: BuildTestEnvironment.canBuild))
struct DebugInEditorTests {
    private struct Window {
        var controller: MainWindowController
        var gdb: FakeDebugger
        var mainC: URL
    }

    /// A window showing a new Blinky project, where debugging talks to `gdb`.
    private func makeBlinkyWindow(
        in folder: TemporaryFolder,
        gdb: FakeDebugger = FakeBlinky.debugger()
    ) throws -> Window {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        try controller.createProject(named: "Blinky", in: folder.url)
        controller.debugger.connect = { _ in gdb }

        // The real compiler, plus stand-ins for GDB and OpenOCD in case they are not installed.
        let bin = folder.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FakeTool.install(.openOCD, in: bin, script: "exit 0")
        try FakeTool.install(.debugger, in: bin, script: "exit 0")
        controller.makeToolLocator = {
            ToolLocator(searchDirectories: ToolLocator.defaultSearchDirectories() + [bin])
        }
        let mainC = try #require(controller.editor.document?.url)
        return Window(controller: controller, gdb: gdb, mainC: mainC)
    }

    /// Starts a session and stops it at the first line of `main`.
    private func startAtMain(_ window: Window) async {
        #expect(await window.controller.startDebugging())
        window.gdb.print(FakeBlinky.stop(atLine: 21, of: window.mainC, reason: "breakpoint-hit"))
        await waitUntil("the program stops at main") { window.controller.debugger.isStopped }
    }

    /// The actions of the buttons in the window's toolbar right now.
    private func toolbarActions(of controller: MainWindowController) -> [Selector] {
        controller.toolbar.visibleActions
    }

    private func isEnabled(_ action: Selector, in controller: MainWindowController) -> Bool {
        controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    /// Where line `line` is drawn in the gutter.
    private func gutterPoint(forLine line: Int, in controller: MainWindowController) throws -> NSPoint {
        let ruler = try #require(controller.editor.ruler)
        let textView = controller.editor.textView
        let layoutManager = try #require(textView.layoutManager)
        let offset = try #require(controller.editor.lineIndex.offset(ofLine: line))
        let rect = layoutManager.lineFragmentRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: offset),
            effectiveRange: nil
        )
        let inTextView = NSPoint(x: 0, y: rect.midY + textView.textContainerOrigin.y)
        return NSPoint(x: 5, y: ruler.convert(inTextView, from: textView).y)
    }

    // MARK: - Starting and stopping

    @Test func startingBuildsThenStopsAtMainWithTheLineMarked() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller

        await startAtMain(window)

        #expect(controller.lastBuild?.succeeded == true)
        #expect(controller.editor.executionLine == 21)
        #expect(controller.editor.isReadOnly)
        #expect(controller.issues.statusLabel.stringValue == "Stopped at main.c:21 in main")
        #expect(controller.toolbar.activity.activity == Activity(text: "Stopped at main.c:21 in main", kind: .info))
        #expect(controller.toolbar.isShowingDebugControls)
        #expect(toolbarActions(of: controller).contains(#selector(MainWindowController.debugStepOver(_:))))
        #expect(controller.isIssuesPanelVisible)
        // GDB was given the image the build just made.
        let image = try #require(controller.lastBuild?.elf)
        #expect(window.gdb.commands.contains("-file-exec-and-symbols \"\(image.path(percentEncoded: false))\""))
        await waitUntil("the lines with code are marked") { controller.editor.executableLines == [21, 28, 31] }
    }

    @Test func stoppingPutsTheEditorBack() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        await startAtMain(window)

        await controller.debugger.stop()
        await waitUntil("the session is over") { !controller.debugger.isActive }

        #expect(controller.editor.executionLine == nil)
        #expect(controller.editor.executableLines.isEmpty)
        #expect(!controller.editor.isReadOnly)
        #expect(controller.issues.statusLabel.stringValue == "Debug session ended")
        #expect(!controller.toolbar.isShowingDebugControls)
        #expect(!toolbarActions(of: controller).contains(#selector(MainWindowController.debugStepOver(_:))))
        #expect(toolbarActions(of: controller).contains(#selector(MainWindowController.toggleDebugging(_:))))
    }

    @Test func aBuildWithErrorsDoesNotStartASession() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        let textView = controller.editor.textView
        textView.insertText("int main(void) { return missing; }\n", replacementRange: NSRange(
            location: 0,
            length: (textView.string as NSString).length
        ))

        #expect(await !controller.startDebugging())

        #expect(!controller.debugger.isActive)
        #expect(window.gdb.commands.isEmpty)
        #expect(!controller.editor.isReadOnly)
        #expect(controller.issues.statusLabel.stringValue.hasPrefix("Build failed"))
        #expect(controller.toolbar.activity.activity.kind == .failed)
        #expect(!controller.toolbar.isShowingDebugControls)
    }

    @Test func aStartWithoutABoardIsExplained() async throws {
        let folder = try TemporaryFolder()
        let gdb = FakeBlinky.debugger(refusing: "-target-select")
        let window = try makeBlinkyWindow(in: folder, gdb: gdb)
        let controller = window.controller

        gdb.print("Error: open failed")
        #expect(await !controller.startDebugging())
        await waitUntil("the session is over") { !controller.debugger.isActive }

        #expect(controller.issues.statusLabel.stringValue == "Debug session failed to start")
        #expect(controller.issues.diagnostics.first?.message == FlashFailure.boardNotConnected.localizedDescription)
        #expect(!controller.editor.isReadOnly)
    }

    @Test func missingGDBSaysWhereToInstallIt() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        let compiler = try #require(ToolLocator.standard().locate(.compiler)).deletingLastPathComponent()
        let onlyCompiler = folder.url.appending(path: "only-compiler", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: onlyCompiler, withIntermediateDirectories: true)
        for tool in try FileManager.default.contentsOfDirectory(at: compiler, includingPropertiesForKeys: nil)
        where !tool.lastPathComponent.contains("gdb") {
            try FileManager.default.createSymbolicLink(
                at: onlyCompiler.appending(path: tool.lastPathComponent),
                withDestinationURL: tool
            )
        }
        controller.makeToolLocator = { ToolLocator(searchDirectories: [onlyCompiler]) }

        #expect(await !controller.startDebugging())

        #expect(controller.issues.diagnostics.first?.message.contains("Window > Toolchain Status") == true)
        #expect(window.gdb.commands.isEmpty)
    }

    // MARK: - Stepping

    @Test func eachStopMovesTheMarkedLine() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        await startAtMain(window)

        controller.debugStepOver(nil)
        await waitUntil("the program is running") { controller.debugger.state == .running }
        #expect(controller.editor.executionLine == nil)
        #expect(controller.issues.statusLabel.stringValue == "Running")
        #expect(window.gdb.commands.last == "-exec-next")

        window.gdb.print(FakeBlinky.stop(atLine: 22, of: window.mainC))
        await waitUntil("the program stops") { controller.debugger.isStopped }
        #expect(controller.editor.executionLine == 22)
    }

    @Test func aStopInAnotherFileOpensIt() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        await startAtMain(window)
        let startup = window.mainC.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "startup/startup.c")

        controller.debugStepInto(nil)
        await waitUntil("the program is running") { controller.debugger.state == .running }
        window.gdb.print(FakeBlinky.stop(atLine: 30, of: startup))
        await waitUntil("the program stops") { controller.debugger.isStopped }

        #expect(controller.editor.document?.url.lastPathComponent == "startup.c")
        #expect(controller.editor.executionLine == 30)
        #expect(controller.editor.isReadOnly)
    }

    @Test func aStopWithoutSourceCodeSaysWhere() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        await startAtMain(window)

        controller.debugContinue(nil)
        await waitUntil("the program is running") { controller.debugger.state == .running }
        controller.debugPause(nil)
        await waitUntil("the pause command is sent") { window.gdb.commands.last == "-exec-interrupt" }
        #expect(window.gdb.commands.suffix(2) == ["-exec-continue", "-exec-interrupt"])
        window.gdb.print(FakeBlinky.stopInLibrary)
        await waitUntil("the program stops") { controller.debugger.isStopped }

        #expect(controller.editor.executionLine == nil)
        #expect(controller.editor.document?.url.lastPathComponent == "main.c")
        #expect(controller.issues.statusLabel.stringValue
            == "Stopped in SysCtlDelay at 0x472, where there is no source code to show")
    }

    @Test func runToCursorLineUsesTheLineTheCursorIsOn() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        await startAtMain(window)

        controller.editor.goTo(line: 31, column: 1)
        controller.debugRunToCursor(nil)
        await waitUntil("the program is running") { controller.debugger.state == .running }

        let path = SourceLine(file: window.mainC, line: 31).file.path(percentEncoded: false)
        #expect(window.gdb.commands.suffix(2) == ["-break-insert -t --source \"\(path)\" --line 31", "-exec-continue"])
    }

    @Test func aCommandGDBRefusesIsExplainedInTheStatusLine() async throws {
        let folder = try TemporaryFolder()
        let refusal = "\"finish\" not meaningful in the outermost frame."
        let gdb = FakeDebugger { command in
            command == "-exec-finish" ? ["^error,msg=\"\\\"finish\\\" not meaningful in the outermost frame.\""]
                : ["^done"]
        }
        let window = try makeBlinkyWindow(in: folder, gdb: gdb)
        let controller = window.controller
        await startAtMain(window)

        controller.debugStepOut(nil)

        await waitUntil("the refusal is shown") { controller.issues.statusLabel.stringValue == refusal }
        #expect(controller.debugger.isStopped)
    }
}

extension DebugInEditorTests {
    // MARK: - Breakpoints

    @Test func clickingTheGutterSetsAndRemovesABreakpoint() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder).controller
        let ruler = try #require(controller.editor.ruler)
        controller.window?.layoutIfNeeded()
        let point = try gutterPoint(forLine: 28, in: controller)

        #expect(ruler.lineNumber(at: point) == 28)
        ruler.onClickLine?(try #require(ruler.lineNumber(at: point)))
        await waitUntil("the breakpoint shows") { controller.editor.breakpointLines == [28] }

        ruler.onClickLine?(28)
        await waitUntil("the breakpoint is gone") { controller.editor.breakpointLines.isEmpty }
    }

    @Test func breakpointsFollowTheFileThatIsOpen() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        let startup = window.mainC.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "startup/startup.c")

        controller.editor.goTo(line: 28, column: 1)
        controller.toggleBreakpointAtCursor(nil)
        await waitUntil("the breakpoint shows") { controller.editor.breakpointLines == [28] }

        controller.openFile(startup)
        #expect(controller.editor.breakpointLines.isEmpty)
        controller.openFile(window.mainC)
        #expect(controller.editor.breakpointLines == [28])
    }

    @Test func aBreakpointGDBMovesIsShownWhereItEndedUp() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder, gdb: FakeBlinky.debugger(movedLines: [26: 28]))
        let controller = window.controller
        controller.editor.goTo(line: 26, column: 1)
        controller.toggleBreakpointAtCursor(nil)
        await waitUntil("the breakpoint shows") { controller.editor.breakpointLines == [26] }

        await startAtMain(window)

        #expect(controller.editor.breakpointLines == [28])
    }

    // MARK: - What can be done when

    @Test func commandsAreOnlyOfferedWhenTheyCanRun() async throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let controller = window.controller
        let whileStopped = [
            #selector(MainWindowController.debugContinue(_:)),
            #selector(MainWindowController.debugStepInto(_:)),
            #selector(MainWindowController.debugStepOver(_:)),
            #selector(MainWindowController.debugStepOut(_:)),
            #selector(MainWindowController.debugRunToCursor(_:)),
            #selector(MainWindowController.debugReset(_:))
        ]
        let pause = #selector(MainWindowController.debugPause(_:))
        let toggle = #selector(MainWindowController.toggleDebugging(_:))
        let build = #selector(MainWindowController.buildProject(_:))
        let flash = #selector(MainWindowController.flashProject(_:))
        let breakpoint = #selector(MainWindowController.toggleBreakpointAtCursor(_:))

        // No session.
        #expect(whileStopped.allSatisfy { !isEnabled($0, in: controller) })
        #expect(!isEnabled(pause, in: controller))
        #expect([toggle, build, flash, breakpoint].allSatisfy { isEnabled($0, in: controller) })

        // Stopped.
        await startAtMain(window)
        #expect(whileStopped.allSatisfy { isEnabled($0, in: controller) })
        #expect(!isEnabled(pause, in: controller))
        #expect(isEnabled(toggle, in: controller))
        #expect(isEnabled(breakpoint, in: controller))
        #expect(!isEnabled(build, in: controller))
        #expect(!isEnabled(flash, in: controller))
        // The toolbar's buttons follow the same rules.
        let stepOver = #selector(MainWindowController.debugStepOver(_:))
        let stepOverButton = try #require(controller.toolbar.debugItem?.sessionButtons.first { $0.action == stepOver })
        #expect(stepOverButton.isEnabled)

        // Running.
        controller.debugContinue(nil)
        await waitUntil("the program is running") { controller.debugger.state == .running }
        #expect(whileStopped.allSatisfy { !isEnabled($0, in: controller) })
        #expect(!stepOverButton.isEnabled)
        #expect(isEnabled(pause, in: controller))
        #expect(isEnabled(toggle, in: controller))
        #expect(!isEnabled(breakpoint, in: controller))
    }

    @Test func theToolbarAndMenuOfferTheDebugCommands() throws {
        let item = DebugControlsItem(itemIdentifier: .init("Debug"), isSessionActive: true)
        #expect(item.visibleActions.contains(#selector(MainWindowController.toggleDebugging(_:))))
        #expect(item.visibleActions.contains(#selector(MainWindowController.debugStepOver(_:))))

        item.showSession(false)
        #expect(item.visibleActions == [#selector(MainWindowController.toggleDebugging(_:))])

        let menu = MainMenu.make(appName: "uMeil")
        let debug = try #require(menu.items.first { $0.submenu?.title == "Debug" }?.submenu)
        #expect(debug.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Start/Stop Debug Session", "Reset", "Run", "Stop", "Step", "Step Over", "Step Out",
            "Run to Cursor Line", "Insert/Remove Breakpoint"
        ])
        let stepOver = try #require(debug.items.first { $0.title == "Step Over" })
        #expect(stepOver.keyEquivalent == String(Character(UnicodeScalar(NSF10FunctionKey)!)))
        #expect(stepOver.keyEquivalentModifierMask.isEmpty)
    }
}
