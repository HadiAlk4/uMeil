import AppKit
import Testing
@testable import uMeil

@MainActor
@Suite(.serialized)
struct BracketMatchingTests {
    // MARK: - Basic and nested pairs

    @Test func matchesParensBracketsAndBracesForwardAndBackward() {
        let code = "int f(int a[4]) { return a[0]; }"

        // '(' at 5 <-> ')' at 14 (note: offset 13 is ']', so cursor 14 checks 13 first)
        #expect(BracketMatcher.match(in: code, cursor: 5) == .init(anchorOffset: 5, matchOffset: 14))
        #expect(BracketMatcher.match(in: code, cursor: 6) == .init(anchorOffset: 5, matchOffset: 14))
        #expect(BracketMatcher.match(in: code, cursor: 15) == .init(anchorOffset: 14, matchOffset: 5))

        // '[' at 11 <-> ']' at 13
        #expect(BracketMatcher.match(in: code, cursor: 11) == .init(anchorOffset: 11, matchOffset: 13))
        #expect(BracketMatcher.match(in: code, cursor: 12) == .init(anchorOffset: 11, matchOffset: 13))
        #expect(BracketMatcher.match(in: code, cursor: 13) == .init(anchorOffset: 13, matchOffset: 11))
        #expect(BracketMatcher.match(in: code, cursor: 14) == .init(anchorOffset: 13, matchOffset: 11))

        // '{' at 16 <-> '}' at 31
        #expect(BracketMatcher.match(in: code, cursor: 16) == .init(anchorOffset: 16, matchOffset: 31))
        #expect(BracketMatcher.match(in: code, cursor: 17) == .init(anchorOffset: 16, matchOffset: 31))
        #expect(BracketMatcher.match(in: code, cursor: 31) == .init(anchorOffset: 31, matchOffset: 16))
        #expect(BracketMatcher.match(in: code, cursor: 32) == .init(anchorOffset: 31, matchOffset: 16))
    }

    @Test func matchesNestedPairsAccurately() {
        let code = "foo(bar[baz(1, 2)] + {3})"
        #expect(BracketMatcher.match(in: code, cursor: 4) == .init(anchorOffset: 3, matchOffset: 24))
        #expect(BracketMatcher.match(in: code, cursor: 25) == .init(anchorOffset: 24, matchOffset: 3))
        #expect(BracketMatcher.match(in: code, cursor: 12) == .init(anchorOffset: 11, matchOffset: 16))
        #expect(BracketMatcher.match(in: code, cursor: 17) == .init(anchorOffset: 16, matchOffset: 11))
        #expect(BracketMatcher.match(in: code, cursor: 8) == .init(anchorOffset: 7, matchOffset: 17))
        #expect(BracketMatcher.match(in: code, cursor: 18) == .init(anchorOffset: 17, matchOffset: 7))
        #expect(BracketMatcher.match(in: code, cursor: 22) == .init(anchorOffset: 21, matchOffset: 23))
    }

    // MARK: - Cursor priority and boundaries

    @Test func prefersCharacterBeforeCursorOverCharacterAtCursor() {
        let code = "()[]"
        #expect(BracketMatcher.match(in: code, cursor: 2) == .init(anchorOffset: 1, matchOffset: 0))
        #expect(BracketMatcher.match(in: "a[]", cursor: 1) == .init(anchorOffset: 1, matchOffset: 2))
        #expect(BracketMatcher.match(in: code, cursor: 0) == .init(anchorOffset: 0, matchOffset: 1))
    }

    @Test func returnsNilForEmptyOutOfBoundsOrNonBracketPositions() {
        #expect(BracketMatcher.match(in: "", cursor: 0) == nil)
        #expect(BracketMatcher.match(in: "()", cursor: -1) == nil)
        #expect(BracketMatcher.match(in: "()", cursor: 3) == nil)
        #expect(BracketMatcher.match(in: "int x = 0;", cursor: 4) == nil)
    }

