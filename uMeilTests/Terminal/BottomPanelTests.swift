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
        panel.tabBar.items.map(\.title)
    }

    private func containsSubview<T: NSView>(ofType _: T.Type, in view: NSView) -> Bool {
        if view is T { return true }
        return view.subviews.contains { containsSubview(ofType: T.self, in: $0) }
    }

    @Test func hasIssuesTerminalDebugSerialAndBreakpointsTabs() {
        #expect(labels(of: makePanel()) == ["Issues", "Terminal", "Debug", "Serial", "Breakpoints"])
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
            defaults: TestDefaults(),
            makeTerminalSession: { SilentSession() }
        )

        #expect(controller.bottomPanel.debugConsole === controller.debugPanels.command)
    }

    @Test func tabBarMatchesEditorStyleAndPinsFlushToTopLeadingEdge() throws {
        let panel = makePanel()
        panel.view.frame = NSRect(x: 0, y: 0, width: 640, height: 240)
        panel.view.layoutSubtreeIfNeeded()

        #expect(!containsSubview(ofType: NSSegmentedControl.self, in: panel.view))
        #expect(!containsSubview(ofType: NSTabView.self, in: panel.view))

        let barFrame = panel.tabBar.convert(panel.tabBar.bounds, to: panel.view)
        #expect(barFrame.height == EditorTabBar.height)
        #expect(barFrame.minX == 0)
        #expect(barFrame.width == 640)
        #expect(barFrame.maxY == panel.view.bounds.maxY)

        let firstTab = try #require(panel.tabBar.tabView(at: 0))
        let firstTabFrame = firstTab.convert(firstTab.bounds, to: panel.tabBar)
        #expect(firstTabFrame.minX == 0)
        #expect(panel.tabBar.accessibilityRole() == .tabGroup)
        #expect(firstTab.accessibilityRole() == .radioButton)
        #expect(firstTab.accessibilityValue() as? Bool == true)
    }

    @Test func clickingATabSwitchesSelectionUpdatesAccessibilityAndFiresCallback() throws {
        let panel = makePanel()
        var chosen: [BottomPanelViewController.Tab] = []
        panel.onSelectTab = { chosen.append($0) }

        let terminalTab = try #require(panel.tabBar.tabView(at: BottomPanelViewController.Tab.terminal.rawValue))
        #expect(terminalTab.accessibilityPerformPress())

        #expect(panel.selectedTab == .terminal)
        #expect(chosen == [.terminal])
        #expect(panel.tabBar.items.map(\.isSelected) == [false, true, false, false, false])
        #expect(panel.tabBar.tabView(at: 0)?.accessibilityValue() as? Bool == false)
        #expect(terminalTab.accessibilityValue() as? Bool == true)
    }

    @Test func tabBarHandlesNarrowWidthsWithoutOverflowing() {
        let panel = makePanel()
        panel.view.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        panel.select(.terminal)
        panel.view.layoutSubtreeIfNeeded()

        let barFrame = panel.tabBar.convert(panel.tabBar.bounds, to: panel.view)
        #expect(barFrame.width == 260)
        #expect(barFrame.maxY == panel.view.bounds.maxY)
        for tab in panel.tabBar.tabViews {
            let tabFrame = tab.convert(tab.bounds, to: panel.tabBar)
            #expect(tabFrame.minX >= 0)
            #expect(tabFrame.maxX <= panel.tabBar.bounds.maxX)
        }
    }
}
