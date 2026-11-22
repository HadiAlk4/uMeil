import AppKit

/// A small bar of run and step buttons that floats over the top of the
/// editor during a debug session, so the controls are where the user is
/// looking. The buttons send the same actions as the Debug menu, whose keys
/// (F5, F10, F11) their tooltips name.
final class DebugBarView: NSVisualEffectView {
    /// The commands on the bar, left to right. Run and Stop share a place:
    /// only the one that applies shows.
    static let actions: [Selector] = [
        #selector(MainWindowController.debugContinue(_:)),
        #selector(MainWindowController.debugPause(_:)),
        #selector(MainWindowController.debugStepOver(_:)),
        #selector(MainWindowController.debugStepInto(_:)),
        #selector(MainWindowController.debugStepOut(_:)),
        #selector(MainWindowController.debugReset(_:)),
        #selector(MainWindowController.toggleDebugging(_:))
    ]

    /// Decides whether a button's action can run now. Without it, every
    /// button is enabled.
    var isActionEnabled: ((Selector) -> Bool)?

    let buttons: [NSButton]
    private(set) var isRunning = false

    init() {
        buttons = Self.actions.compactMap { action in
            DebugControlsItem.command(for: action).map(Self.makeButton)
        }
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Debug controls")

        // Ending the session stands apart from the run and step buttons.
        let end = buttons.last { $0.action == #selector(MainWindowController.toggleDebugging(_:)) }
        end?.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "End Debug Session")
        end?.toolTip = "End the debug session (⌃F5)"
        end?.setAccessibilityLabel("End Debug Session")
        end?.contentTintColor = .systemRed
        let divider = NSBox()
        divider.boxType = .separator
        let views = buttons.flatMap { $0 === end ? [divider, $0] : [$0] }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 16)
        ])
        show(isRunning: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DebugBarView is created in code, not from a nib")
    }

    /// The actions of the buttons showing now.
    var visibleActions: [Selector] {
        buttons.filter { !$0.isHidden }.compactMap(\.action)
    }

    func button(for action: Selector) -> NSButton? {
        buttons.first { $0.action == action }
    }

    /// Shows Stop while the program runs, and Run while it is stopped.
    func show(isRunning: Bool) {
        self.isRunning = isRunning
        button(for: #selector(MainWindowController.debugContinue(_:)))?.isHidden = isRunning
        button(for: #selector(MainWindowController.debugPause(_:)))?.isHidden = !isRunning
        validate()
    }

    func validate() {
        for button in buttons {
            guard let action = button.action else { continue }
            button.isEnabled = isActionEnabled?(action) ?? true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A CGColor does not follow light and dark mode by itself.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private static func makeButton(_ command: DebugControlsItem.Command) -> NSButton {
        let image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title) ?? NSImage()
        // No target: the action goes to the window controller through the responder chain.
        let button = NSButton(image: image, target: nil, action: command.action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = command.toolTipWithShortcut
        button.setAccessibilityLabel(command.title)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 22)
        ])
        return button
    }
}
