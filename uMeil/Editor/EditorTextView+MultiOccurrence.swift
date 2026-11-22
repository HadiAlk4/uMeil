import AppKit

/// Routes edits and focus changes through the `⌘D` occurrences being edited together.
extension EditorTextView {
    override func deleteForward(_ sender: Any?) {
        if !handleMultiOccurrenceDeleteForward() {
            super.deleteForward(sender)
        }
    }

    override func paste(_ sender: Any?) {
        if !handleMultiOccurrencePaste() {
            super.paste(sender)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if !handleMultiOccurrenceCancelOperation() {
            super.cancelOperation(sender)
        }
    }

    override func doCommand(by selector: Selector) {
        endMultiOccurrenceSessionBefore(selector)
        super.doCommand(by: selector)
    }

    override func didChangeText() {
        handleTextDidChangeForMultiOccurrence()
        super.didChangeText()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            endMultiOccurrenceSession()
        }
        return resigned
    }
}
