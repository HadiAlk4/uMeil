import AppKit
import Testing
@testable import uMeil

@MainActor
struct LineNumberRulerViewTests {
    private struct EditorFixture {
        let editor: EditorViewController
        let ruler: LineNumberRulerView
        let window: NSWindow
        let temp: TemporaryDirectory
    }

    private func makeEditorInWindow(
        text: String,
        appearance: NSAppearance.Name = .aqua
    ) throws -> EditorFixture {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data(text.utf8).write(to: file)

        let editor = EditorViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = editor
        try editor.open(file)
        window.layoutIfNeeded()
        editor.view.layoutSubtreeIfNeeded()

        let ruler = try #require(editor.ruler)
        return EditorFixture(editor: editor, ruler: ruler, window: window, temp: temp)
    }

    private func makeHoverEvent(type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try #require(
            NSEvent.enterExitEvent(
                with: type,
                location: NSPoint(x: 10, y: 10),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                trackingNumber: 1,
                userData: nil
            )
        )
    }

    private func lineRectInRuler(
        forLine line: Int,
        editor: EditorViewController,
        ruler: LineNumberRulerView
    ) throws -> NSRect {
        let textView = editor.textView
        let layoutManager = try #require(textView.layoutManager)
        let offset = try #require(editor.lineIndex.offset(ofLine: line))
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let topInText = NSPoint(x: 0, y: fragment.minY + textView.textContainerOrigin.y)
        let top = ruler.convert(topInText, from: textView).y
        return NSRect(x: 0, y: top, width: ruler.ruleThickness, height: fragment.height)
    }

    private func render(_ view: NSView, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        return rep
    }

    /// Samples colors inside `rect` (in `view`'s flipped point coordinates).
    private func sampleColors(in rect: NSRect, of view: NSView, rep: NSBitmapImageRep) -> [NSColor] {
        let scaleX = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        let scaleY = CGFloat(rep.pixelsHigh) / max(view.bounds.height, 1)
        let minX = max(0, Int(floor(rect.minX * scaleX)))
        let maxX = min(rep.pixelsWide - 1, Int(ceil(rect.maxX * scaleX)))
        let minY = max(0, Int(floor(rect.minY * scaleY)))
        let maxY = min(rep.pixelsHigh - 1, Int(ceil(rect.maxY * scaleY)))
        guard minX <= maxX, minY <= maxY else { return [] }

        var colors: [NSColor] = []
        for row in minY...maxY {
            for column in minX...maxX {
                if let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) {
                    colors.append(color)
                }
            }
        }
        return colors
    }

    // MARK: - Executable-line hover ticks

    @Test func executableLineTicksStayHiddenUntilPointerEntersGutter() throws {
        let code = "int main(void) {\n    int a = 1;\n    int b = 2;\n    int c = 3;\n    return a + b + c;\n}\n"
        let fixture = try makeEditorInWindow(text: code)
        let (editor, ruler, window) = (fixture.editor, fixture.ruler, fixture.window)
        editor.executableLines = [2, 3, 4, 5]
        editor.breakpointLines = [3]
        editor.disabledBreakpointLines = [4]

        #expect(!ruler.isMouseInsideGutter)
        #expect(!ruler.showsExecutableLineTicks)
        #expect(!ruler.shouldDrawExecutableLineTick(forLine: 2))
        #expect(!ruler.shouldDrawExecutableLineTick(forLine: 5))

        ruler.mouseEntered(with: try makeHoverEvent(type: .mouseEntered, in: window))
        #expect(ruler.isMouseInsideGutter)
        #expect(ruler.showsExecutableLineTicks)
        #expect(ruler.shouldDrawExecutableLineTick(forLine: 2))
        #expect(ruler.shouldDrawExecutableLineTick(forLine: 5))
        #expect(!ruler.shouldDrawExecutableLineTick(forLine: 1))
        #expect(!ruler.shouldDrawExecutableLineTick(forLine: 3))
        #expect(!ruler.shouldDrawExecutableLineTick(forLine: 4))

        ruler.mouseExited(with: try makeHoverEvent(type: .mouseExited, in: window))
        #expect(!ruler.isMouseInsideGutter)
        #expect(!ruler.showsExecutableLineTicks)
        #expect(!ruler.shouldDrawExecutableLineTick(forLine: 2))
    }

    @Test func trackingAreaUpdatesCleanlyAcrossResizesAndWindowChanges() throws {
        let code = (1...20).map { "int line\($0) = \($0);" }.joined(separator: "\n") + "\n"
        let fixture = try makeEditorInWindow(text: code)
        let (ruler, window) = (fixture.ruler, fixture.window)

        ruler.updateTrackingAreas()
        #expect(ruler.trackingAreas.count == 1)
        let initialArea = try #require(ruler.trackingAreas.first)
        #expect(initialArea.options.contains(.mouseEnteredAndExited))
        #expect(initialArea.options.contains(.activeInKeyWindow))
        #expect(initialArea.options.contains(.inVisibleRect))
        #expect(!initialArea.options.contains(.assumeInside))

        // Resizing must replace the tracking area without leaking duplicates.
        window.setContentSize(NSSize(width: 800, height: 480))
        window.layoutIfNeeded()
        ruler.updateTrackingAreas()
        #expect(ruler.trackingAreas.count == 1)

        // Updating tracking areas while hovered preserves inside assumption.
        ruler.mouseEntered(with: try makeHoverEvent(type: .mouseEntered, in: window))
        ruler.updateTrackingAreas()
        #expect(ruler.isMouseInsideGutter)
        #expect(ruler.trackingAreas.count == 1)
        #expect(ruler.trackingAreas.first?.options.contains(.assumeInside) == true)

        // Detaching from the window resets hover state cleanly.
        window.contentViewController = nil
        #expect(!ruler.isMouseInsideGutter)
    }

    @Test func executableLineTicksRenderOnlyWhileHovering() throws {
        let code = "int main(void) {\n    int a = 1;\n    return a;\n}\n"
        let fixture = try makeEditorInWindow(text: code, appearance: .aqua)
        let (editor, ruler, window) = (fixture.editor, fixture.ruler, fixture.window)
        editor.executableLines = [2]

        let line2 = try lineRectInRuler(forLine: 2, editor: editor, ruler: ruler)
        let strip = NSRect(x: 2, y: line2.minY + 1, width: 10, height: max(line2.height - 2, 1))

        let baselineRep = try render(ruler, appearance: .aqua)
        let baselineColors = sampleColors(in: strip, of: ruler, rep: baselineRep)
        let baselineMinLuma = baselineColors.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 }.min()

        ruler.mouseEntered(with: try makeHoverEvent(type: .mouseEntered, in: window))
        let hoveredRep = try render(ruler, appearance: .aqua)
        let hoveredColors = sampleColors(in: strip, of: ruler, rep: hoveredRep)
        let hoveredMinLuma = hoveredColors.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 }.min()

        // Without hover, the strip on line 2 is uniformly blank (no tick drawn).
        let baselineMaxLuma = baselineColors.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 }.max()
        #expect(try #require(baselineMaxLuma) - #require(baselineMinLuma) < 0.02)
        // With hover, a subtle darker tick appears inside the strip.
        #expect(try #require(hoveredMinLuma) < #require(baselineMinLuma) - 0.08)
    }

    // MARK: - Unified green program-counter marker and highlight

    @Test func showExecutionLineUpdatesRulerAndEditorTextViewTogether() throws {
        let code = "int main(void) {\n    int x = 1;\n    return x;\n}\n"
        let fixture = try makeEditorInWindow(text: code)
        let (editor, ruler) = (fixture.editor, fixture.ruler)
        let textView = try #require(editor.textView as? EditorTextView)

        editor.showExecutionLine(2)
        #expect(editor.executionLine == 2)
        #expect(ruler.programCounterLine == 2)
        #expect(textView.executionLineStart == editor.lineIndex.offset(ofLine: 2))

        editor.showExecutionLine(nil)
        #expect(editor.executionLine == nil)
        #expect(ruler.programCounterLine == nil)
        #expect(textView.executionLineStart == nil)
    }

    @Test func programCounterPointerPathFitsStripAndPointsRight() {
        let strip = NSRect(x: 34, y: 100, width: 10, height: 17)
        let path = LineNumberRulerView.programCounterPointerPath(in: strip)

        #expect(!path.isEmpty)
        #expect(path.bounds.minX >= strip.minX - 0.01)
        #expect(path.bounds.maxX <= strip.maxX + 0.01)
        #expect(path.bounds.minY >= strip.minY)
        #expect(path.bounds.maxY <= strip.maxY)
        #expect(abs(path.bounds.midY - strip.midY) < 0.01)
        #expect(path.contains(NSPoint(x: path.bounds.maxX - 0.5, y: strip.midY)))
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func programCounterDrawsMatchingGreenPointerAndLineHighlightWithBreakpoint(
        appearance: NSAppearance.Name
    ) throws {
        let code = "int main(void) {\n    int x = 1;\n    x += 2;\n    return x;\n}\n"
        let fixture = try makeEditorInWindow(text: code, appearance: appearance)
        let (editor, ruler) = (fixture.editor, fixture.ruler)
        editor.breakpointLines = [3]
        editor.showExecutionLine(3)

        let line3 = try lineRectInRuler(forLine: 3, editor: editor, ruler: ruler)
        let rulerRep = try render(ruler, appearance: appearance)
        let pointerStrip = NSRect(
            x: ruler.ruleThickness - 11,
            y: line3.minY,
            width: 10,
            height: line3.height
        )
        let breakpointStrip = NSRect(x: 0, y: line3.minY, width: 14, height: line3.height)

        let pointerColors = sampleColors(in: pointerStrip, of: ruler, rep: rulerRep)
        let breakpointColors = sampleColors(in: breakpointStrip, of: ruler, rep: rulerRep)
        let allLineColors = sampleColors(in: line3, of: ruler, rep: rulerRep)

        // Crisp green PC pointer on the right edge of the gutter.
        #expect(pointerColors.contains {
            $0.greenComponent > $0.redComponent + 0.20 && $0.greenComponent > $0.blueComponent + 0.15
        })
        // Red breakpoint circle stays cleanly separated on the left strip.
        #expect(breakpointColors.contains { $0.redComponent > $0.greenComponent + 0.25 })
        // No yellow or orange pixels anywhere on the execution line in the gutter.
        #expect(!allLineColors.contains {
            $0.redComponent > 0.70 && $0.greenComponent > 0.45 && $0.blueComponent < 0.25
        })

        // Matching green execution highlight in the editor text view on line 3.
        let textView = editor.textView
        let layoutManager = try #require(textView.layoutManager)
        let offset = try #require(editor.lineIndex.offset(ofLine: 3))
        let glyph = layoutManager.glyphIndexForCharacter(at: offset)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let sampleX = min(
            textView.textContainerOrigin.x + used.maxX + 12,
            max(textView.bounds.maxX - 24, textView.bounds.minX)
        )
        let emptyAreaOfLine3 = NSRect(
            x: sampleX,
            y: fragment.minY + textView.textContainerOrigin.y + 2,
            width: min(40, max(textView.bounds.maxX - sampleX, 1)),
            height: max(fragment.height - 4, 2)
        )
        let textRep = try render(textView, appearance: appearance)
        let highlightColors = sampleColors(in: emptyAreaOfLine3, of: textView, rep: textRep)
        #expect(!highlightColors.isEmpty)
        #expect(highlightColors.contains {
            $0.greenComponent > $0.redComponent + 0.04 && $0.greenComponent > $0.blueComponent + 0.02
        })
    }
}