    @Test func handlesUnmatchedAndInterleavedBrackets() {
        #expect(BracketMatcher.match(in: "(", cursor: 1) == nil)
        #expect(BracketMatcher.match(in: ")", cursor: 1) == nil)
        #expect(BracketMatcher.match(in: "({)}", cursor: 1) == nil)
        #expect(BracketMatcher.match(in: "({)}", cursor: 3) == nil)
        #expect(BracketMatcher.match(in: "((a)", cursor: 1) == nil)
        #expect(BracketMatcher.match(in: "((a)", cursor: 2) == .init(anchorOffset: 1, matchOffset: 3))

        let code = "void broken(void) { int x = (1; }\nvoid ok(void) { int y = (2); }\n"
        let openOffset = (code as NSString).range(of: "(2)").location
        #expect(BracketMatcher.match(in: code, cursor: openOffset + 1)
            == .init(anchorOffset: openOffset, matchOffset: openOffset + 2))
    }

    // MARK: - C-aware comments, strings, and char literals

    @Test func ignoresBracketsInsideLineCommentsAndLineContinuations() {
        let code = "int f( // ) ] }\n    int x // ( \\\n    )\n)"
        let openOffset = (code as NSString).range(of: "(").location
        let closeOffset = (code as NSString).length - 1
        #expect(BracketMatcher.match(in: code, cursor: openOffset + 1, mode: .c)
            == .init(anchorOffset: openOffset, matchOffset: closeOffset))
        #expect(BracketMatcher.match(in: code, cursor: closeOffset + 1, mode: .c)
            == .init(anchorOffset: closeOffset, matchOffset: openOffset))

        let commentBracket = (code as NSString).range(of: ") ]").location
        #expect(BracketMatcher.match(in: code, cursor: commentBracket + 1, mode: .c) == nil)
    }

    @Test func ignoresBracketsInsideBlockCommentsIncludingSlashStarSlash() {
        let code = "foo(/* ) ] { */ /*/ ) */ bar)"
        let closeOffset = (code as NSString).length - 1
        #expect(BracketMatcher.match(in: code, cursor: 4, mode: .c)
            == .init(anchorOffset: 3, matchOffset: closeOffset))
        #expect(BracketMatcher.match(in: code, cursor: closeOffset + 1, mode: .c)
            == .init(anchorOffset: closeOffset, matchOffset: 3))
        #expect(BracketMatcher.match(in: "foo(/* )", cursor: 4, mode: .c) == nil)
    }

    @Test func ignoresBracketsInsideStringsAndHandlesEscapes() {
        let code = #"printf("a ) \" ) \\", ")/*");"#
        let closeOffset = (code as NSString).length - 2
        #expect(BracketMatcher.match(in: code, cursor: 7, mode: .c) == .init(anchorOffset: 6, matchOffset: closeOffset))
        #expect(BracketMatcher.match(in: code, cursor: closeOffset + 1, mode: .c)
            == .init(anchorOffset: closeOffset, matchOffset: 6))

        let escapedSlash = #"f("\\", (1))"#
        #expect(BracketMatcher.match(in: escapedSlash, cursor: 2, mode: .c)
            == .init(anchorOffset: 1, matchOffset: (escapedSlash as NSString).length - 1))

        let inString = (code as NSString).range(of: ") \\\"").location
        #expect(BracketMatcher.match(in: code, cursor: inString + 1, mode: .c) == nil)
    }

    @Test func ignoresBracketsInsideCharLiteralsAndHandlesEscapes() {
        let code = #"if (c == ')' || c == '\'' || c == '\\' || c == '"') {}"#
        let closeOffset = (code as NSString).range(of: ") {}").location
        #expect(BracketMatcher.match(in: code, cursor: 4, mode: .c)
            == .init(anchorOffset: 3, matchOffset: closeOffset))
        #expect(BracketMatcher.match(in: code, cursor: closeOffset + 1, mode: .c)
            == .init(anchorOffset: closeOffset, matchOffset: 3))

        let inChar = (code as NSString).range(of: "')'").location + 1
        #expect(BracketMatcher.match(in: code, cursor: inChar + 1, mode: .c) == nil)
    }

    @Test func handlesPlainTextAndUTF16UnicodeOffsets() {
        let prose = "don't (forget // [this])"
        let openParen = (prose as NSString).range(of: "(").location
        let closeParen = (prose as NSString).length - 1
        #expect(BracketMatcher.match(in: prose, cursor: openParen + 1, mode: .plainText)
            == .init(anchorOffset: openParen, matchOffset: closeParen))

        let code = "/* 😊 */ (x)"
        let nsCode = code as NSString
        let openOffset = nsCode.range(of: "(").location
        let closeOffset = nsCode.range(of: ")").location
        #expect(openOffset == 9 && closeOffset == 11)
        #expect(BracketMatcher.match(in: code, cursor: closeOffset + 1, mode: .c)
            == .init(anchorOffset: closeOffset, matchOffset: openOffset))
    }
}

// MARK: - Editor integration

extension BracketMatchingTests {
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

