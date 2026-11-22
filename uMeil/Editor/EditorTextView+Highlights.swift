import AppKit

extension EditorTextView {
    /// Holds visual highlight state drawn in `drawBackground(in:)` so edits
    /// stay out of `NSTextStorage` and never affect undo or syntax coloring.
    struct HighlightState {
        /// Whether the current cursor line should be tinted behind the text.
        var highlightsCurrentLine = false
        /// Last invalidated or drawn rect of the current-line band, used to
        /// clear the previous line cleanly when the cursor moves.
        var lastCurrentLineRect: NSRect?
    }

    /// Whether the line containing a zero-length caret is faintly highlighted.
    var highlightsCurrentLine: Bool {
        get { highlightState.highlightsCurrentLine }
        set {
            guard highlightState.highlightsCurrentLine != newValue else { return }
            highlightState.highlightsCurrentLine = newValue
            refreshCurrentLineHighlight()
        }
    }

    /// The full-width rect of the current cursor line in view coordinates, or
    /// `nil` when current-line highlighting is disabled or text is selected.
    var currentLineHighlightRect: NSRect? {
        guard highlightState.highlightsCurrentLine,
              let layoutManager,
              let textContainer,
              let storage = textStorage,
              selectedRanges.count == 1,
              let selection = selectedRanges.first?.rangeValue,
              selection.location != NSNotFound,
              selection.length == 0
        else { return nil }

        let length = storage.length
        let location = min(max(selection.location, 0), length)
        let fragmentRect = lineFragmentRect(
            atUTF16Offset: location,
            textLength: length,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        guard fragmentRect.height > 0 else { return nil }

        return NSRect(
            x: bounds.minX,
            y: fragmentRect.minY + textContainerOrigin.y,
            width: bounds.width,
            height: fragmentRect.height
        )
    }

    /// Invalidates the old and new current-line bands when the cursor or
    /// layout changes so no stale tint remains on the previous line.
    func refreshCurrentLineHighlight() {
        let previous = highlightState.lastCurrentLineRect
        let current = currentLineHighlightRect
        guard previous != current else { return }

        if let previous {
            setNeedsDisplay(fullWidthRect(for: previous))
        }
        if let current {
            setNeedsDisplay(fullWidthRect(for: current))
        }
        highlightState.lastCurrentLineRect = current
    }

    /// Draws editor highlights behind the text.
    func drawEditorHighlights(in dirtyRect: NSRect) {
        drawCurrentLineHighlight(in: dirtyRect)
    }

    private func drawCurrentLineHighlight(in dirtyRect: NSRect) {
        let lineRect = currentLineHighlightRect
        highlightState.lastCurrentLineRect = lineRect
        guard let lineRect, lineRect.intersects(dirtyRect) else { return }

        EditorTheme.currentLineColor.setFill()
        lineRect.fill()
    }

    private func fullWidthRect(for rect: NSRect) -> NSRect {
        NSRect(x: bounds.minX, y: rect.minY, width: max(bounds.width, rect.width), height: rect.height)
    }

    private func lineFragmentRect(
        atUTF16Offset location: Int,
        textLength: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect {
        if textLength == 0 {
            layoutManager.ensureLayout(for: textContainer)
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 { return extra }
            let height = layoutManager.defaultLineHeight(for: font ?? EditorTheme.font)
            return NSRect(x: 0, y: 0, width: bounds.width, height: height)
        }

        if location == textLength {
            // `ensureLayout(forCharacterRange:)` stops at the final `\n` glyph
            // and can leave `extraLineFragmentRect` stale right after typing a
            // newline; ensuring layout for the container computes the trailing
            // empty line fragment immediately.
            layoutManager.ensureLayout(for: textContainer)
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 { return extra }
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: textLength - 1)
            return layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        }

        layoutManager.ensureLayout(forCharacterRange: NSRange(location: location, length: 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            return layoutManager.extraLineFragmentRect
        }
        return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    }
}
