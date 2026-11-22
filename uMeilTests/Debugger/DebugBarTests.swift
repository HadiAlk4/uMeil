import AppKit
import Testing
@testable import uMeil

@MainActor
struct DebugBarTests {
    private func makeWindow() throws -> (MainWindowController, FakeDebugger) {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        let gdb = FakeBlinky.debugger()
        controller.debugger.connect = { _ in gdb }
        return (controller, gdb)
    }

    @Test func floatsOverTheTopOfTheEditorOnlyDuringASession() async throws {
        let (controller, gdb) = try makeWindow()
        let bar = controller.debugBar
        #expect(bar.superview === controller.editor.view)
        #expect(bar.isHidden)

        try await controller.debugger.start(FakeBlinky.plan)
        gdb.print(FakeBlinky.stop(atLine: 21, of: URL(filePath: "/tmp/main.c"), reason: "breakpoint-hit"))
        await waitUntil("the program stops") { controller.debugger.isStopped }

        #expect(!bar.isHidden)
        controller.editor.view.layoutSubtreeIfNeeded()
        let frame = bar.convert(bar.bounds, to: controller.editor.view)
        let editorBounds = controller.editor.view.bounds
        #expect(abs(frame.midX - editorBounds.midX) < 1, "the bar is centred")
        #expect(editorBounds.contains(frame), "the bar is inside the editor")

        await controller.debugger.stop()
        #expect(bar.isHidden)
    }

    @Test func showsRunWhileStoppedAndStopWhileRunning() async throws {
        let (controller, gdb) = try makeWindow()
        let bar = controller.debugBar
        let run = #selector(MainWindowController.debugContinue(_:))
        let pause = #selector(MainWindowController.debugPause(_:))
        let stepOver = #selector(MainWindowController.debugStepOver(_:))

        try await controller.debugger.start(FakeBlinky.plan)
        gdb.print(FakeBlinky.stop(atLine: 21, of: URL(filePath: "/tmp/main.c"), reason: "breakpoint-hit"))
        await waitUntil("the program stops") { controller.debugger.isStopped }

        #expect(bar.visibleActions == [
            run, stepOver,
            #selector(MainWindowController.debugStepInto(_:)),
            #selector(MainWindowController.debugStepOut(_:)),
            #selector(MainWindowController.debugReset(_:)),
            #selector(MainWindowController.toggleDebugging(_:))
        ])
        #expect(bar.button(for: run)?.isEnabled == true)
        #expect(bar.button(for: stepOver)?.isEnabled == true)

        controller.debugContinue(nil)
        await waitUntil("the program runs") { controller.debugger.state == .running }

        #expect(bar.visibleActions.contains(pause))
        #expect(!bar.visibleActions.contains(run))
        #expect(bar.button(for: pause)?.isEnabled == true)
        #expect(bar.button(for: stepOver)?.isEnabled == false, "stepping needs a stopped program")

        await controller.debugger.stop()
    }

    @Test func tooltipsNameTheKeilKeys() throws {
        let bar = DebugBarView()

        #expect(bar.button(for: #selector(MainWindowController.debugContinue(_:)))?.toolTip?.hasSuffix("(F5)") == true)
        #expect(bar.button(for: #selector(MainWindowController.debugStepOver(_:)))?.toolTip?.hasSuffix("(F10)") == true)
        #expect(bar.button(for: #selector(MainWindowController.debugStepInto(_:)))?.toolTip?.hasSuffix("(F11)") == true)
        #expect(bar.button(for: #selector(MainWindowController.debugStepOut(_:)))?.toolTip?.hasSuffix("(⌃F11)") == true)
    }

    /// The keys the tooltips name must be the ones the Debug menu answers to.
    @Test func theDebugMenuHasTheKeilKeys() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let debug = try #require(menu.items.first { $0.submenu?.title == "Debug" }?.submenu)
        func key(_ action: Selector) -> (String, NSEvent.ModifierFlags)? {
            debug.items.first { $0.action == action }.map { ($0.keyEquivalent, $0.keyEquivalentModifierMask) }
        }
        func functionKey(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

        let commands = DebugControlsItem.sessionCommands + [DebugControlsItem.toggle]
        for command in commands {
            guard let shortcut = command.shortcut else { continue }
            let found = try #require(key(command.action), "\(command.title) is not in the Debug menu")
            let number = try #require(Int(shortcut.drop { $0 != "F" }.dropFirst()))
            let expected = functionKey(NSF1FunctionKey + number - 1)
            #expect(found.0 == expected, "\(command.title) should answer to \(shortcut)")
            #expect(found.1 == (shortcut.hasPrefix("⌃") ? [.control] : []), "\(command.title) modifiers")
        }
    }
}
