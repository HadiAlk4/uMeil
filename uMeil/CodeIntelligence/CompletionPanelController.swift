import AppKit

/// Floating, non-activating popup listing `clangd` completions beneath the caret.
@MainActor
final class CompletionPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var allItems: [LSPCompletionItem] = []
    private(set) var filteredItems: [LSPCompletionItem] = []
    var onAccept: ((LSPCompletionItem) -> Void)?

    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let documentationLabel = NSTextField(labelWithString: "")

    private static let rowHeight: CGFloat = 22
    private static let panelWidth: CGFloat = 440
    private static let maxVisibleRows = 8
    private static let badgeColumnID = NSUserInterfaceItemIdentifier("Badge")
    private static let labelColumnID = NSUserInterfaceItemIdentifier("Label")
    private static let detailColumnID = NSUserInterfaceItemIdentifier("Detail")

    var isVisible: Bool { panel.isVisible }

    var selectedItem: LSPCompletionItem? {
        let row = tableView.selectedRow
        return filteredItems.indices.contains(row) ? filteredItems[row] : nil
    }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        super.init()
        configureViews()
    }

    private func configureViews() {
        configureTableView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        documentationLabel.font = .systemFont(ofSize: 11)
        documentationLabel.textColor = .secondaryLabelColor
        documentationLabel.lineBreakMode = .byTruncatingTail
        documentationLabel.isHidden = true

        let separator = NSBox()
        separator.boxType = .separator
        let docWrapper = NSStackView(views: [separator, documentationLabel])
        docWrapper.orientation = .vertical
        docWrapper.spacing = 4
        docWrapper.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 5, right: 8)
        docWrapper.isHidden = true

        let stack = NSStackView(views: [scrollView, docWrapper])
        stack.orientation = .vertical
        stack.spacing = 4
        panel.contentView = Self.makePopoverContainer(around: stack)
    }

    private func configureTableView() {
        let columns = [(Self.badgeColumnID, 24.0), (Self.labelColumnID, 300.0), (Self.detailColumnID, 100.0)]
        for (identifier, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 4, height: 0)
        tableView.allowsEmptySelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
    }

    /// Filters and ranks `items` matching `prefix` (prefix matches first, then substring matches).
    nonisolated static func filterAndRank(_ items: [LSPCompletionItem], prefix: String) -> [LSPCompletionItem] {
        guard !prefix.isEmpty else { return items }
        let lowered = prefix.lowercased()
        var prefixMatches: [LSPCompletionItem] = []
        var substringMatches: [LSPCompletionItem] = []
        for item in items {
            let candidate = item.filterKey.lowercased()
            if candidate.hasPrefix(lowered) {
                prefixMatches.append(item)
            } else if candidate.contains(lowered) {
                substringMatches.append(item)
            }
        }
        return prefixMatches + substringMatches
    }

    func show(items: [LSPCompletionItem], filter: String, anchoredAt screenRect: NSRect, parentWindow: NSWindow?) {
        allItems = items
        filteredItems = Self.filterAndRank(items, prefix: filter)
        guard !filteredItems.isEmpty else {
            dismiss()
            return
        }
        reloadSelection()
        positionPanel(anchoredAt: screenRect, parentWindow: parentWindow)
        if let parentWindow, panel.parent !== parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func updateFilter(_ prefix: String) {
        guard isVisible else { return }
        filteredItems = Self.filterAndRank(allItems, prefix: prefix)
        guard !filteredItems.isEmpty else {
            dismiss()
            return
        }
        reloadSelection()
        resizePanelHeightOnly()
    }

    func dismiss() {
        allItems = []
        filteredItems = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isVisible, !filteredItems.isEmpty else { return false }
        switch event.keyCode {
        case 125: moveSelection(by: 1)
        case 126: moveSelection(by: -1)
        case 36, 76, 48: acceptSelected()
        case 53: dismiss()
        default: return false
        }
        return true
    }

    @discardableResult
    func acceptSelected() -> Bool {
        guard let item = selectedItem else { return false }
        dismiss()
        onAccept?(item)
        return true
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard filteredItems.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        acceptSelected()
    }

    private func reloadSelection() {
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.scrollRowToVisible(0)
        updateDocumentationFooter()
    }

    private func moveSelection(by delta: Int) {
        guard !filteredItems.isEmpty else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = (current + delta + filteredItems.count) % filteredItems.count
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        updateDocumentationFooter()
    }

    private func updateDocumentationFooter() {
        let doc = selectedItem?.documentation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        documentationLabel.stringValue = doc
        documentationLabel.isHidden = doc.isEmpty
        documentationLabel.superview?.isHidden = doc.isEmpty
    }

    private func positionPanel(anchoredAt screenRect: NSRect, parentWindow: NSWindow?) {
        let size = desiredPanelSize()
        let visibleFrame = parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = max(min(screenRect.minX, visibleFrame.maxX - size.width - 8), visibleFrame.minX + 8)
        var originY = screenRect.minY - size.height - 2
        if originY < visibleFrame.minY + 8 {
            originY = min(screenRect.maxY + 2, visibleFrame.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
    }

    private func resizePanelHeightOnly() {
        var frame = panel.frame
        let newHeight = desiredPanelSize().height
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        panel.setFrame(frame, display: true)
    }

    private func desiredPanelSize() -> NSSize {
        let visibleRows = min(max(filteredItems.count, 1), Self.maxVisibleRows)
        let footerHeight: CGFloat = documentationLabel.isHidden ? 0 : 26
        return NSSize(width: Self.panelWidth, height: CGFloat(visibleRows) * Self.rowHeight + 8 + footerHeight)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDocumentationFooter()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, filteredItems.indices.contains(row) else { return nil }
        let item = filteredItems[row]
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeCell(identifier: identifier)
        Self.populate(cell: cell, identifier: identifier, item: item)
        return cell
    }
}

private extension CompletionPanelController {
    static func makePopoverContainer(around content: NSView) -> NSVisualEffectView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor)
        ])
        return background
    }

    static func populate(
        cell: NSTableCellView,
        identifier: NSUserInterfaceItemIdentifier,
        item: LSPCompletionItem
    ) {
        switch identifier {
        case badgeColumnID:
            cell.textField?.stringValue = item.kind?.badge ?? "•"
            cell.textField?.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            cell.textField?.alignment = .center
            cell.textField?.textColor = badgeColor(for: item.kind)
        case labelColumnID:
            cell.textField?.stringValue = item.displayLabel
            cell.textField?.font = EditorTheme.font.withSize(12)
            cell.textField?.textColor = .labelColor
            cell.textField?.alignment = .left
        case detailColumnID:
            cell.textField?.stringValue = item.detail ?? ""
            cell.textField?.font = .systemFont(ofSize: 11)
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.alignment = .right
        default:
            break
        }
    }

    static func badgeColor(for kind: LSPCompletionItem.Kind?) -> NSColor {
        switch kind {
        case .function, .method, .constructor: .systemBlue
        case .class, .struct, .enum, .interface, .typeParameter: .systemTeal
        case .constant, .enumMember, .value: .systemIndigo
        case .keyword: .systemPink
        default: .secondaryLabelColor
        }
    }

    static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
