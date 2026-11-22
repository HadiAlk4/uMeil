import AppKit

/// The gutter down the left side of the editor. It shows line numbers and,
/// in a strip to their left, breakpoints and where the program has stopped.
/// Clicking a line sets or removes a breakpoint on it.
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

    /// Lines with a breakpoint, drawn as a red circle.
    var breakpointLines: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    /// Lines with a breakpoint that is turned off, drawn as a hollow circle.
    var disabledBreakpointLines: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    /// Lines that have machine code, so a breakpoint can stop there. Drawn
    /// as a gray block. Empty when no debug session is running.
    var executableLines: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    /// The line the stopped program will run next, drawn as a yellow arrow.
    var programCounterLine: Int? {
        didSet { needsDisplay = true }
    }

    /// Called with a line number when that line is clicked.
    var onClickLine: ((Int) -> Void)?

    private static let padding: CGFloat = 8
    /// The width of the strip for breakpoints and the program counter.
    private static let markStripWidth: CGFloat = 14

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

    /// Redraws the numbers in the current font, widening or narrowing the
    /// gutter to fit them.
    func fontDidChange() {
        updateThickness()
        needsDisplay = true
    }

    /// Makes the gutter wide enough for the largest line number (at least three digits).
    private func updateThickness() {
        let digits = max(String(lineIndex.lineCount).count, 3)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = Self.markStripWidth + ceil(sample.size(withAttributes: numberAttributes).width) + Self.padding
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
                let badge = NSRect(
                    x: Self.markStripWidth,
                    y: top + 1,
                    width: ruleThickness - Self.markStripWidth - 3,
                    height: lineRect.height - 2
                )
                IssuesViewController.color(for: severity).setFill()
                NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
                attributes[.foregroundColor] = severity == .warning ? NSColor.black : NSColor.white
            }
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: ruleThickness - Self.padding - size.width, y: top + (lineRect.height - size.height) / 2),
                withAttributes: attributes
            )
            drawMarks(forLine: line, in: NSRect(x: 0, y: top, width: Self.markStripWidth, height: lineRect.height))
        }
    }

    /// Draws the breakpoint, executable-line, and program counter marks for
    /// one line into its part of the strip.
    private func drawMarks(forLine line: Int, in strip: NSRect) {
        let side = min(strip.height - 4, 10)
        let mark = NSRect(x: strip.midX - side / 2, y: strip.midY - side / 2, width: side, height: side)

        if breakpointLines.contains(line) {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: mark).fill()
        } else if disabledBreakpointLines.contains(line) {
            let ring = NSBezierPath(ovalIn: mark.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.systemRed.withAlphaComponent(0.6).setStroke()
            ring.stroke()
        } else if executableLines.contains(line) {
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(rect: mark.insetBy(dx: side / 2 - 1.5, dy: 0)).fill()
        }

        if line == programCounterLine {
            // An arrow pointing at the code, over a breakpoint if there is one.
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: mark.minX, y: mark.minY + side * 0.3))
            arrow.line(to: NSPoint(x: mark.midX, y: mark.minY + side * 0.3))
            arrow.line(to: NSPoint(x: mark.midX, y: mark.minY))
            arrow.line(to: NSPoint(x: mark.maxX + 2, y: mark.midY))
            arrow.line(to: NSPoint(x: mark.midX, y: mark.maxY))
            arrow.line(to: NSPoint(x: mark.midX, y: mark.maxY - side * 0.3))
            arrow.line(to: NSPoint(x: mark.minX, y: mark.maxY - side * 0.3))
            arrow.close()
            NSColor.systemYellow.setFill()
            arrow.fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            arrow.lineWidth = 0.75
            arrow.stroke()
        }
    }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        if let line = lineNumber(at: convert(event.locationInWindow, from: nil)) {
            onClickLine?(line)
        }
    }

    /// The line drawn at `point` in the gutter, or `nil` below the last line.
    func lineNumber(at point: NSPoint) -> Int? {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return nil }

        let inTextView = convert(point, to: textView)
        let inContainer = NSPoint(x: 0, y: inTextView.y - textView.textContainerOrigin.y)
        let textLength = textView.textStorage?.length ?? 0

        if layoutManager.extraLineFragmentRect.height > 0,
           inContainer.y >= layoutManager.extraLineFragmentRect.minY {
            // The empty last line after a trailing newline (or in an empty file).
            return inContainer.y < layoutManager.extraLineFragmentRect.maxY ? lineIndex.lineCount : nil
        }
        guard textLength > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard inContainer.y >= lineRect.minY, inContainer.y < lineRect.maxY else { return nil }
        return lineIndex.lineNumber(atOffset: layoutManager.characterIndexForGlyph(at: glyph))
    }
}
