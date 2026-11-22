import AppKit

/// The toolbar's debugger buttons, in one item: Debug, which starts and ends
/// a session, and the run and step buttons, which only show during one.
///
/// Showing and hiding buttons inside one item, rather than adding and
/// removing toolbar items, keeps the toolbar itself unchanged.
final class DebugControlsItem: NSToolbarItem {
    /// One button. The names follow the Keil µVision debugger, which the course uses.
    struct Command {
        var title: String
        var symbol: String
        var toolTip: String
        var action: Selector
        /// The Debug menu's key for it, as Keil µVision has it.
        var shortcut: String?

        /// The tooltip with the key that does the same, as in "Run until a breakpoint (F5)".
        var toolTipWithShortcut: String {
            shortcut.map { "\(toolTip) (\($0))" } ?? toolTip
        }
    }

    static let toggle = Command(
        title: "Debug",
        symbol: "ladybug",
        toolTip: "Start a debug session",
        action: #selector(MainWindowController.toggleDebugging(_:)),
        shortcut: "⌃F5"
    )

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
            action: #selector(MainWindowController.debugPause(_:))
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
    var isActionEnabled: ((Selector) -> Bool)?

    let toggleButton: NSButton
    let sessionButtons: [NSButton]
    private(set) var isSessionActive = false

    init(itemIdentifier: NSToolbarItem.Identifier, isSessionActive: Bool) {
        toggleButton = Self.makeButton(Self.toggle)
        sessionButtons = Self.sessionCommands.map(Self.makeButton)
        super.init(itemIdentifier: itemIdentifier)
        label = "Debug"
        let stack = NSStackView(views: [toggleButton] + sessionButtons)
        stack.spacing = 2
        stack.detachesHiddenViews = true
        view = stack
        showSession(isSessionActive)
    }

    /// The actions of the buttons showing now.
    var visibleActions: [Selector] {
        ([toggleButton] + sessionButtons).filter { !$0.isHidden }.compactMap(\.action)
    }

    func showSession(_ isActive: Bool) {
        isSessionActive = isActive
        sessionButtons.forEach { $0.isHidden = !isActive }
        toggleButton.image = NSImage(
            systemSymbolName: isActive ? "ladybug.slash" : Self.toggle.symbol,
            accessibilityDescription: Self.toggle.title
        )
        toggleButton.toolTip = isActive ? "End the debug session (⌃F5)" : Self.toggle.toolTipWithShortcut
        validate()
    }

    override func validate() {
        for button in [toggleButton] + sessionButtons {
            guard let action = button.action else { continue }
            button.isEnabled = isActionEnabled?(action) ?? true
        }
    }

    private static func makeButton(_ command: Command) -> NSButton {
        let image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title) ?? NSImage()
        // No target: the action goes to the window controller through the responder chain.
        let button = NSButton(image: image, target: nil, action: command.action)
        button.bezelStyle = .toolbar
        button.toolTip = command.toolTipWithShortcut
        button.setAccessibilityLabel(command.title)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return button
    }
}
