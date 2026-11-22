import AppKit

/// The strip of tabs above the code, one per open file. Clicking a tab shows
/// its file; its × closes it. A dot marks a file with unsaved changes.
final class EditorTabBar: NSView {
    struct Item: Equatable {
        var url: URL
        var title: String
        var isModified: Bool
        var isSelected: Bool
    }

    var onSelect: ((URL) -> Void)?
    var onClose: ((URL) -> Void)?

    private(set) var items: [Item] = []
    private let stack = NSStackView()
    private let scrollView = NSScrollView()

    static let height: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Many tabs scroll sideways instead of squeezing their names away.
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        scrollView.documentView = documentView
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(separator)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor)
        ])
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Open files")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorTabBar is created in code, not from a nib")
    }

    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    func show(_ items: [Item]) {
        guard items != self.items else { return }
        self.items = items
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let tab = TabView(item: item)
            tab.onSelect = { [weak self] in self?.onSelect?(item.url) }
            tab.onClose = { [weak self] in self?.onClose?(item.url) }
            stack.addArrangedSubview(tab)
            stack.addArrangedSubview(Divider())
        }
        isHidden = items.isEmpty
        if let selected = stack.arrangedSubviews.first(where: { ($0 as? TabView)?.item.isSelected == true }) {
            layoutSubtreeIfNeeded()
            selected.scrollToVisible(selected.bounds)
        }
    }

    /// The tab for `url`, for tests and accessibility.
    func tabView(for url: URL) -> TabView? {
        stack.arrangedSubviews.lazy.compactMap { $0 as? TabView }.first { $0.item.url == url }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class Divider: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 16) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            bounds.fill()
        }
    }

    /// One tab: a file name with a close button, or a dot while unsaved.
    final class TabView: NSView {
        let item: Item
        var onSelect: (() -> Void)?
        var onClose: (() -> Void)?

        let closeButton: NSButton
        private let label: NSTextField
        private var isHovering = false {
            didSet { updateCloseButton() }
        }

        init(item: Item) {
            self.item = item
            label = NSTextField(labelWithString: item.title)
            closeButton = NSButton(image: NSImage(), target: nil, action: nil)
            super.init(frame: .zero)

            let icon = FileIcon(name: item.url.lastPathComponent, isDirectory: false)
            let iconView = NSImageView(image: icon.image ?? NSImage())
            iconView.contentTintColor = icon.color
            iconView.symbolConfiguration = .init(pointSize: 11, weight: .regular)

            label.font = .systemFont(ofSize: 12, weight: item.isSelected ? .medium : .regular)
            label.textColor = item.isSelected ? .labelColor : .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle

            closeButton.isBordered = false
            closeButton.bezelStyle = .accessoryBarAction
            closeButton.target = self
            closeButton.action = #selector(closeClicked)
            closeButton.setAccessibilityLabel("Close \(item.title)")
            closeButton.toolTip = "Close Tab"
            updateCloseButton()

            let row = NSStackView(views: [iconView, label, closeButton])
            row.orientation = .horizontal
            row.spacing = 5
            row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 6)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                heightAnchor.constraint(equalToConstant: EditorTabBar.height - 1),
                widthAnchor.constraint(lessThanOrEqualToConstant: 240),
                closeButton.widthAnchor.constraint(equalToConstant: 16),
                closeButton.heightAnchor.constraint(equalToConstant: 16)
            ])
            toolTip = item.url.path(percentEncoded: false)
            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel(item.isModified ? "\(item.title), edited" : item.title)
            setAccessibilityValue(item.isSelected)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("TabView is created in code, not from a nib")
        }

        /// The × shows on the showing tab and under the mouse. An unsaved
        /// tab shows a dot instead until the mouse is over it, as in Xcode.
        private func updateCloseButton() {
            let showsDot = item.isModified && !isHovering
            let symbol = showsDot ? "circle.fill" : "xmark"
            let size: CGFloat = showsDot ? 7 : 9
            closeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .bold))
            closeButton.contentTintColor = .secondaryLabelColor
            closeButton.alphaValue = showsDot || isHovering || item.isSelected ? 1 : 0
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true }
        override func mouseExited(with event: NSEvent) { isHovering = false }

        override func mouseDown(with event: NSEvent) {
            onSelect?()
        }

        /// A middle click closes the tab, as in browsers.
        override func otherMouseDown(with event: NSEvent) {
            onClose?()
        }

        override func accessibilityPerformPress() -> Bool {
            onSelect?()
            return true
        }

        @objc private func closeClicked() {
            onClose?()
        }

        override func draw(_ dirtyRect: NSRect) {
            guard item.isSelected else { return }
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            // A line along the top in the accent color marks the showing tab.
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
        }

        override var isFlipped: Bool { false }
    }
}