    private func waitUntil(
        timeout: Duration = TestTiming.duration(.seconds(10)),
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            await Task.yield()
            if condition() || clock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func bracketHighlightAndFlashColorsAdaptBetweenLightAndDark() throws {
        let colors = [
            EditorTheme.bracketMatchBackgroundColor,
            EditorTheme.bracketMatchBorderColor,
            EditorTheme.bracketFlashBackgroundColor,
            EditorTheme.bracketFlashBorderColor
        ]
        for color in colors {
            let light = try #require(resolved(color, in: .aqua))
            let dark = try #require(resolved(color, in: .darkAqua))
            #expect(light != dark)
        }
        #expect(EditorHighlightState.defaultFlashDuration >= .milliseconds(200))
        #expect(EditorHighlightState.defaultFlashDuration <= .milliseconds(300))
    }

    @Test func highlightsMatchingBracketOnCursorMoveAndClearsOnSelectionOrClose() throws {
        let (editor, _) = try makeEditor(text: "int main(void) {\n    return 0;\n}\n")
        let textView = try editorTextView(of: editor)

        #expect(textView.bracketMatch == nil)
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        #expect(textView.bracketMatch == .init(anchorOffset: 8, matchOffset: 13))
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(textView.bracketMatch == .init(anchorOffset: 8, matchOffset: 13))
        textView.setSelectedRange(NSRange(location: 8, length: 2))
        #expect(textView.bracketMatch == nil)
        textView.setSelectedRange(NSRange(location: 32, length: 0))
        #expect(textView.bracketMatch == .init(anchorOffset: 31, matchOffset: 15))
        textView.setSelectedRange(NSRange(location: 20, length: 0))
        #expect(textView.bracketMatch == nil)
        textView.setSelectedRange(NSRange(location: 32, length: 0))
        editor.close(hasFolder: true)
        #expect(textView.bracketMatch == nil)
    }

    @Test func usesPlainTextModeForNonCFilesAndCModeForCFiles() throws {
        let prose = "don't (stop)"
        let (txtEditor, _) = try makeEditor(text: prose, fileName: "notes.txt")
        let txtView = try editorTextView(of: txtEditor)
        txtView.setSelectedRange(NSRange(location: (prose as NSString).length, length: 0))
        #expect(txtView.bracketMatch == .init(anchorOffset: 11, matchOffset: 6))

        let cCode = "int f(/* ) */ x) { return x; }"
        let (cEditor, _) = try makeEditor(text: cCode, fileName: "main.c")
        let cView = try editorTextView(of: cEditor)
        cView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(cView.bracketMatch == .init(anchorOffset: 5, matchOffset: 15))
    }

    @Test func typingClosingBracketFlashesMatchingOpenerAndClearsAutomatically() async throws {
        let (editor, _) = try makeEditor(text: "foo(bar")
        let textView = try editorTextView(of: editor)
        editor.highlightState.flashDuration = TestTiming.duration(.milliseconds(50))

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertText(")", replacementRange: NSRange(location: 7, length: 0))
        #expect(textView.bracketMatch == .init(anchorOffset: 7, matchOffset: 3))
        #expect(textView.flashingBracketRange == NSRange(location: 3, length: 1))

        try await waitUntil { textView.flashingBracketRange == nil }
        #expect(textView.flashingBracketRange == nil)
        #expect(editor.highlightState.flashTask == nil)
        #expect(textView.bracketMatch == .init(anchorOffset: 7, matchOffset: 3))
    }

    @Test func typingSquareAndCurlyClosersAlsoFlashMatchingOpeners() async throws {
        let (editor, _) = try makeEditor(text: "a[0")
        let textView = try editorTextView(of: editor)
        editor.highlightState.flashDuration = TestTiming.duration(.milliseconds(50))

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText("]", replacementRange: NSRange(location: 3, length: 0))
        #expect(textView.flashingBracketRange == NSRange(location: 1, length: 1))

        try await waitUntil { textView.flashingBracketRange == nil }
        #expect(textView.flashingBracketRange == nil)
        #expect(editor.highlightState.flashTask == nil)

        textView.insertText(" { x", replacementRange: NSRange(location: 4, length: 0))
        textView.insertText("}", replacementRange: NSRange(location: 8, length: 0))
        #expect(textView.flashingBracketRange == NSRange(location: 5, length: 1))
    }

    @Test func typingUnmatchedOrCommentedClosingBracketDoesNotFlash() throws {
        let (editor, _) = try makeEditor(text: "foo")
        let textView = try editorTextView(of: editor)
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText(")", replacementRange: NSRange(location: 3, length: 0))
        #expect(textView.flashingBracketRange == nil)

        let (commentEditor, _) = try makeEditor(text: "// (abc")
        let commentView = try editorTextView(of: commentEditor)
        commentView.setSelectedRange(NSRange(location: 7, length: 0))
        commentView.insertText(")", replacementRange: NSRange(location: 7, length: 0))
        #expect(commentView.flashingBracketRange == nil)
    }

    @Test func rapidClosingBracketsCancelPriorFlashCleanly() async throws {
        let (editor, _) = try makeEditor(text: "foo(bar(1")
        let textView = try editorTextView(of: editor)
        editor.highlightState.flashDuration = TestTiming.duration(.milliseconds(80))

        textView.setSelectedRange(NSRange(location: 9, length: 0))
        textView.insertText(")", replacementRange: NSRange(location: 9, length: 0))
        #expect(textView.flashingBracketRange == NSRange(location: 7, length: 1))
        let firstGeneration = editor.highlightState.flashGeneration

        textView.insertText(")", replacementRange: NSRange(location: 10, length: 0))
        #expect(editor.highlightState.flashGeneration == firstGeneration + 1)
        #expect(textView.flashingBracketRange == NSRange(location: 3, length: 1))

        try await waitUntil { textView.flashingBracketRange == nil }
        #expect(textView.flashingBracketRange == nil)
        #expect(editor.highlightState.flashTask == nil)
        #expect(textView.bracketMatch == .init(anchorOffset: 10, matchOffset: 3))
    }

    @Test func closeCancelsInFlightFlash() throws {
        let (editor, _) = try makeEditor(text: "foo(1")
        let textView = try editorTextView(of: editor)
        editor.highlightState.flashDuration = .seconds(10)

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(")", replacementRange: NSRange(location: 5, length: 0))
        #expect(textView.flashingBracketRange == NSRange(location: 3, length: 1))

        editor.close(hasFolder: true)
        #expect(textView.flashingBracketRange == nil)
        #expect(editor.highlightState.flashTask == nil)
    }

    @Test func neverPollutesUndoAndUndoDoesNotTriggerSpuriousFlash() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("foo(x".utf8).write(to: file)

        let defaults = TestDefaults()
        let controller = MainWindowController(defaults: defaults)
        controller.openFolder(temp.url)
        try controller.editor.open(file)
        let editor = controller.editor
        let textView = try editorTextView(of: editor)
        let undoManager = try #require(textView.undoManager)
        editor.highlightState.flashDuration = .seconds(10)

        textView.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(!undoManager.canUndo)

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(")", replacementRange: NSRange(location: 5, length: 0))
        #expect(textView.string == "foo(x)")
        #expect(textView.flashingBracketRange == NSRange(location: 3, length: 1))
        #expect(undoManager.canUndo)

        undoManager.undo()
        #expect(textView.string == "foo(x")
        #expect(!undoManager.canUndo)
        #expect(textView.flashingBracketRange == nil)

        undoManager.redo()
        #expect(textView.string == "foo(x)")
        #expect(textView.flashingBracketRange == nil)
        #expect(textView.bracketMatch == .init(anchorOffset: 5, matchOffset: 3))
    }

