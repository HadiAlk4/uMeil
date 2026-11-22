import AppKit

/// The `Watch 1` panel: lets users add and remove C expressions to monitor
/// across stops, highlighting values that changed.
final class WatchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct Entry: Equatable {
        var expression: String
        var value: String
        var isChanged: Bool = false
    }

    let inputField = NSTextField()
    let tableView = NSTableView()

    private(set) var entries: [Entry] = []
    private var previousValues: [String: String] = [:]
    /// When the values last changed, so their cells flash only then.
    private var updatedAt: Date?

    /// Called when watch expressions change and should be re-evaluated.
    var onExpressionsChanged: (([String]) -> Void)?

    var expressions: [String] {
        entries.map(\.expression)
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Watch 1"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WatchViewController is created in code, not from a nib")
    }

    override func loadView() {
        let prompt = NSTextField(labelWithString: "Watch:")
        inputField.placeholderString = "Enter expression…"
        inputField.font = EditorTheme.font
        inputField.target = self
        inputField.action = #selector(addSubmitted(_:))

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelected(_:)))
        removeButton.bezelStyle = .inline

        let topBar = NSStackView(views: [prompt, inputField, removeButton])
        topBar.orientation = .horizontal
        topBar.spacing = 6
        topBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let exprCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("expression"))
        exprCol.title = "Expression"
        exprCol.width = 160
        let valCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valCol.title = "Value"
        valCol.width = 200
        tableView.addTableColumn(exprCol)
        tableView.addTableColumn(valCol)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 19

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        view = PanelLayout.view(bar: topBar, content: scrollView)
    }

    /// Adds a watched expression if it is not already in the list.
    func addExpression(_ expression: String) {
        loadViewIfNeeded()
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !entries.contains(where: { $0.expression == trimmed }) else { return }
        entries.append(Entry(expression: trimmed, value: "—"))
        tableView.reloadData()
        onExpressionsChanged?(expressions)
    }

    /// Removes the watched expression at `index`.
    func removeExpression(at index: Int) {
        guard entries.indices.contains(index) else { return }
        let removed = entries.remove(at: index)
        previousValues.removeValue(forKey: removed.expression)
        if isViewLoaded {
            tableView.reloadData()
        }
        onExpressionsChanged?(expressions)
    }

    /// Updates the displayed values for the watched expressions. When `evaluated`
    /// is provided, expressions not in `evaluated` (and absent from
    /// `valuesByExpression`) keep their current placeholder until evaluated.
    func updateValues(_ valuesByExpression: [String: String], evaluated: Set<String>? = nil) {
        loadViewIfNeeded()
        for idx in entries.indices {
            let expr = entries[idx].expression
            if let evaluated, !evaluated.contains(expr), valuesByExpression[expr] == nil {
                continue
            }
            let newValue = valuesByExpression[expr] ?? "<unavailable>"
            let oldValue = previousValues[expr]
            entries[idx].value = newValue
            entries[idx].isChanged = oldValue != nil && oldValue != newValue
            previousValues[expr] = newValue
        }
        updatedAt = Date()
        tableView.reloadData()
    }

    /// Clears stale displayed values and change history while keeping the
    /// user's watched expressions.
    func clearValues() {
        previousValues = [:]
        for idx in entries.indices {
            entries[idx].value = "—"
            entries[idx].isChanged = false
        }
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    @objc private func addSubmitted(_ sender: Any?) {
        let text = inputField.stringValue
        inputField.stringValue = ""
        addExpression(text)
    }

    @objc private func removeSelected(_ sender: Any?) {
        let row = tableView.selectedRow
        if row >= 0 {
            removeExpression(at: row)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let entry = entries[row]
        let isValue = identifier.rawValue == "value"
        let cell: NSTableCellView
        let label: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let existingLabel = reused.textField {
            cell = reused
            label = existingLabel
        } else {
            let createdLabel = NSTextField(labelWithString: "")
            createdLabel.lineBreakMode = .byTruncatingTail
            createdLabel.translatesAutoresizingMaskIntoConstraints = false
            let createdCell = NSTableCellView()
            createdCell.identifier = identifier
            createdCell.textField = createdLabel
            createdCell.addSubview(createdLabel)
            NSLayoutConstraint.activate([
                createdLabel.leadingAnchor.constraint(equalTo: createdCell.leadingAnchor, constant: 2),
                createdLabel.trailingAnchor.constraint(equalTo: createdCell.trailingAnchor, constant: -2),
                createdLabel.centerYAnchor.constraint(equalTo: createdCell.centerYAnchor)
            ])
            cell = createdCell
            label = createdLabel
        }

        label.stringValue = isValue ? entry.value : entry.expression
        label.font = DebugTableStyle.font
        label.lineBreakMode = .byTruncatingTail
        label.layer?.removeAnimation(forKey: "changedFlash")
        label.layer?.backgroundColor = NSColor.clear.cgColor
        label.drawsBackground = false
        label.backgroundColor = .clear
        if isValue && entry.isChanged {
            DebugTableStyle.markChanged(label, flash: DebugTableStyle.shouldFlash(since: updatedAt))
        } else {
            label.textColor = .labelColor
        }
        return cell
    }
}
