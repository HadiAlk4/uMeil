import AppKit

/// A strip of left-aligned tabs pinned to the top edge of a pane (the bottom
/// workspace panel and the debugger's auxiliary inspector), matching
/// `EditorTabBar`'s height, typography, dividers, active accent line, and
/// bottom hairline separator.
final class PaneTabBar: NSView {
    struct Item: Equatable {
        var title: String
        var isSelected: Bool
    }

    static let height: CGFloat = EditorTabBar.height

    /// Called when the user selects a tab by index.
    var onSelectIndex: ((Int) -> Void)?

    private(set) var items: [Item] = []
    private let tabStack = NSStackView()
    private let trailingStack = NSStackView()
    private let separator = NSBox()
    private var trailingConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        tabStack.orientation = .horizontal
        tabStack.spacing = 0
        tabStack.alignment = .centerY
        tabStack.distribution = .fill
        tabStack.detachesHiddenViews = true
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tabStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        trailingStack.orientation = .horizontal
        trailingStack.spacing = 6
        trailingStack.alignment = .centerY
        trailingStack.detachesHiddenViews = true
        trailingStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailingStack.setClippingResistancePriority(.defaultLow, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tabStack)
        addSubview(separator)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            tabStack.topAnchor.constraint(equalTo: topAnchor),
            tabStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            tabStack.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityRole(.tabGroup)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneTabBar is created in code, not from a nib")
    }

    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func accessibilityTabs() -> [Any]? {
        tabViews
    }

    /// Installs accessory views to the right of the tab strip (such as status
    /// text and action buttons). Passing an empty array removes them.
    func setTrailingViews(_ views: [NSView]) {
        NSLayoutConstraint.deactivate(trailingConstraints)
        trailingConstraints = []
        trailingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        trailingStack.removeFromSuperview()

        guard !views.isEmpty else { return }
        views.forEach { trailingStack.addArrangedSubview($0) }
        addSubview(trailingStack)
        trailingConstraints = [
            trailingStack.topAnchor.constraint(equalTo: topAnchor),
            trailingStack.bottomAnchor.constraint(equalTo: separator.topAnchor),
            trailingStack.leadingAnchor.constraint(equalTo: tabStack.trailingAnchor),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ]
        NSLayoutConstraint.activate(trailingConstraints)
    }

    func show(_ items: [Item]) {
        guard items != self.items else { return }
        self.items = items

        let existing = tabViews
        if existing.count == items.count {
            for (tab, item) in zip(existing, items) {
                tab.update(item)
            }
            return
        }

        tabStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, item) in items.enumerated() {
            let tab = TabView(index: index, item: item)
            tab.onSelect = { [weak self] in self?.onSelectIndex?(index) }
            tabStack.addArrangedSubview(tab)
            tabStack.addArrangedSubview(Divider())
        }
    }

    /// All tab views in display order, for tests and accessibility.
    var tabViews: [TabView] {
        tabStack.arrangedSubviews.compactMap { $0 as? TabView }
    }

    /// The tab at `index`, for tests and accessibility.
    func tabView(at index: Int) -> TabView? {
        let views = tabViews
        return views.indices.contains(index) ? views[index] : nil
    }

    private final class Divider: NSView {
        override var allowsVibrancy: Bool { false }
        override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 16) }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            bounds.fill()
        }
    }

    /// One tab in a pane tab bar: a label with an active top accent line.
    final class TabView: NSView {
        let index: Int
        private(set) var item: Item
        var onSelect: (() -> Void)?

        let label: NSTextField
        private var isHovering = false {
            didSet {
                if oldValue != isHovering {
                    needsDisplay = true
                }
            }
        }

        init(index: Int, item: Item) {
            self.index = index
            self.item = item
            label = NSTextField(labelWithString: item.title)
            super.init(frame: .zero)

            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            // Stay below windowSizeStayPut (500) so narrow splits truncate titles instead of refusing to resize.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultHigh, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: PaneTabBar.height - 1)
            ])

            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            applyItem()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("TabView is created in code, not from a nib")
        }

        override var allowsVibrancy: Bool { false }
        override var isFlipped: Bool { false }

        func update(_ item: Item) {
            guard item != self.item else { return }
            self.item = item
            applyItem()
        }

        private func applyItem() {
            label.stringValue = item.title
            label.font = .systemFont(ofSize: 12, weight: item.isSelected ? .medium : .regular)
            label.textColor = item.isSelected ? .labelColor : .secondaryLabelColor
            setAccessibilityLabel(item.title)
            setAccessibilityValue(item.isSelected)
            needsDisplay = true
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                isHovering = false
            }
        }

        override func mouseEntered(with event: NSEvent) { isHovering = true }
        override func mouseExited(with event: NSEvent) { isHovering = false }

        override func mouseDown(with event: NSEvent) {
            onSelect?()
        }

        override func accessibilityPerformPress() -> Bool {
            onSelect?()
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            if item.isSelected {
                NSColor.textBackgroundColor.setFill()
                bounds.fill()
                // A line along the top in the accent color marks the showing tab.
                NSColor.controlAccentColor.setFill()
                NSRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2).fill()
            } else if isHovering {
                NSColor.labelColor.withAlphaComponent(0.05).setFill()
                bounds.fill()
            }
        }
    }
}

/// Hosts multiple child view controllers behind a top-pinned `PaneTabBar`,
/// replacing `NSTabViewController`'s centered floating tab strip while keeping
/// `tabViewItems` and `selectedTabViewItemIndex` compatible.
final class PaneTabViewController: NSViewController {
    let tabBar = PaneTabBar()
    private let contentContainer = NSView()
    private var activeConstraints: [NSLayoutConstraint] = []

    private(set) var tabViewItems: [NSTabViewItem] = []

    var selectedTabViewItemIndex: Int = -1 {
        didSet {
            guard tabViewItems.indices.contains(selectedTabViewItemIndex) else {
                if tabViewItems.isEmpty {
                    selectedTabViewItemIndex = -1
                } else {
                    selectedTabViewItemIndex = oldValue
                }
                return
            }
            if isViewLoaded {
                refreshTabBar()
                applySelectedTab()
            }
        }
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaneTabViewController is created in code, not from a nib")
    }

    func addTabViewItem(_ item: NSTabViewItem) {
        tabViewItems.append(item)
        if let child = item.viewController {
            addChild(child)
        }
        if selectedTabViewItemIndex < 0 {
            selectedTabViewItemIndex = 0
        } else if isViewLoaded {
            refreshTabBar()
        }
    }

    override func loadView() {
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

        tabBar.onSelectIndex = { [weak self] index in
            self?.selectedTabViewItemIndex = index
        }

        view = background
        refreshTabBar()
        applySelectedTab()
    }

    private func refreshTabBar() {
        guard isViewLoaded else { return }
        let items = tabViewItems.enumerated().map { index, item in
            PaneTabBar.Item(title: item.label, isSelected: index == selectedTabViewItemIndex)
        }
        tabBar.show(items)
    }

    private func applySelectedTab() {
        NSLayoutConstraint.deactivate(activeConstraints)
        activeConstraints = []
        for subview in contentContainer.subviews {
            subview.removeFromSuperview()
        }
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              let childView = tabViewItems[selectedTabViewItemIndex].viewController?.view
        else { return }

        childView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(childView)
        activeConstraints = [
            childView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            childView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            childView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor)
        ]
        NSLayoutConstraint.activate(activeConstraints)
    }
}
