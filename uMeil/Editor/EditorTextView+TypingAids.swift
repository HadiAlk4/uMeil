import AppKit

/// The editing help `EditorTextView` gives while typing. The decisions are
/// made by `CodeEditing`; this applies them so they can be undone like typing.
extension EditorTextView {
    /// The text, without copying it.
    var currentText: NSString {
        textStorage?.mutableString ?? (string as NSString)
    }

    /// Makes `edit` as a normal, undoable change to the text.
    func apply(_ edit: TextEdit) {
        guard let textStorage,
              shouldChangeText(in: edit.range, replacementString: edit.replacement)
        else { return }
        textStorage.replaceCharacters(
            in: edit.range,
            with: NSAttributedString(string: edit.replacement, attributes: typingAttributes)
        )
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    /// Whether the typing aids should handle a key. They stay out of the way
    /// while an input method is composing text.
    var canUseTypingAids: Bool {
        isEditable && !hasMarkedText() && selectedRanges.count == 1
    }

    func handleNewline() -> Bool {
        guard canUseTypingAids else { return false }
        apply(CodeEditing.newline(in: currentText, selection: selectedRange(), style: indentStyle))
        return true
    }

    /// A single typed character. Returns whether it was handled here.
    func handleTyped(_ typed: String) -> Bool {
        guard canUseTypingAids, typed.count == 1, let character = typed.first else { return false }
        let selection = selectedRange()
        let action = CodeEditing.pairAction(
            for: character,
            in: currentText,
            selection: selection,
            autoClosed: autoClosedPairs
        )
        switch action {
        case .stepOver:
            autoClosedPairs.remove(selection.location)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        case let .insertPair(edit, closer):
            apply(edit)
            autoClosedPairs.insert(closer)
            return true
        case nil:
            break
        }
        guard character == "}",
              let edit = CodeEditing.closingBrace(in: currentText, selection: selection, style: indentStyle)
        else { return false }
        apply(edit)
        return true
    }

    /// Tab: indentation at the cursor, or with text selected, every
    /// selected line moves one level right.
    func handleTab() -> Bool {
        guard canUseTypingAids else { return false }
        let selection = selectedRange()
        if selection.length > 0 {
            shiftSelectedLines(.right)
        } else {
            apply(CodeEditing.tab(in: currentText, selection: selection, style: indentStyle))
        }
        return true
    }

    func shiftSelectedLines(_ direction: CodeEditing.ShiftDirection) {
        guard isEditable,
              let edit = CodeEditing.shiftLines(
                in: currentText,
                selection: selectedRange(),
                style: indentStyle,
                direction: direction
              )
        else { return }
        apply(edit)
    }

    /// Backspace: an empty pair the editor made goes as one, and spaces in
    /// the indentation go a tab stop at a time.
    func handleDeleteBackward() -> Bool {
        guard canUseTypingAids else { return false }
        let selection = selectedRange()
        let edit = CodeEditing.deletePair(in: currentText, selection: selection, autoClosed: autoClosedPairs)
            ?? CodeEditing.deleteIndentation(in: currentText, selection: selection, style: indentStyle)
        guard let edit else { return false }
        apply(edit)
        return true
    }
}
