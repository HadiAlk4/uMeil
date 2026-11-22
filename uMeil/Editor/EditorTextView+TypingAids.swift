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

    func handleTab() -> Bool {
        guard canUseTypingAids else { return false }
        let selection = selectedRange()
        guard selection.length == 0 else { return false }
        apply(CodeEditing.tab(in: currentText, selection: selection, style: indentStyle))
        return true
    }

    func handleDeleteBackward() -> Bool {
        guard canUseTypingAids,
              let edit = CodeEditing.deleteIndentation(in: currentText, selection: selectedRange(), style: indentStyle)
        else { return false }
        apply(edit)
        return true
    }
}
