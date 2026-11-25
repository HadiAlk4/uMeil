import AppKit
import Testing
@testable import uMeil

struct CSyntaxHighlighterTests {
    private let source = """
    #include <stdint.h>
    #include "driverlib/gpio.h"

    #define LED_PIN GPIO_PIN_0

    // Blink the LED 😀
    static uint32_t counter = 0x10;

    int main(void) {
        const char *name = "tiva";
        GPIOPinWrite(GPIO_PORTN_BASE, LED_PIN, 1);
        counter = counter + 1;
        return 0; /* done */
    }
    """

    /// The kind given to the first occurrence of `snippet`, or `nil` if no
    /// token covers exactly that text.
    private func kind(of snippet: String, in tokens: [HighlightToken]) -> HighlightKind? {
        let range = (source as NSString).range(of: snippet)
        precondition(range.location != NSNotFound, "\(snippet) is not in the test source")
        return tokens.first { $0.range == range }?.kind
    }

    @Test func classifiesEachKindOfCode() async throws {
        let tokens = try await CSyntaxHighlighter().tokens(in: source)

        #expect(kind(of: "#include", in: tokens) == .preprocessor)
        #expect(kind(of: "<stdint.h>", in: tokens) == .string)
        #expect(kind(of: "\"driverlib/gpio.h\"", in: tokens) == .string)
        #expect(kind(of: "#define", in: tokens) == .preprocessor)
        #expect(kind(of: "// Blink the LED 😀", in: tokens) == .comment)
        #expect(kind(of: "static", in: tokens) == .keyword)
        #expect(kind(of: "uint32_t", in: tokens) == .type)
        #expect(kind(of: "0x10", in: tokens) == .number)
        #expect(kind(of: "void", in: tokens) == .type)
        #expect(kind(of: "main", in: tokens) == .function)
        #expect(kind(of: "const", in: tokens) == .keyword)
        #expect(kind(of: "char", in: tokens) == .type)
        #expect(kind(of: "\"tiva\"", in: tokens) == .string)
        #expect(kind(of: "GPIOPinWrite", in: tokens) == .function)
        #expect(kind(of: "GPIO_PORTN_BASE", in: tokens) == .constant)
        #expect(kind(of: "return", in: tokens) == .keyword)
        #expect(kind(of: "/* done */", in: tokens) == .comment)
    }

    @Test func leavesOrdinaryVariablesUncolored() async throws {
        let tokens = try await CSyntaxHighlighter().tokens(in: source)

        #expect(kind(of: "counter", in: tokens) == nil)
        #expect(kind(of: "name", in: tokens) == nil)
    }

    @Test func rangesStayCorrectAfterNonASCIIText() async throws {
        // The emoji in the comment is two UTF-16 units; a parser working in
        // bytes or characters would put every later token in the wrong place.
        let tokens = try await CSyntaxHighlighter().tokens(in: source)
        let returnRange = (source as NSString).range(of: "return")

        #expect(tokens.contains(HighlightToken(range: returnRange, kind: .keyword)))
    }

    @Test func tokensAreSortedAndInsideTheText() async throws {
        let tokens = try await CSyntaxHighlighter().tokens(in: source)
        let length = (source as NSString).length

        #expect(!tokens.isEmpty)
        #expect(tokens.map(\.range.location) == tokens.map(\.range.location).sorted())
        #expect(tokens.allSatisfy { $0.range.length > 0 && NSMaxRange($0.range) <= length })
    }

    @Test func copesWithEmptyAndBrokenCode() async throws {
        let highlighter = try CSyntaxHighlighter()

        #expect(await highlighter.tokens(in: "").isEmpty)
        // Unfinished code is the normal state while typing; it must still
        // highlight what it can rather than give up.
        let broken = await highlighter.tokens(in: "int main(void) { return")
        #expect(broken.contains { $0.kind == .keyword })
        #expect(broken.contains { $0.kind == .type })
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func highlightsATenThousandLineFile() async throws {
        let line = "    GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_0, 1); // on\n"
        let text = "void run(void) {\n" + String(repeating: line, count: 10_000) + "}\n"

        let tokens = try await CSyntaxHighlighter().tokens(in: text)

        // Per line: one function, two constants, one number, one comment.
        #expect(tokens.filter { $0.kind == .comment }.count == 10_000)
        #expect(tokens.filter { $0.kind == .constant }.count == 20_000)
    }
}

struct HighlightMapTests {
    private func token(_ location: Int, _ length: Int, _ kind: HighlightKind = .keyword) -> HighlightToken {
        HighlightToken(range: NSRange(location: location, length: length), kind: kind)
    }

