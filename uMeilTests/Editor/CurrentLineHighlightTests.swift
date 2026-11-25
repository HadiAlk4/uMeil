import AppKit
import Testing
@testable import uMeil

@MainActor
struct CurrentLineHighlightTests {
    private func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor? {
        var result: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return result
    }

    private func makeEditor(
        text: String,
        fileName: String = "main.c"
    ) throws -> (EditorViewController, TemporaryDirectory) {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: fileName)
        try Data(text.utf8).write(to: file)
        let editor = EditorViewController()
        editor.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        editor.view.layoutSubtreeIfNeeded()
        try editor.open(file)
        editor.view.layoutSubtreeIfNeeded()
        return (editor, temp)
    }

    private func editorTextView(of editor: EditorViewController) throws -> EditorTextView {
        try #require(editor.textView as? EditorTextView)
    }

    // MARK: - Theme color

    @Test func currentLineColorAdaptsBetweenLightAndDarkAndStaysFaint() throws {
        let light = try #require(resolved(EditorTheme.currentLineColor, in: .aqua))
        let dark = try #require(resolved(EditorTheme.currentLineColor, in: .darkAqua))

        #expect(light != dark)
        #expect(light.alphaComponent > 0 && light.alphaComponent < 0.15)
        #expect(dark.alphaComponent > 0 && dark.alphaComponent < 0.15)
    }

    // MARK: - Lifecycle and selection

    @Test func inactiveBeforeOpenAndClearedOnClose() throws {
        let editor = EditorViewController()
        editor.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        editor.view.layoutSubtreeIfNeeded()
        let textView = try editorTextView(of: editor)

        #expect(!textView.highlightsCurrentLine)
        #expect(textView.currentLineHighlightRect == nil)

        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("int a = 1;\nint b = 2;\n".utf8).write(to: file)
        try editor.open(file)
        editor.view.layoutSubtreeIfNeeded()

        #expect(textView.highlightsCurrentLine)
        let openRect = try #require(textView.currentLineHighlightRect)
        #expect(openRect.width == textView.bounds.width)
        #expect(openRect.width > 0)
        #expect(openRect.height > 0)

        editor.close(hasFolder: true)
        #expect(!textView.highlightsCurrentLine)
        #expect(textView.currentLineHighlightRect == nil)
    }

    @Test func movesWithCursorAndHidesWhileTextIsSelected() throws {
        let (editor, _) = try makeEditor(text: "int a = 1;\nint b = 2;\nint c = 3;\n")
        let textView = try editorTextView(of: editor)

        let line1Rect = try #require(textView.currentLineHighlightRect)

        // Move caret to line 2 ("int b = 2;").
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        let line2Rect = try #require(textView.currentLineHighlightRect)
        #expect(line2Rect.minY > line1Rect.minY)
        #expect(line2Rect.width == textView.bounds.width)

        // Selecting text hides the current-line highlight.
        textView.setSelectedRange(NSRange(location: 11, length: 5))
        #expect(textView.currentLineHighlightRect == nil)

        // Collapsing back to a caret restores it on line 3.
        textView.setSelectedRange(NSRange(location: 22, length: 0))
        let line3Rect = try #require(textView.currentLineHighlightRect)
        #expect(line3Rect.minY > line2Rect.minY)
    }

    // MARK: - Empty documents and trailing lines

    @Test func highlightsEmptyDocumentViaExtraLineFragment() throws {
        let (editor, _) = try makeEditor(text: "")
        let textView = try editorTextView(of: editor)

        let rect = try #require(textView.currentLineHighlightRect)
        #expect(rect.height > 0)
        #expect(rect.minY == textView.textContainerOrigin.y)
        #expect(rect.width == textView.bounds.width)
    }

    @Test func highlightsTrailingEmptyLineAfterFinalNewline() throws {
        let (editor, _) = try makeEditor(text: "int a = 1;\n")
        let textView = try editorTextView(of: editor)

        let line1Rect = try #require(textView.currentLineHighlightRect)

        // Offset 11 is after the trailing newline, on the empty second line.
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        let line2Rect = try #require(textView.currentLineHighlightRect)

        #expect(line2Rect.height > 0)
        #expect(line2Rect.minY >= line1Rect.maxY - 0.5)
        #expect(line2Rect.width == textView.bounds.width)
    }

    @Test func highlightsLastLineWhenNoTrailingNewline() throws {
        let (editor, _) = try makeEditor(text: "int a = 1;")
        let textView = try editorTextView(of: editor)

        let startRect = try #require(textView.currentLineHighlightRect)
        textView.setSelectedRange(NSRange(location: 10, length: 0))
        let endRect = try #require(textView.currentLineHighlightRect)

        #expect(endRect == startRect)
    }

    // MARK: - Text, font, appearance, and rendering

    @Test func followsInsertedNewlinesOnTextChange() throws {
        let (editor, _) = try makeEditor(text: "int a;")
        let textView = try editorTextView(of: editor)

        textView.setSelectedRange(NSRange(location: 6, length: 0))
        let before = try #require(textView.currentLineHighlightRect)
        textView.insertText("\n", replacementRange: NSRange(location: 6, length: 0))
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))
        let after = try #require(textView.currentLineHighlightRect)

        #expect(after.minY > before.minY)
    }

    @Test func updatesHeightWhenFontSizeChanges() throws {
        let settings = AppearanceSettings.shared
        let originalSize = settings.fontSize
        defer { settings.fontSize = originalSize }

        settings.fontSize = 12
        let (editor, _) = try makeEditor(text: "int a;\n")
        editor.applyFontSettings()
        let textView = try editorTextView(of: editor)
        let smallHeight = try #require(textView.currentLineHighlightRect).height

        settings.fontSize = 24
        editor.applyFontSettings()
        let largeHeight = try #require(textView.currentLineHighlightRect).height

        #expect(largeHeight > smallHeight)
    }

    @Test func doesNotPolluteUndoManager() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("line 1\nline 2\nline 3\n".utf8).write(to: file)

        let defaults = TestDefaults()
        let controller = MainWindowController(defaults: defaults)
        controller.openFolder(temp.url)
        try controller.editor.open(file)
        let undoManager = try #require(controller.editor.textView.undoManager)

        controller.editor.textView.setSelectedRange(NSRange(location: 7, length: 0))
        controller.editor.textView.setSelectedRange(NSRange(location: 14, length: 0))
        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 4))
        controller.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(!undoManager.canUndo)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func rendersDistinctTintOnCurrentLineInLightAndDarkMode(appearanceName: NSAppearance.Name) throws {
        let (editor, _) = try makeEditor(text: "a\nb\nc\n")
        let textView = try editorTextView(of: editor)
        textView.appearance = NSAppearance(named: appearanceName)
        textView.viewDidChangeEffectiveAppearance()

        // Put the cursor on line 2 and render into a bitmap.
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let line2Rect = try #require(textView.currentLineHighlightRect)
        let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        // Sample blank space far to the right of the single-letter lines,
        // converting view points to bitmap pixels for Retina displays.
        let scaleX = CGFloat(bitmap.pixelsWide) / textView.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / textView.bounds.height
        let sampleX = Int(min(textView.bounds.width - 20, 200) * scaleX)
        let line1Y = Int(max(0, line2Rect.minY - line2Rect.height / 2) * scaleY)
        let line2Y = Int(line2Rect.midY * scaleY)
        let unhighlighted = try #require(bitmap.colorAt(x: sampleX, y: line1Y)?.usingColorSpace(.sRGB))
        let highlighted = try #require(bitmap.colorAt(x: sampleX, y: line2Y)?.usingColorSpace(.sRGB))

        #expect(highlighted != unhighlighted)
    }

    @Test func coexistsWithBuildMessageAndExecutionLine() throws {
        let (editor, _) = try makeEditor(text: "int a;\nint b;\n")
        let textView = try editorTextView(of: editor)
        editor.setBuildMessages([1: .init(severity: .error, text: "oops")])
        editor.showExecutionLine(2)
        textView.setSelectedRange(NSRange(location: 7, length: 0))

        let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        #expect(textView.currentLineHighlightRect != nil)
        #expect(editor.executionLine == 2)
    }
}
