import AppKit

/// Line-editing keyboard shortcuts and menu actions (`⌥↑`, `⌥↓`, `⇧⌥↓`) for `EditorTextView`.
extension EditorTextView {
    private static let relevantShortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125

    /// Edit > Move Line Up (`⌥↑`)
    @objc func moveLineUp(_ sender: Any?) {
        guard isEditable,
              let edit = LineEditing.moveLinesUp(in: string, selection: selectedRange())
        else { return }
        applyLineEdit(edit)
    }

    /// Edit > Move Line Down (`⌥↓`)
    @objc func moveLineDown(_ sender: Any?) {
        guard isEditable,
              let edit = LineEditing.moveLinesDown(in: string, selection: selectedRange())
        else { return }
        applyLineEdit(edit)
    }

    /// Edit > Duplicate Line (`⇧⌥↓`)
    @objc func duplicateLineDown(_ sender: Any?) {
        guard isEditable else { return }
        let edit = LineEditing.duplicateLinesDown(in: string, selection: selectedRange())
        applyLineEdit(edit)
    }

    /// Intercepts `⌥↑`, `⌥↓`, and `⇧⌥↓` before `NSTextView` maps them to paragraph movement.
    func handleLineEditingKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(Self.relevantShortcutModifiers)
        let isUpArrow = event.keyCode == Self.upArrowKeyCode || event.specialKey == .upArrow
        let isDownArrow = event.keyCode == Self.downArrowKeyCode || event.specialKey == .downArrow

        if isUpArrow && modifiers == .option {
            moveLineUp(nil)
            return true
        }
        if isDownArrow && modifiers == .option {
            moveLineDown(nil)
            return true
        }
        if isDownArrow && modifiers == [.option, .shift] {
            duplicateLineDown(nil)
            return true
        }
        return false
    }

    func validateLineEditingUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(moveLineUp(_:)),
             #selector(moveLineDown(_:)),
             #selector(duplicateLineDown(_:)):
            return isEditable
        default:
            return nil
        }
    }

    private func applyLineEdit(_ edit: LineEditResult) {
        guard isEditable, let storage = textStorage else { return }
        let previousSelection = selectedRange()
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
        }
        undoManager?.registerUndo(withTarget: self) { target in
            target.setSelectedRange(previousSelection)
        }
        guard shouldChangeText(in: edit.affectedRange, replacementString: edit.replacement) else {
            return
        }
        storage.beginEditing()
        storage.replaceCharacters(in: edit.affectedRange, with: edit.replacement)
        let insertedLength = (edit.replacement as NSString).length
        if insertedLength > 0, !typingAttributes.isEmpty {
            let insertedRange = NSRange(location: edit.affectedRange.location, length: insertedLength)
            storage.setAttributes(typingAttributes, range: insertedRange)
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(edit.newSelection)
        scrollRangeToVisible(edit.newSelection)
    }
}
