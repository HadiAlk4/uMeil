import AppKit

/// The `Peripherals` panel's outline of registers and fields, typing new
/// values into it, and its context menu.
extension PeripheralsViewController: NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
    NSMenuDelegate {
    private func isWritable(_ node: Node) -> Bool {
        (node.field?.access ?? node.register.access).isWritable
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.children.isEmpty == false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let identifier = tableColumn?.identifier else { return nil }
        let label: NSTextField
        switch identifier.rawValue {
        case "name":
            label = NSTextField(labelWithString: node.name)
            label.font = .systemFont(ofSize: 12)
            label.toolTip = node.field?.description ?? node.register.description
        case "value":
            label = NSTextField(labelWithString: valueText(for: node))
            label.font = EditorTheme.font
            if case .unreadable(let reason) = readings[node.register.name] {
                label.toolTip = reason
                label.textColor = .secondaryLabelColor
            } else if readings[node.register.name] == .notRead {
                label.textColor = .secondaryLabelColor
                label.toolTip = node.register.readHasSideEffects
                    ? "Reading this register changes the chip. Choose Read Now from the menu to read it."
                    : nil
            }
            if changedRegisters.contains(node.register.name) {
                label.textColor = .systemTeal
                label.drawsBackground = true
                label.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.15)
            }
            if isEditable, isWritable(node) {
                label.isEditable = true
                label.delegate = self
            }
        default:
            label = NSTextField(labelWithString: locationText(for: node))
            label.font = EditorTheme.font
            label.textColor = .secondaryLabelColor
        }
        label.lineBreakMode = .byTruncatingTail

        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    // MARK: - Typing a value

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let peripheral = selectedPeripheral,
              let node = outlineView.item(atRow: outlineView.row(for: field)) as? Node
        else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leaving the value as shown is not a write.
        guard !text.isEmpty, text != valueText(for: node) else { return }
        onWrite?(peripheral, node.register, node.field, text)
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? Node,
              node.register.access.isReadable
        else { return }
        let item = NSMenuItem(title: "Read Now", action: #selector(readNow(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = node
        item.isEnabled = isEditable
        menu.addItem(item)
    }

    @objc private func readNow(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? Node, let peripheral = selectedPeripheral else { return }
        onReadNow?(peripheral, node.register)
    }
}
