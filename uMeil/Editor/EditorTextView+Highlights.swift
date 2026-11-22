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
        /// Matched bracket pair adjacent to the cursor, if any.
        var bracketMatch: BracketMatcher.Match?
        /// Opening bracket briefly flashing after typing a closing bracket.
        var flashingBracketRange: NSRange?
        /// Last drawn steady bracket rects for targeted invalidation.
        var lastBracketRects: [NSRect] = []
        /// Last drawn flash rect for targeted invalidation.
        var lastFlashRect: NSRect?
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

    /// The matched bracket pair around the cursor, drawn behind the text.
    var bracketMatch: BracketMatcher.Match? {
        get { highlightState.bracketMatch }
        set {
            guard highlightState.bracketMatch != newValue else { return }
            let previousRects = highlightState.lastBracketRects
            highlightState.bracketMatch = newValue
            let nextRects = currentBracketRects(for: newValue)
            invalidateBracketRects(previous: previousRects, next: nextRects)
            highlightState.lastBracketRects = nextRects
        }
    }

    /// The matching opening bracket briefly flashing after typing `)`, `]`, or `}`.
    var flashingBracketRange: NSRange? {
        get { highlightState.flashingBracketRange }
        set {
            guard highlightState.flashingBracketRange != newValue else { return }
            let previousRect = highlightState.lastFlashRect
            highlightState.flashingBracketRange = newValue
            let nextRect = newValue.flatMap { range in
                range.length == 1 ? bracketHighlightRect(forOffset: range.location) : nil
            }
            invalidateBracketRects(
                previous: previousRect.map { [$0] } ?? [],
                next: nextRect.map { [$0] } ?? []
            )
            highlightState.lastFlashRect = nextRect
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

    /// View-coordinate bounding rect of the single UTF-16 character at `offset`.
    func bracketHighlightRect(forOffset offset: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer,
              let storage = textStorage,
              offset >= 0,
              offset < storage.length
        else { return nil }

        let charRange = NSRange(location: offset, length: 1)
        layoutManager.ensureLayout(forCharacterRange: charRange)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }

        var box = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        box.origin.x += textContainerOrigin.x
        box.origin.y += textContainerOrigin.y
        guard box.width > 0, box.height > 0 else { return nil }
        return box
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

    /// Recomputes and invalidates bracket highlight geometry after font or
    /// layout shifts.
    func refreshBracketHighlights() {
        let nextBrackets = currentBracketRects(for: highlightState.bracketMatch)
        invalidateBracketRects(previous: highlightState.lastBracketRects, next: nextBrackets)
        highlightState.lastBracketRects = nextBrackets

        let nextFlash = highlightState.flashingBracketRange.flatMap { range in
            range.length == 1 ? bracketHighlightRect(forOffset: range.location) : nil
        }
        invalidateBracketRects(
            previous: highlightState.lastFlashRect.map { [$0] } ?? [],
            next: nextFlash.map { [$0] } ?? []
        )
        highlightState.lastFlashRect = nextFlash
    }

    /// Draws editor highlights behind the text.
    func drawEditorHighlights(in dirtyRect: NSRect) {
        drawCurrentLineHighlight(in: dirtyRect)
        drawBracketHighlights(in: dirtyRect)
    }

    private func drawCurrentLineHighlight(in dirtyRect: NSRect) {
        let lineRect = currentLineHighlightRect
        highlightState.lastCurrentLineRect = lineRect
        guard let lineRect, lineRect.intersects(dirtyRect) else { return }

        EditorTheme.currentLineColor.setFill()
        lineRect.fill()
    }

    private func drawBracketHighlights(in dirtyRect: NSRect) {
        let flashOffset: Int? = if let flash = highlightState.flashingBracketRange, flash.length == 1 {
            flash.location
        } else {
            nil
        }

        if let match = highlightState.bracketMatch {
            var drawnRects: [NSRect] = []
            for offset in [match.anchorOffset, match.matchOffset] {
                guard let box = bracketHighlightRect(forOffset: offset) else { continue }
                drawnRects.append(box)
                guard offset != flashOffset else { continue }
                let fillRect = box.insetBy(dx: -1, dy: 0)
                guard fillRect.insetBy(dx: -1, dy: -1).intersects(dirtyRect) else { continue }
                drawRoundedHighlight(
                    fillRect: fillRect,
                    cornerRadius: 3,
                    fill: EditorTheme.bracketMatchBackgroundColor,
                    border: EditorTheme.bracketMatchBorderColor
                )
            }
            highlightState.lastBracketRects = drawnRects
        } else {
            highlightState.lastBracketRects = []
        }

        if let flashOffset, let box = bracketHighlightRect(forOffset: flashOffset) {
            highlightState.lastFlashRect = box
            let fillRect = box.insetBy(dx: -1.5, dy: -0.5)
            if fillRect.insetBy(dx: -1, dy: -1).intersects(dirtyRect) {
                drawRoundedHighlight(
                    fillRect: fillRect,
                    cornerRadius: 3.5,
                    fill: EditorTheme.bracketFlashBackgroundColor,
                    border: EditorTheme.bracketFlashBorderColor
                )
            }
        } else {
            highlightState.lastFlashRect = nil
        }
    }

    private func drawRoundedHighlight(
        fillRect: NSRect,
        cornerRadius: CGFloat,
        fill: NSColor,
        border: NSColor
    ) {
        fill.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        let strokeRect = fillRect.insetBy(dx: 0.5, dy: 0.5)
        let strokeRadius = max(cornerRadius - 0.5, 0)
        let borderPath = NSBezierPath(roundedRect: strokeRect, xRadius: strokeRadius, yRadius: strokeRadius)
        borderPath.lineWidth = 1
        border.setStroke()
        borderPath.stroke()
    }

    private func currentBracketRects(for match: BracketMatcher.Match?) -> [NSRect] {
        guard let match else { return [] }
        return [match.anchorOffset, match.matchOffset].compactMap(bracketHighlightRect(forOffset:))
    }

    private func invalidateBracketRects(previous: [NSRect], next: [NSRect]) {
        for rect in previous {
            setNeedsDisplay(rect.insetBy(dx: -3, dy: -2))
        }
        for rect in next {
            setNeedsDisplay(rect.insetBy(dx: -3, dy: -2))
        }
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
