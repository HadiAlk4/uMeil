import AppKit
import Testing
@testable import uMeil

struct LineMessageTests {
    private let file = URL(filePath: "/p/main.c")

    private func diagnostic(
        _ severity: Diagnostic.Severity,
        _ message: String,
        line: Int,
        file: URL? = nil
    ) -> Diagnostic {
        Diagnostic(severity: severity, message: message, file: file ?? self.file, line: line, column: 1)
    }

    @Test func keepsTheMostSeriousMessageOnEachLineAndCountsTheRest() {
        let messages = BuildSummary.lineMessages(for: file, in: [
            diagnostic(.warning, "unused variable 'x'", line: 4),
            diagnostic(.error, "'y' undeclared", line: 4),
            diagnostic(.warning, "implicit declaration", line: 9)
        ])

        #expect(messages[4] == .init(severity: .error, text: "'y' undeclared", moreCount: 1))
        #expect(messages[9] == .init(severity: .warning, text: "implicit declaration"))
    }

    @Test func leavesOutNotesAndOtherFiles() {
        let messages = BuildSummary.lineMessages(for: file, in: [
            diagnostic(.note, "declared here", line: 2),
            diagnostic(.error, "elsewhere", line: 3, file: URL(filePath: "/p/uart.c")),
            Diagnostic(severity: .error, message: "linker", file: nil, line: nil, column: nil)
        ])

        #expect(messages.isEmpty)
    }

    @Test func saysHowManyMoreThereAre() {
        let text = EditorTextView.inlineText(for: .init(severity: .error, text: "bad", moreCount: 2))

        #expect(text == "bad  (+2 more)")
    }
}

@MainActor
struct InlineMessagesInEditorTests {
    private func makeEditor(text: String) throws -> (EditorViewController, TemporaryDirectory) {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data(text.utf8).write(to: file)
        let editor = EditorViewController()
        try editor.open(file)
        return (editor, temp)
    }

    private func inlineMessages(of editor: EditorViewController) -> [EditorTextView.InlineMessage] {
        (editor.textView as? EditorTextView)?.inlineMessages ?? []
    }

    @Test func placesEachMessageAtTheStartOfItsLine() throws {
        let (editor, _) = try makeEditor(text: "int a;\nint b;\n")

        editor.setBuildMessages([2: .init(severity: .error, text: "oops")])

        #expect(inlineMessages(of: editor) == [.init(lineStart: 7, message: .init(severity: .error, text: "oops"))])
    }

    @Test func aMessageFollowsItsLineWhileTypingAboveIt() throws {
        let (editor, _) = try makeEditor(text: "int a;\nint b;\n")
        editor.setMarkers([2: .error])
        editor.setBuildMessages([2: .init(severity: .error, text: "oops")])

        editor.textView.insertText("unsigned ", replacementRange: NSRange(location: 0, length: 0))

        #expect(inlineMessages(of: editor).first?.lineStart == 16)
    }

    @Test func addingALineClearsTheMessagesAsItDoesTheMarkers() throws {
        let (editor, _) = try makeEditor(text: "int a;\nint b;\n")
        editor.setMarkers([2: .error])
        editor.setBuildMessages([2: .init(severity: .error, text: "oops")])

        editor.textView.insertText("\n", replacementRange: NSRange(location: 0, length: 0))

        #expect(inlineMessages(of: editor).isEmpty)
    }

    @Test func openingAnotherFileClearsTheMessages() throws {
        let (editor, temp) = try makeEditor(text: "int a;\n")
        editor.setBuildMessages([1: .init(severity: .warning, text: "hm")])
        let other = temp.url.appending(path: "other.c")
        try Data("int b;\n".utf8).write(to: other)

        try editor.open(other)

        #expect(inlineMessages(of: editor).isEmpty)
    }

    @Test func drawsWithoutTrouble() throws {
        let (editor, _) = try makeEditor(text: "int a;\nint b;\n")
        editor.view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        editor.view.layoutSubtreeIfNeeded()
        let long = "a very long message " + String(repeating: "x", count: 300)
        editor.setBuildMessages([1: .init(severity: .error, text: long)])

        let image = editor.textView.bitmapImageRepForCachingDisplay(in: editor.textView.bounds)
        #expect(image != nil)
        if let image {
            editor.textView.cacheDisplay(in: editor.textView.bounds, to: image)
        }
    }
}

/// With the real compiler.
@MainActor
@Suite(.enabled(if: BuildTestEnvironment.canBuild))
struct InlineMessagesAfterBuildTests {
    @Test func aFailedBuildWritesItsMessagesBesideTheCode() async throws {
        let folder = try TemporaryFolder()
        let defaults = TestDefaults()
        let controller = MainWindowController(defaults: defaults)
        try controller.createProject(named: "Blinky", in: folder.url)
        let textView = controller.editor.textView
        let everything = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText("int main(void) {\n    return missing_variable;\n}\n", replacementRange: everything)

        _ = await controller.build()

        let messages = (textView as? EditorTextView)?.inlineMessages ?? []
        #expect(messages.map(\.lineStart) == [17])
        #expect(messages.first?.message.severity == .error)
        #expect(messages.first?.message.text.contains("missing_variable") == true)
    }
}