    @Test func findsOnlyTheTokensThatOverlapARange() {
        let map = HighlightMap(tokens: [token(0, 3), token(5, 3), token(10, 3), token(20, 3)])

        #expect(map.tokens(intersecting: NSRange(location: 6, length: 6)) == [token(5, 3), token(10, 3)])
        #expect(map.tokens(intersecting: NSRange(location: 13, length: 7)).isEmpty) // the gap, ends touching
        #expect(map.tokens(intersecting: NSRange(location: 0, length: 100)).count == 4)
        #expect(map.tokens(intersecting: NSRange(location: 50, length: 10)).isEmpty)
    }

    @Test func findsALongTokenThatStartedFarEarlier() {
        // A block comment covering 0..<1000, with small tokens after it began.
        let comment = token(0, 1000, .comment)
        let map = HighlightMap(tokens: [comment, token(1200, 5), token(1300, 5)])

        #expect(map.tokens(intersecting: NSRange(location: 900, length: 50)) == [comment])
        #expect(map.tokens(intersecting: NSRange(location: 990, length: 300)) == [comment, token(1200, 5)])
    }

    @Test func findsNestedTokensInOrder() {
        let outer = token(10, 20, .string)
        let inner = token(15, 2, .constant)
        let map = HighlightMap(tokens: [outer, inner])

        #expect(map.tokens(intersecting: NSRange(location: 14, length: 4)) == [outer, inner])
    }

    @Test func anEmptyMapFindsNothing() {
        #expect(HighlightMap.empty.tokens(intersecting: NSRange(location: 0, length: 10)).isEmpty)
    }
}

struct SourceLanguageTests {
    @Test func recognizesCFilesByExtension() {
        #expect(SourceLanguage(url: URL(filePath: "/p/main.c")) == .c)
        #expect(SourceLanguage(url: URL(filePath: "/p/gpio.h")) == .c)
        #expect(SourceLanguage(url: URL(filePath: "/p/MAIN.C")) == .c)
        #expect(SourceLanguage(url: URL(filePath: "/p/README.md")) == nil)
        #expect(SourceLanguage(url: URL(filePath: "/p/Makefile")) == nil)
    }
}

/// Highlighting as it reaches the screen, through the real editor.
@MainActor
struct EditorHighlightingTests {
    private func makeEditor(showing name: String, text: String) throws -> (MainWindowController, TemporaryDirectory) {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: name)
        try Data(text.utf8).write(to: url)

        let defaults = TestDefaults()
        let controller = MainWindowController(defaults: defaults)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 500), display: false)
        controller.openFolder(temp.url)
        controller.openFile(url)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return (controller, temp)
    }

    /// The highlight color drawn at the first occurrence of `snippet`.
    private func color(at snippet: String, in textView: NSTextView) -> NSColor? {
        let location = (textView.string as NSString).range(of: snippet).location
        let attributes = textView.layoutManager?.temporaryAttributes(atCharacterIndex: location, effectiveRange: nil)
        return attributes?[.foregroundColor] as? NSColor
    }

    @Test func colorsCCodeInTheEditor() async throws {
        let code = "int main(void) {\n    return 0; // done\n}\n"
        let (controller, temp) = try makeEditor(showing: "main.c", text: code)
        defer { _ = temp }
        let editor = controller.editor

        await editor.rehighlight()

        #expect(color(at: "int", in: editor.textView) == EditorTheme.color(for: .type))
        #expect(color(at: "main", in: editor.textView) == EditorTheme.color(for: .function))
        #expect(color(at: "return", in: editor.textView) == EditorTheme.color(for: .keyword))
        #expect(color(at: "// done", in: editor.textView) == EditorTheme.color(for: .comment))
        #expect(color(at: "{", in: editor.textView) == nil)
    }

    @Test func leavesOtherFilesAsPlainText() async throws {
        let (controller, temp) = try makeEditor(showing: "notes.txt", text: "int main(void) { return 0; }\n")
        defer { _ = temp }

        await controller.editor.rehighlight()

        #expect(color(at: "return", in: controller.editor.textView) == nil)
    }

    @Test func highlightingDoesNotMarkTheFileModifiedOrChangeItsText() async throws {
        let text = "int x = 1;\n"
        let (controller, temp) = try makeEditor(showing: "main.c", text: text)
        defer { _ = temp }

        await controller.editor.rehighlight()

        #expect(!controller.editor.isModified)
        #expect(controller.editor.textView.string == text)
        #expect(controller.editor.textView.undoManager?.canUndo == false)
    }

    @Test func recolorsAfterAnEdit() async throws {
        let (controller, temp) = try makeEditor(showing: "main.c", text: "int x;\n")
        defer { _ = temp }
        let editor = controller.editor
        await editor.rehighlight()

        editor.textView.insertText("static ", replacementRange: NSRange(location: 0, length: 0))
        await editor.rehighlight()

        #expect(color(at: "static", in: editor.textView) == EditorTheme.color(for: .keyword))
        #expect(color(at: "int", in: editor.textView) == EditorTheme.color(for: .type))
    }
}
