import AppKit

/// The gutter down the left side of the editor. It shows breakpoints on the
/// left, line numbers in the middle, and a green pointer on the right edge
/// for the line where the program has stopped. Clicking a line toggles a
/// breakpoint on it.
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

    /// Lines that have machine code, so a breakpoint can stop there. Shown as
    /// faint ticks only while hovering over the gutter. Empty when no debug
    /// session is running.
    var executableLines: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    /// The line the stopped program will run next, marked with a green band
    /// and a matching green pointer on the right edge of the gutter.
    var programCounterLine: Int? {
        didSet { needsDisplay = true }
    }

    /// Whether the pointer is currently inside the gutter's visible bounds.
    private(set) var isMouseInsideGutter = false {
        didSet {
            if isMouseInsideGutter != oldValue {
                needsDisplay = true
            }
        }
    }

    /// Executable-line ticks are revealed only while hovering over the gutter.
    var showsExecutableLineTicks: Bool {
        isMouseInsideGutter
    }

    /// Called with a line number when that line is clicked.
    var onClickLine: ((Int) -> Void)?

    /// The width of the left strip for breakpoints and hover-only ticks.
    private static let markStripWidth: CGFloat = 14
    /// Space to the right of line numbers, also holding the PC pointer.
    private static let pointerStripWidth: CGFloat = 14

    private var gutterTrackingArea: NSTrackingArea?

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

    /// Whether a breakpoint-possible tick should be drawn for `line` right now.
    func shouldDrawExecutableLineTick(forLine line: Int) -> Bool {
        showsExecutableLineTicks
            && executableLines.contains(line)
            && !breakpointLines.contains(line)
            && !disabledBreakpointLines.contains(line)
    }

    /// Makes the gutter wide enough for the largest line number (at least three digits).
    private func updateThickness() {
        let digits = max(String(lineIndex.lineCount).count, 3)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = Self.markStripWidth
            + ceil(sample.size(withAttributes: numberAttributes).width)
            + Self.pointerStripWidth
        if abs(ruleThickness - width) > 0.5 {
            ruleThickness = width
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let gutterTrackingArea {
            removeTrackingArea(gutterTrackingArea)
        }
        var options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeInKeyWindow,
            .inVisibleRect
        ]
        if isMouseInsideGutter {
            options.insert(.assumeInside)
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        gutterTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isMouseInsideGutter = false
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInsideGutter = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInsideGutter = false
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

            let topInTextView = NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y)
            let top = convert(topInTextView, from: textView).y
            drawRow(forLine: line, top: top, height: lineRect.height)
        }
    }

    private func drawRow(forLine line: Int, top: CGFloat, height: CGFloat) {
        let isProgramCounter = line == programCounterLine
        if isProgramCounter {
            EditorTheme.executionLineColor.setFill()
            NSRect(x: 0, y: top, width: max(ruleThickness - 1, 0), height: height).fill(using: .sourceOver)
        }

        // A line with a build message gets a colored badge behind its number.
        var attributes = numberAttributes
        if isProgramCounter {
            attributes[.foregroundColor] = NSColor.labelColor
        }
        if let severity = lineMarkers[line] {
            let badge = NSRect(
                x: Self.markStripWidth,
                y: top + 1,
                width: ruleThickness - Self.markStripWidth - Self.pointerStripWidth + 2.5,
                height: height - 2
            )
            IssuesViewController.color(for: severity).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            attributes[.foregroundColor] = severity == .warning ? NSColor.black : NSColor.white
        }

        let label = String(line) as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: ruleThickness - Self.pointerStripWidth - size.width,
                y: top + (height - size.height) / 2
            ),
            withAttributes: attributes
        )
        drawMarks(forLine: line, in: NSRect(x: 0, y: top, width: Self.markStripWidth, height: height))
        if isProgramCounter {
            let pointerStrip = NSRect(
                x: ruleThickness - Self.pointerStripWidth + 3,
                y: top,
                width: Self.pointerStripWidth - 4.5,
                height: height
            )
            drawProgramCounterPointer(in: pointerStrip)
        }
    }

    /// Draws the breakpoint or hover-only executable-line tick for one line
    /// into its part of the left strip.
    private func drawMarks(forLine line: Int, in strip: NSRect) {
        let side = min(strip.height - 5, 9)
        let mark = NSRect(x: strip.midX - side / 2, y: strip.midY - side / 2, width: side, height: side)

        if breakpointLines.contains(line) {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: mark).fill()
        } else if disabledBreakpointLines.contains(line) {
            let ring = NSBezierPath(ovalIn: mark.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            NSColor.systemRed.withAlphaComponent(0.6).setStroke()
            ring.stroke()
        } else if shouldDrawExecutableLineTick(forLine: line) {
            let tickWidth: CGFloat = 2.5
            let tickHeight = max(side - 1.5, 4)
            let tickRect = NSRect(
                x: strip.midX - tickWidth / 2,
                y: strip.midY - tickHeight / 2,
                width: tickWidth,
                height: tickHeight
            )
            EditorTheme.executableLineTickColor.setFill()
            NSBezierPath(roundedRect: tickRect, xRadius: tickWidth / 2, yRadius: tickWidth / 2).fill()
        }
    }

    /// Draws an Xcode-style green execution pointer on the right edge of the
    /// gutter, pointing cleanly into the highlighted line of code.
    private func drawProgramCounterPointer(in strip: NSRect) {
        let pointer = Self.programCounterPointerPath(in: strip)
        EditorTheme.executionLineAccentColor.setFill()
        pointer.fill()
    }

    /// Crisp right-pointing pentagon/arrow path fitted inside `strip`.
    static func programCounterPointerPath(in strip: NSRect) -> NSBezierPath {
        let height = min(strip.height - 5, 9)
        let width = min(strip.width, 9.5)
        let box = NSRect(
            x: strip.maxX - width,
            y: strip.midY - height / 2,
            width: width,
            height: height
        )
        let radius: CGFloat = min(1.5, height * 0.2)
        let shoulderX = box.maxX - height * 0.45

        let path = NSBezierPath()
        path.move(to: NSPoint(x: box.minX + radius, y: box.minY))
        path.line(to: NSPoint(x: shoulderX, y: box.minY))
        path.line(to: NSPoint(x: box.maxX, y: box.midY))
        path.line(to: NSPoint(x: shoulderX, y: box.maxY))
        path.line(to: NSPoint(x: box.minX + radius, y: box.maxY))
        path.curve(
            to: NSPoint(x: box.minX, y: box.maxY - radius),
            controlPoint1: NSPoint(x: box.minX, y: box.maxY),
            controlPoint2: NSPoint(x: box.minX, y: box.maxY)
        )
        path.line(to: NSPoint(x: box.minX, y: box.minY + radius))
        path.curve(
            to: NSPoint(x: box.minX + radius, y: box.minY),
            controlPoint1: NSPoint(x: box.minX, y: box.minY),
            controlPoint2: NSPoint(x: box.minX, y: box.minY)
        )
        path.close()
        return path
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
