import AppKit
import Testing
@testable import uMeil

struct ClangFormatterTests {
    @Test func findsTheSmallestReplacement() throws {
        let change = try #require(ClangFormatter.replacement(from: "a(  x );\nb;\n", to: "a(x);\nb;\n"))
        #expect(change.range == NSRange(location: 2, length: 4))
        #expect(change.text == "x")
        #expect(ClangFormatter.replacement(from: "same", to: "same") == nil)

        let grown = try #require(ClangFormatter.replacement(from: "ab", to: "a b"))
        #expect(grown.range == NSRange(location: 1, length: 0) && grown.text == " ")
    }

    @Test func usesTheProjectsClangFormatFileWhenThereIsOne() throws {
        let temp = try TemporaryDirectory()
        let source = try temp.directory("src").appending(path: "main.c")
        #expect(ClangFormatter.style(for: source) == ClangFormatter.defaultStyle)

        let config = temp.url.appending(path: ".clang-format")
        try Data("BasedOnStyle: GNU\n".utf8).write(to: config)
        let style = ClangFormatter.style(for: source)
        #expect(style.hasPrefix("file:") && style.hasSuffix("/.clang-format"))
    }
}

@MainActor
@Suite(.enabled(if: ClangFormatter.locate(near: ToolLocator.standard().locate(.clangd)) != nil))
struct FormatSelectionInEditorTests {
    private struct Fixture {
        let editor: EditorViewController
        let folder: TemporaryDirectory
        /// Supplies the undo manager.
        let window: NSWindow
    }

    private func makeEditor(_ text: String) throws -> Fixture {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data(text.utf8).write(to: file)
        let editor = EditorViewController()
        let window = NSWindow(contentViewController: editor)
        try editor.open(file)
        let executable = try #require(ClangFormatter.locate(near: ToolLocator.standard().locate(.clangd)))
        editor.intelligence.onFormatRequested = { url, text, lines in
            try await ClangFormatter(executable: executable).format(text, of: url, lines: lines)
        }
        return Fixture(editor: editor, folder: temp, window: window)
    }

    @Test func formatsOnlyTheSelectedLinesInOneUndo() async throws {
        let messy = "int main(void)\n{\n  int a=1;\n    int b = 2;\n    return a+b;\n}\n"
        let fixture = try makeEditor(messy)
        let editor = fixture.editor
        let lineThree = (messy as NSString).range(of: "  int a=1;\n")
        editor.textView.setSelectedRange(lineThree)

        #expect(await editor.performFormatSelection())
        // Line 5 is outside the selection, so it keeps its spacing.
        #expect(editor.textView.string == "int main(void)\n{\n    int a = 1;\n    int b = 2;\n    return a+b;\n}\n")
        #expect((editor.textView.string as NSString).substring(with: editor.textView.selectedRange())
            == "    int a = 1;\n")

        editor.textView.undoManager?.undo()
        #expect(editor.textView.string == messy)
        withExtendedLifetime(fixture) {}
    }

    @Test func leavesBlinkyAsItIs() async throws {
        let blinky = try String(
            contentsOf: try #require(Bundle(for: EditorViewController.self)
                .url(forResource: "Templates.bundle/Blinky/files/src/main", withExtension: "c")),
            encoding: .utf8
        )
        let fixture = try makeEditor(blinky)
        let editor = fixture.editor
        editor.textView.selectAll(nil)
        #expect(await editor.performFormatSelection())
        #expect(editor.textView.string == blinky)
        #expect(!editor.isModified)
        withExtendedLifetime(fixture) {}
    }
}
