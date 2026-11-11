import AppKit

/// The gutter down the left side of the editor that shows line numbers.
final class LineNumberRulerView: NSRulerView {
    /// Line positions for the text currently in the editor.
    var lineIndex = LineIndex("") {
        didSet {
            updateThickness()
            needsDisplay = true
        }
    }

    /// Lines to flag with an error or warning marker, from the last build.
    var lineMarkers: [Int: Diagnostic.Severity] = [:] {
        didSet { needsDisplay = true }
    }

    private static let padding: CGFloat = 8

    private var numberAttributes: [NSAttributedString.Key: Any] {
        [.font: EditorTheme.lineNumberFont, .foregroundColor: NSColor.secondaryLabelColor]
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        // Without this the ruler can draw over the text on macOS 14 and later.
        clipsToBounds = true
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberRulerView is created in code, not from a nib")
    }

    /// Makes the gutter wide enough for the largest line number (at least three digits).
    private func updateThickness() {
        let digits = max(String(lineIndex.lineCount).count, 3)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: numberAttributes).width) + Self.padding * 2
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        // Only the lines on screen are drawn, so cost does not grow with file size.
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let visibleCharacters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let firstLine = lineIndex.lineNumber(atOffset: visibleCharacters.location)
        let lastLine = lineIndex.lineNumber(atOffset: NSMaxRange(visibleCharacters))
        let textLength = textView.textStorage?.length ?? 0

        for line in firstLine...lastLine {
            guard let offset = lineIndex.offset(ofLine: line) else { break }

            let lineRect: NSRect
            if offset < textLength {
                let glyph = layoutManager.glyphIndexForCharacter(at: offset)
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                // The empty last line after a trailing newline (or in an empty file).
                lineRect = layoutManager.extraLineFragmentRect
            }
            guard lineRect.height > 0 else { continue }

            let label = String(line) as NSString
            let topInTextView = NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y)
            let top = convert(topInTextView, from: textView).y

            // A line with a build message gets a colored badge behind its number.
            var attributes = numberAttributes
            if let severity = lineMarkers[line] {
                let badge = NSRect(x: 3, y: top + 1, width: ruleThickness - 6, height: lineRect.height - 2)
                IssuesViewController.color(for: severity).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
                attributes[.foregroundColor] = severity == .warning ? NSColor.black : NSColor.white
            }
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: ruleThickness - Self.padding - size.width, y: top + (lineRect.height - size.height) / 2),
                withAttributes: attributes
            )
        }
    }
}
