import AppKit

/// Hosts the collapsible bottom workspace tabs (`Issues`, `Terminal`,
/// `Debug`, `Serial` and `Breakpoints`) below the code editor.
final class BottomPanelViewController: NSViewController {
    enum Tab: Int, CaseIterable {
        case issues
        case terminal
        case debug
        case serial
        case breakpoints

        var title: String {
            switch self {
            case .issues: "Issues"
            case .terminal: "Terminal"
            case .debug: "Debug"
            case .serial: "Serial"
            case .breakpoints: "Breakpoints"
            }
        }
    }

    let issues: IssuesViewController
    let terminal: TerminalViewController
    /// The debugger's console: GDB and OpenOCD output, and a field for commands.
    let debugConsole: CommandViewController
    /// The board's serial port: what the firmware prints, and a field for sending lines.
    let serial: SerialMonitorViewController
    /// Every breakpoint in the project, to turn on and off or delete.
    let breakpoints: BreakpointsViewController

    private(set) var selectedTab: Tab = .issues
    var onSelectTab: ((Tab) -> Void)?
    var onRestartTerminal: (() -> Void)?
    var onClose: (() -> Void)?

    let tabBar = PaneTabBar()
    private let terminalStatusLabel = NSTextField(labelWithString: "")
    private lazy var clearButton = makeActionButton(
        symbol: "trash",
        title: "Clear",
        tooltip: "Clear terminal scrollback",
        action: #selector(clearClicked(_:))
    )
    private lazy var restartButton = makeActionButton(
        symbol: "arrow.clockwise",
        title: "Restart",
        tooltip: "Restart shell in the project folder",
        action: #selector(restartClicked(_:))
    )
    private lazy var closeButton = makeActionButton(
        symbol: "xmark",
        title: "Hide Panel",
        tooltip: "Hide bottom panel (⌘J)",
        action: #selector(closeClicked(_:))
    )
    private let contentContainer = NSView()
    private var activeConstraints: [NSLayoutConstraint] = []

    init(
        issues: IssuesViewController,
        terminal: TerminalViewController,
        debugConsole: CommandViewController,
        serial: SerialMonitorViewController = SerialMonitorViewController(),
        breakpoints: BreakpointsViewController = BreakpointsViewController()
    ) {
        self.issues = issues
        self.terminal = terminal
        self.debugConsole = debugConsole
        self.serial = serial
        self.breakpoints = breakpoints
        super.init(nibName: nil, bundle: nil)
        issues.onDiagnosticsChange = { [weak self] in self?.refreshTabBar() }
        breakpoints.onCountChange = { [weak self] in self?.refreshTabBar() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BottomPanelViewController is created in code, not from a nib")
    }

    override func loadView() {
        terminalStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        terminalStatusLabel.textColor = .secondaryLabelColor
        terminalStatusLabel.lineBreakMode = .byTruncatingMiddle
        terminalStatusLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        tabBar.setAccessibilityLabel("Bottom panel")
        tabBar.onSelectIndex = { [weak self] index in self?.tabSelected(at: index) }
        tabBar.setTrailingViews([
            terminalStatusLabel,
            spacer,
            clearButton,
            restartButton,
            closeButton
        ])

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(tabBar)
        background.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: background.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        ])
        view = background

        addChild(issues)
        addChild(terminal)
        addChild(debugConsole)
        addChild(serial)
        addChild(breakpoints)
        terminal.onStatusChange = { [weak self] in self?.updateTerminalHeader() }
        refreshTabBar()
        applyTab(selectedTab)
    }

    /// The label on each tab. Issues shows how many errors and warnings the
    /// last build reported, as in "Issues 3".
    func title(for tab: Tab) -> String {
        switch tab {
        case .issues:
            let count = issues.diagnostics.count { $0.severity != .note }
            return count > 0 ? "\(tab.title) \(count)" : tab.title
        case .breakpoints:
            let count = breakpoints.entries.count
            return count > 0 ? "\(tab.title) \(count)" : tab.title
        case .terminal, .debug, .serial:
            return tab.title
        }
    }

    private func refreshTabBar() {
        guard isViewLoaded else { return }
        let items = Tab.allCases.map { tab in
            PaneTabBar.Item(title: title(for: tab), isSelected: tab == selectedTab)
        }
        tabBar.show(items)
    }

    func select(_ tab: Tab) {
        loadViewIfNeeded()
        guard selectedTab != tab || contentContainer.subviews.isEmpty else { return }
        selectedTab = tab
        refreshTabBar()
        applyTab(tab)
    }

    private func applyTab(_ tab: Tab) {
        NSLayoutConstraint.deactivate(activeConstraints)
        for subview in contentContainer.subviews {
            subview.removeFromSuperview()
        }

        let child: NSViewController = switch tab {
        case .issues: issues
        case .terminal: terminal
        case .debug: debugConsole
        case .serial: serial
        case .breakpoints: breakpoints
        }
        let childView = child.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(childView)
        activeConstraints = [
            childView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            childView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)
        ]
        NSLayoutConstraint.activate(activeConstraints)
        updateTerminalHeader()
    }

    private func updateTerminalHeader() {
        let showingTerminal = selectedTab == .terminal
        terminalStatusLabel.isHidden = !showingTerminal
        clearButton.isHidden = !showingTerminal
        restartButton.isHidden = !showingTerminal
        if showingTerminal {
            terminalStatusLabel.stringValue = terminal.statusText
        }
    }

    private func tabSelected(at index: Int) {
        guard let tab = Tab(rawValue: index) else { return }
        select(tab)
        onSelectTab?(tab)
    }

    @objc private func clearClicked(_ sender: Any?) {
        terminal.clear()
    }

    @objc private func restartClicked(_ sender: Any?) {
        onRestartTerminal?()
    }

    @objc private func closeClicked(_ sender: Any?) {
        onClose?()
    }

    private func makeActionButton(
        symbol: String,
        title: String,
        tooltip: String,
        action: Selector
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let button = NSButton(image: image ?? NSImage(), target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = tooltip
        button.setAccessibilityLabel(title)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        return button
    }
}
