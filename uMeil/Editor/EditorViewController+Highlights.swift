import AppKit

/// Per-editor state for visual highlight timers, kept in a dedicated container
/// so `EditorViewController` stays concise and conflict-free.
@MainActor
final class EditorHighlightState {
    static let defaultFlashDuration: Duration = .milliseconds(250)

    /// How long the matching opening bracket flashes after typing `)`, `]`, or `}`.
    var flashDuration: Duration = defaultFlashDuration
    var flashTask: Task<Void, Never>?
    var flashGeneration = 0
    /// UTF-16 offset where a single typed closing bracket is about to land.
    var pendingClosingBracketOffset: Int?
}

/// Keeps the editor's visual highlights (current line, matching bracket, and
/// closing-bracket flash) synchronized with document lifecycle, cursor motion,
/// edits, and font changes without touching `NSTextStorage` or undo.
@MainActor
extension EditorViewController {
    private var highlightedTextView: EditorTextView? { textView as? EditorTextView }

    func refreshEditorHighlights() {
        cancelBracketFlash()
        highlightState.pendingClosingBracketOffset = nil
        guard let textView = highlightedTextView else { return }
        textView.highlightsCurrentLine = document != nil
        textView.refreshCurrentLineHighlight()
        updateBracketMatch()
    }

    func clearEditorHighlights() {
        cancelBracketFlash()
        highlightState.pendingClosingBracketOffset = nil
        guard let textView = highlightedTextView else { return }
        textView.highlightsCurrentLine = false
        textView.bracketMatch = nil
        textView.refreshCurrentLineHighlight()
    }

    func editorHighlightsCancelPendingTypedBracket() {
        highlightState.pendingClosingBracketOffset = nil
    }

    func editorHighlightsWillChangeText(in affectedCharRange: NSRange, replacementString: String?) {
        let isUndoOrRedo = (textView.undoManager?.isUndoing ?? false)
            || (textView.undoManager?.isRedoing ?? false)
        if !isUndoOrRedo,
           let replacement = replacementString,
           BracketMatcher.isClosingBracket(replacement) {
            highlightState.pendingClosingBracketOffset = affectedCharRange.location
        } else {
            highlightState.pendingClosingBracketOffset = nil
        }

        if let flash = highlightedTextView?.flashingBracketRange {
            let isDeletion = affectedCharRange.length > 0 && (replacementString?.isEmpty ?? true)
            if isDeletion || affectedCharRange.location <= NSMaxRange(flash) {
                cancelBracketFlash()
            }
        }
    }

    func editorHighlightsDidChangeSelection() {
        highlightedTextView?.refreshCurrentLineHighlight()
        if textView.selectedRange().length > 0 {
            cancelBracketFlash()
        }
        updateBracketMatch()
    }

    func editorHighlightsDidChangeText() {
        let typedClosingOffset = highlightState.pendingClosingBracketOffset
        highlightState.pendingClosingBracketOffset = nil

        highlightedTextView?.refreshCurrentLineHighlight()
        let match = updateBracketMatch()
        highlightedTextView?.refreshBracketHighlights()

        if let typedClosingOffset,
           let match,
           match.anchorOffset == typedClosingOffset {
            flashMatchingBracket(at: match.matchOffset)
        } else if let flash = highlightedTextView?.flashingBracketRange,
                  NSMaxRange(flash) > (textView.textStorage?.length ?? 0) {
            cancelBracketFlash()
        }
    }

    func editorHighlightsDidChangeFont() {
        guard let textView = highlightedTextView else { return }
        textView.refreshCurrentLineHighlight()
        textView.refreshBracketHighlights()
        textView.needsDisplay = true
    }

    @discardableResult
    func updateBracketMatch() -> BracketMatcher.Match? {
        guard let textView = highlightedTextView else { return nil }
        guard document != nil,
              textView.selectedRanges.count == 1,
              let selection = textView.selectedRanges.first?.rangeValue,
              selection.location != NSNotFound,
              selection.length == 0
        else {
            textView.bracketMatch = nil
            return nil
        }

        let mode = BracketMatcher.mode(for: document?.url)
        let match = BracketMatcher.match(in: textView.string, cursor: selection.location, mode: mode)
        textView.bracketMatch = match
        return match
    }

    func flashMatchingBracket(at offset: Int) {
        highlightState.flashTask?.cancel()
        highlightState.flashGeneration += 1
        let generation = highlightState.flashGeneration

        guard let textView = highlightedTextView,
              let length = textView.textStorage?.length,
              offset >= 0,
              offset < length
        else {
            highlightState.flashTask = nil
            highlightedTextView?.flashingBracketRange = nil
            return
        }

        let range = NSRange(location: offset, length: 1)
        textView.flashingBracketRange = range
        let duration = highlightState.flashDuration

        highlightState.flashTask = Task { [weak self, weak textView] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            if let self {
                guard self.highlightState.flashGeneration == generation else { return }
                self.highlightedTextView?.flashingBracketRange = nil
                self.highlightState.flashTask = nil
            } else {
                textView?.flashingBracketRange = nil
            }
        }
    }

    func cancelBracketFlash() {
        highlightState.flashTask?.cancel()
        highlightState.flashTask = nil
        highlightState.flashGeneration += 1
        highlightedTextView?.flashingBracketRange = nil
    }
}
