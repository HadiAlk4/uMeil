import AppKit

/// The toolbar's debugger buttons, in one item: Debug, which starts and ends
/// a session, and the run and step buttons, which only show during one.
///
/// Showing and hiding buttons inside one item, rather than adding and
/// removing toolbar items, keeps the toolbar itself unchanged.
@MainActor
final class DebugControlsItem: NSToolbarItem {
    /// One button. The names follow the Keil µVision debugger, which the course uses.
    struct Command {
        var title: String
        var symbol: String
        var toolTip: String
        var action: Selector
        /// The Debug menu's key for it, as Keil µVision has it.
        var shortcut: String?
        /// True for stop actions that render in red when available.
        var isStopAction = false

        /// The command name, description, and menu shortcut, as in
        /// "Step Over — Run one line, including any function it calls (F10)".
        var toolTipWithShortcut: String {
            let base = "\(title) — \(toolTip)"
            return shortcut.map { "\(base) (\($0))" } ?? base
        }
    }

    static let toggle = Command(
        title: "Debug",
        symbol: "ladybug",
        toolTip: "Start a debug session",
        action: #selector(MainWindowController.toggleDebugging(_:)),
        shortcut: "⌃F5"
    )

    static let endSessionSymbol = "ladybug.slash"
    static let endSessionTitle = "End Debug Session"
    static let endSessionToolTip = "End Debug Session — Stop the debug session (⌃F5)"

    static func command(for action: Selector) -> Command? {
        ([toggle] + sessionCommands).first { $0.action == action }
    }

    static let sessionCommands = [
        Command(
            title: "Reset",
            symbol: "arrow.counterclockwise",
            toolTip: "Reset the chip and stop at its first instruction",
            action: #selector(MainWindowController.debugReset(_:))
        ),
        Command(
            title: "Run",
            symbol: "play.fill",
            toolTip: "Run until a breakpoint",
            action: #selector(MainWindowController.debugContinue(_:)),
            shortcut: "F5"
        ),
        Command(
            title: "Stop",
            symbol: "pause.fill",
            toolTip: "Stop the running program where it is",
            action: #selector(MainWindowController.debugPause(_:)),
            isStopAction: true
        ),
        Command(
            title: "Step",
            symbol: "arrow.down.right",
            toolTip: "Run one line, going into a function it calls",
            action: #selector(MainWindowController.debugStepInto(_:)),
            shortcut: "F11"
        ),
        Command(
            title: "Step Over",
            symbol: "arrow.turn.up.right",
            toolTip: "Run one line, including any function it calls",
            action: #selector(MainWindowController.debugStepOver(_:)),
            shortcut: "F10"
        ),
        Command(
            title: "Step Out",
            symbol: "arrow.up.left",
            toolTip: "Run until this function returns",
            action: #selector(MainWindowController.debugStepOut(_:)),
            shortcut: "⌃F11"
        ),
        Command(
            title: "Run to Cursor Line",
            symbol: "arrow.right.to.line",
            toolTip: "Run until the line the cursor is on",
            action: #selector(MainWindowController.debugRunToCursor(_:)),
            shortcut: "⌃F10"
        )
    ]

    /// Decides whether a button's action can run now. Without it, every
    /// button is enabled.
    var isActionEnabled: ((Selector) -> Bool)? {
        didSet { validate() }
    }

    let toggleButton: NSButton
    let sessionButtons: [NSButton]
    private let toggleToolbarButton: ToolbarButton
    private let sessionToolbarButtons: [ToolbarButton]
    private(set) var isSessionActive = false

    init(itemIdentifier: NSToolbarItem.Identifier, isSessionActive: Bool) {
        let toggleBtn = Self.makeButton(Self.toggle)
        let sessionBtns = Self.sessionCommands.map(Self.makeButton)
        toggleToolbarButton = toggleBtn
        sessionToolbarButtons = sessionBtns
        toggleButton = toggleBtn
        sessionButtons = sessionBtns
        super.init(itemIdentifier: itemIdentifier)
        label = "Debug"
        let stack = NSStackView(views: [toggleButton] + sessionButtons)
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.detachesHiddenViews = true
        view = stack
        showSession(isSessionActive)
    }

    /// The actions of the buttons showing now.
    var visibleActions: [Selector] {
        ([toggleButton] + sessionButtons).filter { !$0.isHidden }.compactMap(\.action)
    }

    func button(for action: Selector) -> NSButton? {
        ([toggleButton] + sessionButtons).first { $0.action == action }
    }

    func showSession(_ isActive: Bool) {
        isSessionActive = isActive
        sessionButtons.forEach { $0.isHidden = !isActive }
        toggleToolbarButton.symbolName = isActive ? Self.endSessionSymbol : Self.toggle.symbol
        toggleToolbarButton.activeTintColor = isActive ? ToolbarIcon.stopTintColor : ToolbarIcon.enabledTintColor
        toggleToolbarButton.toolTip = isActive ? Self.endSessionToolTip : Self.toggle.toolTipWithShortcut
        toggleToolbarButton.setAccessibilityLabel(isActive ? Self.endSessionTitle : Self.toggle.title)
        validate()
    }

    override func validate() {
        toggleToolbarButton.symbolName = isSessionActive ? Self.endSessionSymbol : Self.toggle.symbol
        toggleToolbarButton.activeTintColor = isSessionActive ? ToolbarIcon.stopTintColor : ToolbarIcon.enabledTintColor
        toggleToolbarButton.isEnabled = toggleToolbarButton.action.map { isActionEnabled?($0) ?? true } ?? true

        for (button, command) in zip(sessionToolbarButtons, Self.sessionCommands) {
            button.activeTintColor = command.isStopAction ? ToolbarIcon.stopTintColor : ToolbarIcon.enabledTintColor
            button.isEnabled = button.action.map { isActionEnabled?($0) ?? true } ?? true
        }
    }

    private static func makeButton(_ command: Command) -> ToolbarButton {
        let tint = command.isStopAction ? ToolbarIcon.stopTintColor : ToolbarIcon.enabledTintColor
        return ToolbarButton(
            title: command.title,
            symbol: command.symbol,
            toolTip: command.toolTipWithShortcut,
            action: command.action,
            activeTintColor: tint
        )
    }
}
