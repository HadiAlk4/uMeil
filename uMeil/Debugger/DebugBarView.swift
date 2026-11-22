import AppKit

/// A small bar of run and step buttons and the current debug status that floats
/// over the top of the editor during a debug session, so the controls and stop
/// location are where the user is looking. The buttons send the same actions as
/// the Debug menu, whose keys (F5, F10, F11) their tooltips name.
final class DebugBarView: NSVisualEffectView {
    /// The kind of status shown beside the debug controls.
    enum StatusKind: Equatable {
        /// Starting the session (shows a small spinner).
        case starting
        /// Program is running on the chip.
        case running
        /// Stopped at a breakpoint, step, or pause.
        case stopped
        /// Stopped on a fault signal or a debugger command was refused.
        case error
    }

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
    let statusLabel = NSTextField(labelWithString: "")
    let statusDot = NSImageView()
    private(set) var isRunning = false
    private(set) var statusKind: StatusKind?

    private let statusSpinner = NSProgressIndicator()
    private let statusDivider = NSBox()
    private let statusGroup: NSStackView

    init() {
        buttons = Self.actions.compactMap { action in
            DebugControlsItem.command(for: action).map(Self.makeButton)
        }
        statusGroup = NSStackView(views: [statusSpinner, statusDot, statusLabel])
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
        configureStatusViews()

        let views = buttons.flatMap { $0 === end ? [divider, $0] : [$0] } + [statusDivider, statusGroup]

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        if let end {
            stack.setCustomSpacing(4, after: end)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 16),
            statusDivider.heightAnchor.constraint(equalToConstant: 16)
        ])
        show(isRunning: false)
        showStatus("")
    }

    private func configureStatusViews() {
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.isHidden = true

        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.setContentHuggingPriority(.required, for: .horizontal)
        statusDot.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setAccessibilityLabel("Debug status")

        statusGroup.orientation = .horizontal
        statusGroup.alignment = .centerY
        statusGroup.spacing = 5
        statusGroup.detachesHiddenViews = true
        statusGroup.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)

        statusDivider.boxType = .separator
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

    /// Shows the debugger's current status beside the controls, or hides the
    /// status section when `text` is empty.
    func showStatus(_ text: String, kind: StatusKind = .stopped) {
        let isEmpty = text.isEmpty
        statusKind = isEmpty ? nil : kind
        statusLabel.stringValue = text
        statusLabel.toolTip = isEmpty ? nil : text
        statusGroup.toolTip = isEmpty ? nil : text
        statusDivider.isHidden = isEmpty
        statusGroup.isHidden = isEmpty
        guard !isEmpty else {
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            return
        }
        switch kind {
        case .starting:
            statusSpinner.isHidden = false
            statusSpinner.startAnimation(nil)
            statusDot.isHidden = true
            statusLabel.textColor = .secondaryLabelColor
        case .running:
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            statusDot.isHidden = false
            statusDot.contentTintColor = .systemGreen
            statusLabel.textColor = .labelColor
        case .stopped:
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            statusDot.isHidden = false
            statusDot.contentTintColor = .controlAccentColor
            statusLabel.textColor = .labelColor
        case .error:
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            statusDot.isHidden = false
            statusDot.contentTintColor = .systemRed
            statusLabel.textColor = .labelColor
        }
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
        // The window controller sets itself as the target when it installs the bar.
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
