import AppKit

extension EditorTextView {
    /// Dim text drawn after the end of a line, such as a variable's value
    /// while debugging. It is not part of the text, so it cannot be selected
    /// or edited.
    struct InlineAnnotation: Equatable {
        /// The offset of the first character of the line.
        var lineStart: Int
        var text: String
    }

    /// Where an annotation for the line starting at `lineStart` is drawn, in
    /// the view's coordinates, or `nil` if the line is not in the text. It
    /// goes after the line's build message, if it has one.
    func inlineAnnotationOrigin(forLineStart lineStart: Int) -> NSPoint? {
        guard let layoutManager, let storage = textStorage, lineStart >= 0, lineStart < storage.length else {
            return nil
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: lineStart)
        // Lines do not wrap, so a line is one line fragment.
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        var left = textContainerOrigin.x + used.maxX + Self.inlineMessageGap
        if let message = inlineMessages.first(where: { $0.lineStart == lineStart })?.message {
            left += Self.capsuleWidth(for: message) + Self.inlineMessageGap
        }
        return NSPoint(x: left, y: textContainerOrigin.y + used.minY)
    }

    func drawInlineAnnotations(in dirtyRect: NSRect) {
        guard !inlineAnnotations.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: EditorTheme.font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        for annotation in inlineAnnotations {
            guard let origin = inlineAnnotationOrigin(forLineStart: annotation.lineStart) else { continue }
            let text = NSAttributedString(string: annotation.text, attributes: attributes)
            guard NSRect(origin: origin, size: text.size()).intersects(dirtyRect) else { continue }
            text.draw(at: origin)
        }
    }
}
