import AppKit
import Testing
@testable import uMeil

@MainActor
struct BottomPanelTests {
    private final class SilentSession: TerminalSessionView {
        let hostView = NSView()
        var isRunning = false
        var onProcessTerminated: ((Int32?) -> Void)?
        var onDirectoryChanged: ((String?) -> Void)?
        var onTitleChanged: ((String) -> Void)?
        func start(config: TerminalLaunchConfig) {}
        func clear() {}
        func terminateSession() {}
    }

    private func makePanel() -> BottomPanelViewController {
        let panel = BottomPanelViewController(
            issues: IssuesViewController(),
            terminal: TerminalViewController(session: SilentSession()),
            debugConsole: CommandViewController()
        )
        panel.loadViewIfNeeded()
        return panel
    }

    private func labels(of panel: BottomPanelViewController) -> [String] {
        (0..<panel.tabControl.segmentCount).compactMap { panel.tabControl.label(forSegment: $0) }
    }

    @Test func hasIssuesTerminalDebugAndSerialTabs() {
        #expect(labels(of: makePanel()) == ["Issues", "Terminal", "Debug", "Serial"])
    }

    @Test func theSerialTabShowsTheSerialMonitorFillingThePanel() {
        let panel = makePanel()
        panel.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)

        panel.select(.serial)
        panel.view.layoutSubtreeIfNeeded()

        let monitor = panel.serial.view
        #expect(monitor.superview != nil)
        let frame = monitor.convert(monitor.bounds, to: panel.view)
        #expect(frame.width >= 590, "the monitor is \(frame.width) wide")
        #expect(frame.height >= 220, "the monitor is \(frame.height) tall")
    }

    @Test func theIssuesTabCountsErrorsAndWarningsButNotNotes() {
        let panel = makePanel()
        panel.issues.show(BuildResult(
            succeeded: false,
            diagnostics: [
                Diagnostic(severity: .error, message: "a"),
                Diagnostic(severity: .warning, message: "b"),
                Diagnostic(severity: .note, message: "c")
            ],
            compiledSources: [],
            didLink: false,
            log: ""
        ))

        #expect(labels(of: panel).first == "Issues 2")

        panel.issues.clear()
        #expect(labels(of: panel).first == "Issues")
    }

    @Test func theDebugTabShowsTheDebuggerConsoleFillingThePanel() throws {
        let panel = makePanel()
        panel.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)

        panel.select(.debug)
        panel.view.layoutSubtreeIfNeeded()

        let console = panel.debugConsole.view
        #expect(console.superview != nil)
        let frame = console.convert(console.bounds, to: panel.view)
        #expect(frame.width >= 590, "the console is \(frame.width) wide")
        #expect(frame.height >= 220, "the console is \(frame.height) tall")
    }

    @Test func theWindowPutsTheDebuggerConsoleInTheDebugTab() {
        let controller = MainWindowController(
            defaults: UserDefaults(suiteName: "BottomPanelTests")!,
            makeTerminalSession: { SilentSession() }
        )

        #expect(controller.bottomPanel.debugConsole === controller.debugPanels.command)
    }
}
