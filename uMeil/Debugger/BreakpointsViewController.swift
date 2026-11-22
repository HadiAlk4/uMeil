import AppKit

/// The bottom panel's `Breakpoints` tab: every breakpoint in the project in
/// one place, to turn on and off, delete, or jump to. Once a project has
/// more than one file, the gutter alone cannot show them all.
final class BreakpointsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Which breakpoints are off. The ones that are on come from the debugger.
    var list = BreakpointList() {
        didSet { reload() }
    }
    /// The breakpoints that are on, from the debugger.
    private(set) var enabled: Set<SourceLine> = []
    private(set) var entries: [BreakpointList.Entry] = []

    /// The user ticked or unticked a breakpoint.
    var onSetEnabled: ((SourceLine, Bool) -> Void)?
    /// The user deleted breakpoints, with Delete, the − button, or Remove All.
    var onRemove: (([BreakpointList.Entry]) -> Void)?
    /// The user double-clicked a breakpoint to see its line.
    var onOpen: ((SourceLine) -> Void)?
    /// The code on a breakpoint's line, shown beside it.
    var lineText: ((SourceLine) -> String?)?
    /// Called when breakpoints are added or removed, for the tab's count.
    var onCountChange: (() -> Void)?

    let tableView = DeletableTableView()
    let messageLabel = NSTextField(labelWithString: "")
    let emptyState = EmptyStateView()
    private(set) lazy var removeButton = makeButton(
        symbol: "minus", title: "Remove", tooltip: "Remove the selected breakpoints (⌫)",
        action: #selector(removeSelected(_:))
    )
    private(set) lazy var removeAllButton: NSButton = {
        let button = NSButton(title: "Remove All", target: self, action: #selector(removeAll(_:)))
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        return button
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Breakpoints"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BreakpointsViewController is created in code, not from a nib")
    }

    override func loadView() {
        addColumn("enabled", title: "", width: 24)
        addColumn("location", title: "Location", width: 150)
        addColumn("code", title: "Code", width: 400)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = DebugTableStyle.rowHeight(base: Self.baseRowHeight)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.onDelete = { [weak self] in self?.removeSelected(nil) }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [removeButton, messageLabel, NSView(), removeAllButton])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 8)

        let container = PanelLayout.view(bar: bar, content: scrollView, barAt: .bottom)
        emptyState.show(
            symbol: "circle.dashed",
            title: "No breakpoints",
            detail: "Click a line number in the editor, or press F9, to stop the program there."
        )
        emptyState.pin(over: scrollView, in: container)
        view = container
        reload()
    }

    /// Row height at the standard font size.
    static let baseRowHeight: CGFloat = 20

    private func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        if identifier == "enabled" {
            column.minWidth = width
            column.maxWidth = width
        }
        tableView.addTableColumn(column)
    }

    private func makeButton(symbol: String, title: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = tooltip
        button.setAccessibilityLabel(title)
        return button
    }

    // MARK: - Showing breakpoints

    /// Shows the breakpoints that are on now, with the ones that are off.
    func show(enabled: Set<SourceLine>) {
        self.enabled = enabled
        list.forget(enabled)
        reload()
    }

    func showMessage(_ text: String) {
        loadViewIfNeeded()
        messageLabel.stringValue = text
        messageLabel.toolTip = text
    }

    private func reload() {
        let previousCount = entries.count
        entries = list.entries(enabled: enabled)
        guard isViewLoaded else {
            if entries.count != previousCount { onCountChange?() }
            return
        }
        let selected = Set(tableView.selectedRowIndexes.compactMap { $0 < tableView.numberOfRows ? $0 : nil })
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(selected.filter { $0 < entries.count }), byExtendingSelection: false)
        emptyState.isHidden = !entries.isEmpty
        removeAllButton.isEnabled = !entries.isEmpty
        updateRemoveButton()
        if entries.count != previousCount { onCountChange?() }
    }

    private func updateRemoveButton() {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }

    // MARK: - Actions

    @objc func toggleClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard entries.indices.contains(row) else { return }
        onSetEnabled?(entries[row].location, sender.state == .on)
    }

    @objc func removeSelected(_ sender: Any?) {
        let chosen = tableView.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        guard !chosen.isEmpty else { return }
        onRemove?(chosen)
    }

    @objc func removeAll(_ sender: Any?) {
        guard !entries.isEmpty else { return }
        onRemove?(entries)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard entries.indices.contains(row) else { return }
        onOpen?(entries[row].location)
    }

    // MARK: - NSTableViewDataSource and NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        if identifier.rawValue == "enabled" {
            return checkbox(for: entry, identifier: identifier)
        }
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? Self.makeTextCell(identifier: identifier)
        let label = cell.textField
        label?.font = DebugTableStyle.font
        label?.textColor = entry.isEnabled ? .labelColor : .secondaryLabelColor
        switch identifier.rawValue {
        case "location":
            label?.stringValue = entry.title
            cell.toolTip = entry.location.file.path(percentEncoded: false)
        default:
            let code = lineText?(entry.location)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            label?.stringValue = code
            label?.textColor = .secondaryLabelColor
            cell.toolTip = code
        }
        return cell
    }

    private func checkbox(for entry: BreakpointList.Entry, identifier: NSUserInterfaceItemIdentifier) -> NSView {
        let button = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton
            ?? {
                let created = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleClicked(_:)))
                created.identifier = identifier
                created.controlSize = .small
                return created
            }()
        button.state = entry.isEnabled ? .on : .off
        button.toolTip = entry.isEnabled ? "Turn off this breakpoint" : "Turn on this breakpoint"
        button.setAccessibilityLabel("\(entry.title) enabled")
        return button
    }

    private static func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
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

/// A table that reports the Delete key, to remove what is selected.
final class DeletableTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<Character> = ["\u{7F}", Character(UnicodeScalar(NSDeleteFunctionKey)!)]
        if let key = event.charactersIgnoringModifiers?.first, deleteKeys.contains(key), onDelete != nil {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}
