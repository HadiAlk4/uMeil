import AppKit

/// A quiet message centered over a list that has nothing in it yet, such
/// as "No issues" under a checkmark. A blank table looks unfinished; this
/// says why it is empty and what fills it.
final class EmptyStateView: NSView {
    let imageView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EmptyStateView is created in code, not from a nib")
    }

    private func setUp() {
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        imageView.contentTintColor = .tertiaryLabelColor

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        detailLabel.preferredMaxLayoutWidth = 320

        let stack = NSStackView(views: [imageView, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
    }

    /// Shows `title` under the SF Symbol `symbol`, with `detail` below in
    /// smaller text. A `nil` symbol or detail leaves that part out.
    func show(symbol: String?, title: String, detail: String? = nil, tint: NSColor = .tertiaryLabelColor) {
        imageView.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        imageView.isHidden = imageView.image == nil
        imageView.contentTintColor = tint
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail?.isEmpty ?? true
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ". "))
    }

    /// Lets clicks reach the list underneath, so it can still take focus.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Pins `self` over `view`, filling it.
    func pin(over view: NSView, in container: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(self, positioned: .above, relativeTo: view)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: view.topAnchor),
            bottomAnchor.constraint(equalTo: view.bottomAnchor),
            leadingAnchor.constraint(equalTo: view.leadingAnchor),
            trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
}
