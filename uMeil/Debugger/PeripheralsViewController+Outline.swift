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
        if identifier.rawValue == "value", let bitState = singleBitState(of: node) {
            return bitState.isWritable
                ? checkboxCell(in: outlineView, isOn: bitState.isOn, for: node)
                : bitDotCell(in: outlineView, isOn: bitState.isOn, for: node)
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
            DebugTableStyle.applyValue(locationText(for: node), to: label, baseColor: .secondaryLabelColor)
        }
        return cell
    }

    private func configureValueLabel(_ label: NSTextField, for node: Node) {
        let text = valueText(for: node)
        if case .unreadable(let reason) = readings[node.register.name] {
            label.stringValue = text
            label.toolTip = reason
            label.textColor = .secondaryLabelColor
        } else if readings[node.register.name] == .notRead {
            label.stringValue = text
            label.textColor = .secondaryLabelColor
            label.toolTip = node.register.readHasSideEffects
                ? "Reading this register changes the chip. Choose Read Now from the menu to read it."
                : nil
        } else {
            DebugTableStyle.applyValue(
                text,
                to: label,
                baseColor: .labelColor,
                isChanged: isChanged(node),
                flash: DebugTableStyle.shouldFlash(since: updatedAt)
            )
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

    // MARK: - Single-bit indicators

    /// Read state of a single-bit field: writable bits show as checkboxes,
    /// read-only bits show as on/off status dots.
    struct SingleBitState: Equatable {
        let isOn: Bool
        let isWritable: Bool
    }

    /// State for any single-bit field whose register has been read.
    func singleBitState(of node: Node) -> SingleBitState? {
        guard let field = node.field, field.bitWidth == 1,
              case .value(let registerValue) = readings[node.register.name]
        else { return nil }
        return SingleBitState(
            isOn: field.value(in: registerValue) != 0,
            isWritable: isWritable(node)
        )
    }

    /// Whether the single-bit field `node` is set, for a field that can be
    /// written and has been read. Read-only single bits show as status dots.
    func bitValue(of node: Node) -> Bool? {
        guard let state = singleBitState(of: node), state.isWritable else { return nil }
        return state.isOn
    }

    private static let checkboxIdentifier = NSUserInterfaceItemIdentifier("bitCheckbox")
    private static let bitDotIdentifier = NSUserInterfaceItemIdentifier("bitDot")
    private static let dotSymbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)

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
        cell.layer?.removeAnimation(forKey: "changedFlash")
        cell.layer?.backgroundColor = NSColor.clear.cgColor
        let changed = isChanged(node)
        checkbox.state = isOn ? .on : .off
        checkbox.isEnabled = isEditable
        checkbox.title = node.field?.enumeratedName(for: isOn ? 1 : 0) ?? ""
        checkbox.font = DebugTableStyle.font
        checkbox.contentTintColor = changed ? DebugTableStyle.changedColor : nil
        checkbox.toolTip = isEditable
            ? "\(node.name) = \(isOn ? "1" : "0") — click to \(isOn ? "clear" : "set")"
            : "\(node.name) = \(isOn ? "1" : "0") — stop the program to change"
        checkbox.setAccessibilityLabel(node.name)
        if changed && DebugTableStyle.shouldFlash(since: updatedAt) {
            DebugTableStyle.flash(cell)
        }
        return cell
    }

    /// A small on/off dot for one read-only bit, such as a status or lock flag.
    private func bitDotCell(in outlineView: NSOutlineView, isOn: Bool, for node: Node) -> NSView {
        let cell: NSTableCellView
        let dot: NSImageView
        if let reused = outlineView.makeView(withIdentifier: Self.bitDotIdentifier, owner: self) as? NSTableCellView,
           let existing = reused.imageView {
            cell = reused
            dot = existing
        } else {
            dot = NSImageView()
            dot.imageScaling = .scaleNone
            dot.translatesAutoresizingMaskIntoConstraints = false
            cell = NSTableCellView()
            cell.identifier = Self.bitDotIdentifier
            cell.imageView = dot
            cell.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: 12),
                dot.heightAnchor.constraint(equalToConstant: 12)
            ])
        }
        cell.layer?.removeAnimation(forKey: "changedFlash")
        cell.layer?.backgroundColor = NSColor.clear.cgColor
        let changed = isChanged(node)
        let symbolName = isOn ? "circle.fill" : "circle"
        let description = isOn ? "On (1)" : "Off (0)"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(Self.dotSymbolConfig)
        image?.isTemplate = true
        dot.image = image
        if changed {
            dot.contentTintColor = DebugTableStyle.changedColor
        } else {
            dot.contentTintColor = isOn ? .controlAccentColor : .tertiaryLabelColor
        }
        dot.toolTip = "\(node.name) = \(isOn ? "1 (on)" : "0 (off)") (read-only)"
        dot.setAccessibilityLabel(node.name)
        dot.setAccessibilityValue(isOn ? "1" : "0")
        if changed && DebugTableStyle.shouldFlash(since: updatedAt) {
            DebugTableStyle.flash(cell)
        }
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
            DebugTableStyle.applyValue(current, to: field, baseColor: .labelColor, isChanged: isChanged(node))
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
