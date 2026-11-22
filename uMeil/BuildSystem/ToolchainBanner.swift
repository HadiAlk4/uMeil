import AppKit

/// A strip across the top of the issues panel that says a tool is missing
/// and offers to install it, in place of an error line in the list.
final class ToolchainBanner: NSView {
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private(set) lazy var installButton = NSButton(
        title: "Install", target: self, action: #selector(installClicked(_:))
    )
    private(set) lazy var dismissButton: NSButton = {
        let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss") ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(dismissClicked(_:)))
        button.isBordered = false
        button.toolTip = "Dismiss"
        return button
    }()

    /// The tools the banner offers to install.
    private(set) var tools: [Tool] = []
    /// Called with `tools` when the user clicks Install.
    var onInstall: (([Tool]) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Missing tools")

        let icon = NSImageView(
            image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                ?? NSImage()
        )
        icon.contentTintColor = .systemYellow
        icon.setContentHuggingPriority(.required, for: .horizontal)

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        messageLabel.maximumNumberOfLines = 2
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        installButton.bezelStyle = .push
        installButton.controlSize = .small
        installButton.keyEquivalent = ""
        installButton.toolTip = "Download and install the missing tools"

        let stack = NSStackView(views: [icon, messageLabel, NSView(), installButton, dismissButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolchainBanner is created in code, not from a nib")
    }

    /// Shows the banner for `tools`, or hides it when there are none.
    func show(_ tools: [Tool]) {
        self.tools = tools
        messageLabel.stringValue = tools.map(\.missingMessage).joined(separator: " ")
        installButton.title = tools.count == 1 ? "Install \(tools[0].shortName)" : "Install"
        isHidden = tools.isEmpty
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.14).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @objc private func installClicked(_ sender: Any?) {
        onInstall?(tools)
    }

    @objc private func dismissClicked(_ sender: Any?) {
        show([])
    }
}

extension Tool {
    /// The tool's name on a button, as in "Install GCC".
    var shortName: String {
        switch self {
        case .compiler: "GCC"
        case .debugger: "GDB"
        case .openOCD: "OpenOCD"
        case .clangd: "clangd"
        }
    }
}
