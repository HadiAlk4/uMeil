import AppKit

/// Keeps the editor's visual highlights (current line, etc.) synchronized
/// with document lifecycle, cursor motion, edits, and font changes.
@MainActor
extension EditorViewController {
    private var highlightedTextView: EditorTextView? { textView as? EditorTextView }

    func refreshEditorHighlights() {
        guard let textView = highlightedTextView else { return }
        textView.highlightsCurrentLine = document != nil
        textView.refreshCurrentLineHighlight()
    }

    func clearEditorHighlights() {
        guard let textView = highlightedTextView else { return }
        textView.highlightsCurrentLine = false
        textView.refreshCurrentLineHighlight()
    }

    func editorHighlightsDidChangeSelection() {
        highlightedTextView?.refreshCurrentLineHighlight()
    }

    func editorHighlightsDidChangeText() {
        highlightedTextView?.refreshCurrentLineHighlight()
    }

    func editorHighlightsDidChangeFont() {
        guard let textView = highlightedTextView else { return }
        textView.refreshCurrentLineHighlight()
        textView.needsDisplay = true
    }
}