    @Test func syntaxHighlightingDoesNotClobberBracketMatchOrFlash() async throws {
        let (editor, _) = try makeEditor(text: "int main(void) {\n    return (1 + 2);\n}\n")
        let textView = try editorTextView(of: editor)
        editor.highlightState.flashDuration = .seconds(10)

        let endOfExpr = (textView.string as NSString).range(of: "2)").location + 1
        textView.setSelectedRange(NSRange(location: endOfExpr, length: 0))
        textView.insertText(")", replacementRange: NSRange(location: endOfExpr, length: 1))

        let matchBefore = textView.bracketMatch
        let flashBefore = textView.flashingBracketRange
        #expect(matchBefore != nil && flashBefore != nil)

        await editor.rehighlight()
        #expect(textView.bracketMatch == matchBefore)
        #expect(textView.flashingBracketRange == flashBefore)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func rendersSteadyAndFlashingBracketHighlightsInLightAndDarkMode(appearanceName: NSAppearance.Name) throws {
        let (editor, _) = try makeEditor(text: "foo(x")
        let textView = try editorTextView(of: editor)
        textView.appearance = NSAppearance(named: appearanceName)
        textView.viewDidChangeEffectiveAppearance()
        editor.highlightState.flashDuration = .seconds(10)

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(")", replacementRange: NSRange(location: 5, length: 0))

        let openerRect = try #require(textView.bracketHighlightRect(forOffset: 3))
        let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: bitmap)
        #expect(openerRect.width > 0 && openerRect.height > 0)
        #expect(textView.flashingBracketRange == NSRange(location: 3, length: 1))

        editor.cancelBracketFlash()
        textView.cacheDisplay(in: textView.bounds, to: bitmap)
        #expect(textView.flashingBracketRange == nil)
        #expect(textView.bracketMatch == .init(anchorOffset: 5, matchOffset: 3))
    }
}
