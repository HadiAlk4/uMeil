import AppKit
import Testing
@testable import uMeil

/// An editor showing some text in a file, inside a window so it has an
/// undo manager. Keeps the window and the file alive while a test runs.
@MainActor
final class TypingFixture {
    let editor: EditorViewController
    let window: NSWindow
    private let folder: TemporaryDirectory

    /// Shows `marked` (see `MarkedText`), with its selection, in `fileName`.
    init(_ marked: String, fileName: String = "main.c", style: IndentStyle = .fourSpaces) throws {
        let start = MarkedText(marked)
        folder = try TemporaryDirectory()
        let url = folder.url.appending(path: fileName)
        try Data(start.text.utf8).write(to: url)
        editor = EditorViewController()
        window = NSWindow(contentViewController: editor)
        try editor.open(url)
        textView.indentStyleOverride = style
        textView.setSelectedRange(start.selection)
    }

    var textView: EditorTextView {
        // swiftlint:disable:next force_cast
        editor.textView as! EditorTextView
    }

    /// The text with the selection marked, as `MarkedText` writes it.
    var shown: String {
        MarkedText(text: textView.string, selection: textView.selectedRange()).description
    }

    /// Types `characters` one at a time, as the keyboard would.
    func type(_ characters: String) {
        for character in characters {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }
}

/// The typing aids through the real editor: keys go to the text view the
/// way AppKit sends them, and edits can be undone.
@MainActor
struct TypingAidsTests {
    // MARK: - Tab and Backspace

    @Test func tabInsertsSpacesAndBackspaceTakesThemBack() throws {
        let fixture = try TypingFixture("int x;\n‸\n")
        fixture.textView.insertTab(nil)
        #expect(fixture.shown == "int x;\n    ‸\n")
        fixture.textView.deleteBackward(nil)
        #expect(fixture.shown == "int x;\n‸\n")
    }

    @Test func tabInsertsATabWhenTabsAreChosen() throws {
        let fixture = try TypingFixture("‸x", style: .tabs)
        fixture.textView.insertTab(nil)
        #expect(fixture.shown == "\t‸x")
    }

    @Test func anIndentCanBeUndone() throws {
        let fixture = try TypingFixture("‸x")
        fixture.textView.insertTab(nil)
        fixture.textView.undoManager?.undo()
        #expect(fixture.textView.string == "x")
    }
}

// MARK: - Return and closing braces

@MainActor
struct AutoIndentTypingTests {
    @Test func typingABlockIndentsItsBody() throws {
        let fixture = try TypingFixture("int main(void) ‸\n")
        fixture.type("{")
        fixture.textView.insertNewline(nil)
        fixture.type("x = 1;")
        fixture.textView.insertNewline(nil)
        fixture.type("}")
        #expect(fixture.shown == "int main(void) {\n    x = 1;\n}‸\n")
    }

    @Test func textPutInByCodeIsNotTreatedAsTyping() throws {
        // Code that puts text in with a replacement range, like an accepted
        // completion, is not treated as typing.
        let fixture = try TypingFixture("‸")
        fixture.textView.insertText("}", replacementRange: NSRange(location: 0, length: 0))
        #expect(fixture.textView.string == "}")
    }
}

// MARK: - Shifting lines

@MainActor
struct ShiftLinesTypingTests {
    @Test func tabAndShiftTabShiftSelectedLines() throws {
        let fixture = try TypingFixture("«a();\nb();»\n")
        fixture.textView.insertTab(nil)
        #expect(fixture.shown == "«    a();\n    b();»\n")
        fixture.textView.insertBacktab(nil)
        #expect(fixture.shown == "«a();\nb();»\n")
    }

    @Test func theMenuCommandsShiftTheCursorsLine() throws {
        let fixture = try TypingFixture("a‸();\n")
        fixture.textView.shiftRight(nil)
        #expect(fixture.shown == "    a‸();\n")
        fixture.textView.shiftLeft(nil)
        #expect(fixture.shown == "a‸();\n")
    }
}

// MARK: - Commenting lines

@MainActor
struct LineCommentTypingTests {
    @Test func commandSlashCommentsAndUncommentsInACFile() throws {
        let fixture = try TypingFixture("«a();\nb();»\n")
        fixture.textView.toggleComment(nil)
        #expect(fixture.shown == "«// a();\n// b();»\n")
        fixture.textView.toggleComment(nil)
        #expect(fixture.shown == "«a();\nb();»\n")
    }

    @Test func filesWithoutLineCommentsCannotBeCommented() throws {
        let fixture = try TypingFixture("‸SECTIONS {}\n", fileName: "tm4c1294ncpdt.ld")
        let item = NSMenuItem(
            title: "Comment Selection",
            action: #selector(EditorTextView.toggleComment(_:)),
            keyEquivalent: ""
        )
        #expect(!fixture.textView.validateUserInterfaceItem(item))
        fixture.textView.toggleComment(nil)
        #expect(fixture.textView.string == "SECTIONS {}\n")
    }
}
