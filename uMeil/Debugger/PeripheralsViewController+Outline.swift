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
        if identifier.rawValue == "value", let bit = bitValue(of: node) {
            return checkboxCell(in: outlineView, isOn: bit, for: node)
        }
        let (cell, label) = dequeueCell(in: outlineView, identifier: identifier)

        // Reset all recycled cell state before applying column-specific properties.
        label.stringValue = ""
        label.font = DebugTableStyle.font
        label.textColor = .labelColor
        label.layer?.removeAnimation(forKey: "changedFlash")
        label.layer?.backgroundColor = NSColor.clear.cgColor
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.toolTip = nil
        label.isEditable = false
        label.delegate = nil
        label.lineBreakMode = .byTruncatingTail

        switch identifier.rawValue {
        case "name":
            label.stringValue = node.name
            label.toolTip = node.field?.description ?? node.register.description
        case "value":
            configureValueLabel(label, for: node)
        default:
            label.stringValue = locationText(for: node)
            label.textColor = .secondaryLabelColor
        }
        return cell
    }

    private func configureValueLabel(_ label: NSTextField, for node: Node) {
        label.stringValue = valueText(for: node)
        if case .unreadable(let reason) = readings[node.register.name] {
            label.toolTip = reason
            label.textColor = .secondaryLabelColor
        } else if readings[node.register.name] == .notRead {
            label.textColor = .secondaryLabelColor
            label.toolTip = node.register.readHasSideEffects
                ? "Reading this register changes the chip. Choose Read Now from the menu to read it."
                : nil
        }
        if isChanged(node) {
            DebugTableStyle.markChanged(label, flash: DebugTableStyle.shouldFlash(since: updatedAt))
        }
        if isEditable, isWritable(node) {
            label.isEditable = true
            label.delegate = self
        }
    }

    private func dequeueCell(
        in outlineView: NSOutlineView,
        identifier: NSUserInterfaceItemIdentifier
    ) -> (NSTableCellView, NSTextField) {
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let existingLabel = reused.textField {
            return (reused, existingLabel)
        }
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
        return (cell, label)
    }

    // MARK: - Clicking a bit

    /// Whether the single-bit field `node` is set, for a field that can be
    /// written and has been read. Other rows show their value as text.
    func bitValue(of node: Node) -> Bool? {
        guard let field = node.field, field.bitWidth == 1, isWritable(node),
              case .value(let registerValue) = readings[node.register.name]
        else { return nil }
        return field.value(in: registerValue) != 0
    }

    private static let checkboxIdentifier = NSUserInterfaceItemIdentifier("bitCheckbox")

    /// A checkbox for one writable bit, such as a GPIO pin's data bit: one
    /// click switches an LED on or off, without typing a hex value.
    private func checkboxCell(in outlineView: NSOutlineView, isOn: Bool, for node: Node) -> NSView {
        let cell: NSTableCellView
        let checkbox: NSButton
        if let reused = outlineView.makeView(withIdentifier: Self.checkboxIdentifier, owner: self) as? NSTableCellView,
           let existing = reused.subviews.first as? NSButton {
            cell = reused
            checkbox = existing
        } else {
            checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(bitClicked(_:)))
            checkbox.controlSize = .small
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            cell = NSTableCellView()
            cell.identifier = Self.checkboxIdentifier
            cell.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        checkbox.state = isOn ? .on : .off
        checkbox.isEnabled = isEditable
        checkbox.title = isOn ? "1" : "0"
        checkbox.font = DebugTableStyle.font
        checkbox.contentTintColor = isChanged(node) ? DebugTableStyle.changedColor : nil
        checkbox.toolTip = isEditable
            ? "Click to \(isOn ? "clear" : "set") \(node.name)"
            : "Stop the program to change \(node.name)"
        checkbox.setAccessibilityLabel(node.name)
        return cell
    }

    @objc func bitClicked(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard let node = outlineView.item(atRow: row) as? Node, let field = node.field,
              let peripheral = selectedPeripheral, isEditable
        else {
            revertEdits()
            return
        }
        onWrite?(peripheral, node.register, field, sender.state == .on ? "1" : "0")
    }

    // MARK: - Typing a value

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let peripheral = selectedPeripheral,
              let node = outlineView.item(atRow: outlineView.row(for: field)) as? Node
        else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = valueText(for: node)
        // Leaving the value blank, unchanged, or ending edits when not editable is not a write.
        guard isEditable, !text.isEmpty, text != current else {
            field.stringValue = current
            return
        }
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
