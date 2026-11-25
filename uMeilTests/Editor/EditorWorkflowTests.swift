import AppKit
import Testing
@testable import uMeil

/// Opening, editing, and saving through the real view controllers.
@MainActor
struct EditorWorkflowTests {
    /// A window controller whose "last folder" setting goes to a throwaway
    /// store, so tests never touch the real app's preferences.
    private func makeWindowController() throws -> (MainWindowController, UserDefaults) {
        let defaults = TestDefaults()
        return (MainWindowController(defaults: defaults), defaults)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Editor

    @Test func opensAFileUnmodified() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "main.c")
        try write("int main(void) {\n    return 0;\n}\n", to: url)
        let editor = EditorViewController()

        try editor.open(url)

        #expect(editor.textView.string == "int main(void) {\n    return 0;\n}\n")
        #expect(editor.document?.url == url)
        #expect(!editor.isModified)
        #expect(editor.textView.selectedRange() == NSRange(location: 0, length: 0))
    }

    @Test func typingMarksTheFileModifiedAndSavingClearsIt() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "main.c")
        try write("int x;\n", to: url)
        let editor = EditorViewController()
        var changes: [Bool] = []
        editor.onModifiedChanged = { changes.append($0) }
        try editor.open(url)

        editor.textView.insertText("// hello\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.isModified)
        #expect(try String(contentsOf: url, encoding: .utf8) == "int x;\n") // not saved yet

        try editor.save()
        #expect(!editor.isModified)
        #expect(try String(contentsOf: url, encoding: .utf8) == "// hello\nint x;\n")
        #expect(changes == [true, false])
    }

    @Test func undoIsAvailableAfterTypingButNotAcrossFiles() throws {
        let temp = try TemporaryDirectory()
        let first = temp.url.appending(path: "a.c")
        let second = temp.url.appending(path: "b.c")
        try write("a\n", to: first)
        try write("b\n", to: second)
        // The text view gets its undo manager from the window it is in.
        let (controller, _) = try makeWindowController()
        let editor = controller.editor
        controller.openFolder(temp.url)
        try editor.open(first)
        let undoManager = try #require(editor.textView.undoManager)

        editor.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(undoManager.canUndo)

        // Undo must not be able to put the first file's text into the second.
        try editor.open(second)
        #expect(!undoManager.canUndo)
        #expect(editor.textView.string == "b\n")
    }

    @Test func turnsOffTextFeaturesThatWouldCorruptCode() {
        let textView = EditorViewController().textView

        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isRichText)
        #expect(textView.usesFindBar)
        #expect(textView.allowsUndo)
    }

    @Test func aFileThatFailsToOpenLeavesTheCurrentOneInPlace() throws {
        let temp = try TemporaryDirectory()
        let source = temp.url.appending(path: "main.c")
        let binary = temp.url.appending(path: "main.bin")
        try write("int x;\n", to: source)
        try Data([0x00, 0x01, 0x02]).write(to: binary)
        let editor = EditorViewController()
        try editor.open(source)

        #expect(throws: TextDocumentError.notText) {
            try editor.open(binary)
        }
        #expect(editor.document?.url == source)
        #expect(editor.textView.string == "int x;\n")
    }

    // MARK: - Window

    @Test func openingAFolderFillsTheNavigatorAndRemembersIt() throws {
        let temp = try TemporaryDirectory()
        try write("", to: temp.url.appending(path: "src/main.c"))
        try write("", to: temp.url.appending(path: "README.md"))
        let (controller, defaults) = try makeWindowController()

        controller.openFolder(temp.url)

        #expect(controller.navigator.root?.children.map(\.name) == ["src", "README.md"])
        #expect(controller.navigator.outlineView.numberOfRows == 2)
        #expect(controller.window?.subtitle == temp.url.lastPathComponent)
        #expect(defaults.string(forKey: MainWindowController.lastFolderDefaultsKey)
            == temp.url.path(percentEncoded: false))
    }

    @Test func openingAFileShowsItAndSelectsItInTheNavigator() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "src/drivers/uart.c")
        try write("void uart_init(void);\n", to: file)
        let (controller, _) = try makeWindowController()
        controller.openFolder(temp.url)

        controller.openFile(file)

        let outline = controller.navigator.outlineView
        let selected = outline.item(atRow: outline.selectedRow) as? FileNode
        #expect(controller.editor.textView.string == "void uart_init(void);\n")
        #expect(selected?.name == "uart.c")
        #expect(controller.window?.title == "uart.c")
        #expect(controller.window?.isDocumentEdited == false)
    }

    @Test func theWindowShowsWhenTheFileHasUnsavedChanges() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try write("int x;\n", to: file)
        let (controller, _) = try makeWindowController()
        controller.openFolder(temp.url)
        controller.openFile(file)

        controller.editor.textView.insertText("y", replacementRange: NSRange(location: 0, length: 0))
        #expect(controller.window?.isDocumentEdited == true)

        controller.saveDocument(nil)
        #expect(controller.window?.isDocumentEdited == false)
        #expect(try String(contentsOf: file, encoding: .utf8) == "yint x;\n")
    }

    @Test func selectingAFileInTheNavigatorOpensIt() throws {
        let temp = try TemporaryDirectory()
        try write("first\n", to: temp.url.appending(path: "a.c"))
        try write("second\n", to: temp.url.appending(path: "b.c"))
        let (controller, _) = try makeWindowController()
        controller.openFolder(temp.url)

        // Row 1 is b.c; selecting it is what a click does.
        controller.navigator.outlineView.selectRowIndexes([1], byExtendingSelection: false)

        #expect(controller.editor.document?.url.lastPathComponent == "b.c")
        #expect(controller.editor.textView.string == "second\n")
    }

    @Test func saveIsOnlyOfferedWhenAFileIsOpen() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try write("int x;\n", to: file)
        let (controller, _) = try makeWindowController()
        let save = NSMenuItem(
            title: "Save",
            action: #selector(MainWindowController.saveDocument(_:)),
            keyEquivalent: "s"
        )

        #expect(!controller.validateMenuItem(save))

        controller.openFolder(temp.url)
        controller.openFile(file)
        #expect(controller.validateMenuItem(save))
    }
}
