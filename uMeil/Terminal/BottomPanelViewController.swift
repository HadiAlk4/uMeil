import AppKit

/// Hosts the collapsible bottom workspace tabs (`Issues` and `Terminal`) below
/// the code editor.
final class BottomPanelViewController: NSViewController {
    enum Tab: Int, CaseIterable {
        case issues
        case terminal

        var title: String {
            switch self {
            case .issues: "Issues"
            case .terminal: "Terminal"
            }
        }
    }

    let issues: IssuesViewController
    let terminal: TerminalViewController

    private(set) var selectedTab: Tab = .issues
    var onSelectTab: ((Tab) -> Void)?
    var onRestartTerminal: (() -> Void)?
    var onClose: (() -> Void)?

    let tabControl = NSSegmentedControl(
        labels: Tab.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
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

    init(issues: IssuesViewController, terminal: TerminalViewController) {
        self.issues = issues
        self.terminal = terminal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BottomPanelViewController is created in code, not from a nib")
    }

    override func loadView() {
        tabControl.segmentStyle = .texturedRounded
        tabControl.controlSize = .small
        tabControl.selectedSegment = selectedTab.rawValue
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))

        terminalStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        terminalStatusLabel.textColor = .secondaryLabelColor
        terminalStatusLabel.lineBreakMode = .byTruncatingMiddle
        terminalStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [
            tabControl,
            terminalStatusLabel,
            NSView(),
            clearButton,
            restartButton,
            closeButton
        ])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)

        let divider = NSBox()
        divider.boxType = .separator

        let stack = NSStackView(views: [header, divider, contentContainer])
        stack.orientation = .vertical
        stack.spacing = 0

        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        ])
        view = background

        addChild(issues)
        addChild(terminal)
        terminal.onStatusChange = { [weak self] in self?.updateTerminalHeader() }
        applyTab(selectedTab)
    }

    func select(_ tab: Tab) {
        loadViewIfNeeded()
        guard selectedTab != tab || contentContainer.subviews.isEmpty else { return }
        selectedTab = tab
        tabControl.selectedSegment = tab.rawValue
        applyTab(tab)
    }

    private func applyTab(_ tab: Tab) {
        NSLayoutConstraint.deactivate(activeConstraints)
        for subview in contentContainer.subviews {
            subview.removeFromSuperview()
        }

        let child: NSViewController = tab == .issues ? issues : terminal
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

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = Tab(rawValue: sender.selectedSegment) else { return }
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
        return button
    }
}
