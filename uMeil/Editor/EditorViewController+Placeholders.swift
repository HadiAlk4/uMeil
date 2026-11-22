import AppKit

/// Fill-in placeholders after accepting a completion such as `GPIOPinWrite`:
/// the arguments are selected one at a time, and Tab / Shift-Tab move
/// between them.
@MainActor
extension EditorViewController {
    /// The placeholders still being filled in, if any.
    var snippetPlaceholders: SnippetPlaceholders? { intelligence.placeholders }

    /// Inserts `snippet` over `range` and selects its first placeholder, or
    /// puts the cursor where the snippet says it should end.
    func insertSnippet(_ snippet: LSPSnippet, replacing range: NSRange) {
        endPlaceholders()
        textView.insertText(snippet.text, replacementRange: range)
        guard let placeholders = SnippetPlaceholders(snippet: snippet, insertedAt: range.location) else {
            if let final = snippet.finalOffset {
                textView.setSelectedRange(NSRange(location: range.location + final, length: 0))
            }
            return
        }
        intelligence.placeholders = placeholders
        textView.setSelectedRange(placeholders.currentRange)
        refreshPlaceholderHighlights()
    }

    /// Handles Tab, Shift-Tab and Esc while placeholders are active.
    /// Returns `true` when the key was used.
    func handlePlaceholderKey(_ event: NSEvent) -> Bool {
        guard var placeholders = intelligence.placeholders else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.keyCode, modifiers) {
        case (48, []):
            if let next = placeholders.next() {
                intelligence.placeholders = placeholders
                textView.setSelectedRange(next)
            } else {
                endPlaceholders()
                textView.setSelectedRange(NSRange(location: placeholders.finalOffset, length: 0))
            }
            return true
        case (48, [.shift]):
            let previous = placeholders.previous()
            intelligence.placeholders = placeholders
            textView.setSelectedRange(previous)
            return true
        case (53, []):
            endPlaceholders()
            return true
        default:
            return false
        }
    }

    /// Keeps the placeholder ranges in step with an edit that is about to happen.
    func placeholdersWillChangeText(in range: NSRange, replacement: String?) {
        guard var placeholders = intelligence.placeholders else { return }
        let length = (replacement.map { $0 as NSString })?.length ?? 0
        if placeholders.apply(edit: range, replacementLength: length) {
            intelligence.placeholders = placeholders
        } else {
            endPlaceholders()
        }
    }

    /// Ends the session once the cursor leaves the inserted snippet.
    func placeholdersSelectionDidChange() {
        guard let placeholders = intelligence.placeholders else { return }
        let selection = textView.selectedRange()
        let span = placeholders.span
        if selection.location < span.location || NSMaxRange(selection) > NSMaxRange(span) {
            endPlaceholders()
        }
    }

    func endPlaceholders() {
        intelligence.placeholders = nil
        refreshPlaceholderHighlights()
    }

    /// Shades each unfilled placeholder so it is clear there is more to type.
    func refreshPlaceholderHighlights() {
        (textView as? EditorTextView)?.placeholderRanges = intelligence.placeholders?.ranges ?? []
    }
}
