import AppKit
import Testing
@testable import uMeil

@MainActor
struct DiagnosticQuickFixTests {
    @Test func appliesMultipleEditsInReverseDocumentOrderAndUndoesInOneStep() throws {
        let original = "int main(void) {\n    int count = 0\n    return cont;\n}\n"
        let fixture = try makeFixture(text: original)
        let action = quickFixAction(
            title: "Add header, fix typo, insert ';'",
            url: fixture.file,
            edits: [
                LSPTextEdit(
                    range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
                    newText: "#include <stdio.h>\n"
                ),
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 1, character: 17),
                        end: LSPPosition(line: 1, character: 17)
                    ),
                    newText: ";"
                ),
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 2, character: 11),
                        end: LSPPosition(line: 2, character: 15)
                    ),
                    newText: "count"
                )
            ]
        )

        #expect(fixture.editor.applyQuickFix(action))
        let fixed = "#include <stdio.h>\nint main(void) {\n    int count = 0;\n    return count;\n}\n"
        #expect(fixture.editor.textView.string == fixed)
        #expect(fixture.editor.isModified)

        let undoManager = try #require(fixture.editor.textView.undoManager)
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Fix: Add header, fix typo, insert ';'")

        undoManager.undo()
        #expect(fixture.editor.textView.string == original)

        undoManager.redo()
        #expect(fixture.editor.textView.string == fixed)
    }

    @Test func preservesArrayOrderForSamePositionInsertionsAndRejectsOverlappingEdits() throws {
        let fixture = try makeFixture(text: "int main(void) { return 0; }\n")
        let origin = LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))
        let orderedInsert = quickFixAction(
            title: "Include headers",
            url: fixture.file,
            edits: [
                LSPTextEdit(range: origin, newText: "#include <stdbool.h>\n"),
                LSPTextEdit(range: origin, newText: "#include <stdint.h>\n")
            ]
        )

        #expect(fixture.editor.applyQuickFix(orderedInsert))
        #expect(
            fixture.editor.textView.string
                == "#include <stdbool.h>\n#include <stdint.h>\nint main(void) { return 0; }\n"
        )

        let overlapping = quickFixAction(
            title: "Bad overlap",
            url: fixture.file,
            edits: [
                LSPTextEdit(
                    range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 6)),
                    newText: "A"
                ),
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 0, character: 4),
                        end: LSPPosition(line: 0, character: 10)
                    ),
                    newText: "B"
                )
            ]
        )
        let beforeOverlap = fixture.editor.textView.string
        #expect(!fixture.editor.applyQuickFix(overlapping))
        #expect(fixture.editor.textView.string == beforeOverlap)
    }

    @Test func refusesToApplyEditsTargetingAnotherFile() throws {
        let original = "int main(void) { return 0; }\n"
        let fixture = try makeFixture(text: original)
        let other = fixture.temp.url.appending(path: "other.c")
        try Data("int other = 1;\n".utf8).write(to: other)

        let foreignEdit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
            newText: "// poisoned\n"
        )
        let foreignOnly = quickFixAction(title: "Touch other file", url: other, edits: [foreignEdit])
        let mixed = LSPCodeAction(
            title: "Touch both files",
            kind: LSPCodeAction.quickFixKind,
            isPreferred: true,
            edit: LSPCodeActionEdit(changes: [
                fixture.file.standardizedFileURL.absoluteString: [foreignEdit],
                other.standardizedFileURL.absoluteString: [foreignEdit]
            ])
        )

        #expect(!fixture.editor.applyQuickFix(foreignOnly))
        #expect(!fixture.editor.applyQuickFix(mixed))
        #expect(fixture.editor.textView.string == original)
        #expect(!fixture.editor.isModified)
    }

    @Test func diagnosticBarFixButtonAppliesQuickFixWithoutTriggeringBarClick() async throws {
        let original = "int main(void) {\n    printf(\"hi\\n\");\n    return 0;\n}\n"
        let fixture = try makeFixture(text: original)
        let diagRange = LSPRange(start: LSPPosition(line: 1, character: 4), end: LSPPosition(line: 1, character: 10))
        let diagnostic = LSPDiagnostic(
            range: diagRange,
            severity: .error,
            code: "-Wimplicit-function-declaration",
            source: "clang",
            message: "Call to undeclared library function 'printf'"
        )
        let fix = includeStdioAction(for: fixture.file)

        var barClickCount = 0
        fixture.editor.diagnosticBar.onClick = { _ in barClickCount += 1 }
        fixture.editor.intelligence.onCodeActionsRequested = { _, _, _, _ in [fix] }

        let printfOffset = (original as NSString).range(of: "printf").location
        fixture.editor.textView.setSelectedRange(NSRange(location: printfOffset, length: 0))

        fixture.editor.applyLiveDiagnostics([diagnostic])
        let shown = await eventually { !fixture.editor.diagnosticBar.fixButton.isHidden }
        #expect(shown)
        #expect(fixture.editor.diagnosticBar.fixButton.title == "Fix: Include <stdio.h>")
        #expect(fixture.editor.diagnosticBar.fixButton.toolTip == "Fix: Include <stdio.h> for symbol printf")

        fixture.editor.diagnosticBar.fixButton.performClick(nil)
        #expect(barClickCount == 0)
        #expect(fixture.editor.textView.string == "#include <stdio.h>\n" + original)
        #expect(fixture.editor.textView.selectedRange().location == printfOffset + "#include <stdio.h>\n".utf16.count)
        #expect(fixture.editor.diagnosticBar.isHidden)
    }

    @Test func diagnosticBarClickGestureIgnoresClicksOnFixButton() throws {
        let fixture = try makeFixture(text: "int main(void) {\n    printf(\"hi\\n\");\n}\n")
        let bar = fixture.editor.diagnosticBar
        let diag = LSPDiagnostic(
            range: LSPRange(start: LSPPosition(line: 1, character: 4), end: LSPPosition(line: 1, character: 10)),
            severity: .error,
            message: "undeclared 'printf'"
        )
        bar.update(diagnostics: [diag], cursorLineZeroBased: 1, quickFix: includeStdioAction(for: fixture.file))
        fixture.editor.view.layoutSubtreeIfNeeded()

        let gesture = try #require(bar.gestureRecognizers.first)
        let buttonPoint = bar.fixButton.convert(
            NSPoint(x: bar.fixButton.bounds.midX, y: bar.fixButton.bounds.midY),
            to: nil
        )
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: buttonPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        #expect(!bar.gestureRecognizer(gesture, shouldAttemptToRecognizeWith: event))
    }

    @Test func clickingInlineQuickFixCapsuleAppliesFixInOneClickAndDrawsCleanly() async throws {
        let original = "int main(void) {\n    printf(\"hi\\n\");\n    return 0;\n}\n"
        let fixture = try makeFixture(text: original)
        let textView = try #require(fixture.editor.textView as? EditorTextView)
        let diagRange = LSPRange(start: LSPPosition(line: 1, character: 4), end: LSPPosition(line: 1, character: 10))
        let diagnostic = LSPDiagnostic(
            range: diagRange,
            severity: .error,
            message: "Call to undeclared library function 'printf'"
        )
        fixture.editor.intelligence.onCodeActionsRequested = { _, _, _, _ in [includeStdioAction(for: fixture.file)] }

        fixture.editor.setBuildMessages([2: .init(severity: .error, text: "undeclared 'printf'")])
        fixture.editor.applyLiveDiagnostics([diagnostic])
        let ready = await eventually { !textView.inlineQuickFixes.isEmpty }
        #expect(ready)

        let item = try #require(textView.inlineQuickFixes.first)
        let capsule = try #require(textView.quickFixCapsuleRect(for: item))

        let image = textView.bitmapImageRepForCachingDisplay(in: textView.bounds)
        #expect(image != nil)
        if let image {
            textView.cacheDisplay(in: textView.bounds, to: image)
        }

        // Clicking outside the capsule does not apply the fix.
        #expect(!textView.handleQuickFixClick(at: NSPoint(x: 4, y: capsule.midY)))
        #expect(fixture.editor.textView.string == original)

        // Clicking inside the capsule applies the fix in one click.
        #expect(textView.handleQuickFixClick(at: NSPoint(x: capsule.midX, y: capsule.midY)))
        #expect(fixture.editor.textView.string == "#include <stdio.h>\n" + original)
        #expect(textView.inlineQuickFixes.isEmpty)
    }

    @Test func dropsStaleAsyncQuickFixWhenTextChangesBeforeResponseArrives() async throws {
        let original = "int main(void) {\n    printf(\"hi\\n\");\n}\n"
        let fixture = try makeFixture(text: original)
        let diagRange = LSPRange(start: LSPPosition(line: 1, character: 4), end: LSPPosition(line: 1, character: 10))
        let diagnostic = LSPDiagnostic(range: diagRange, severity: .error, message: "undeclared 'printf'")
        let fix = includeStdioAction(for: fixture.file)

        fixture.editor.intelligence.onCodeActionsRequested = { _, _, _, _ in
            try? await Task.sleep(for: .milliseconds(80))
            return [fix]
        }

        fixture.editor.applyLiveDiagnostics([diagnostic])
        fixture.editor.textView.insertText(" ", replacementRange: NSRange(location: 0, length: 0))
        try? await Task.sleep(for: .milliseconds(150))

        #expect(fixture.editor.diagnosticBar.currentQuickFix == nil)
        #expect(fixture.editor.diagnosticBar.fixButton.isHidden)
        #expect((fixture.editor.textView as? EditorTextView)?.inlineQuickFixes.isEmpty == true)
    }

    @Test func formatsConciseButtonTitles() {
        let include = LSPCodeAction(title: "Include <stdio.h> for symbol printf", kind: "quickfix")
        #expect(DiagnosticQuickFix.buttonTitle(for: include) == "Fix: Include <stdio.h>")

        let longTitle = LSPCodeAction(title: String(repeating: "a", count: 50), kind: "quickfix")
        let formatted = DiagnosticQuickFix.buttonTitle(for: longTitle)
        #expect(formatted.hasPrefix("Fix: "))
        #expect(formatted.hasSuffix("…"))
        #expect(formatted.count <= 40)
    }
}

@MainActor
private extension DiagnosticQuickFixTests {
    struct Fixture {
        let window: NSWindow
        let editor: EditorViewController
        let file: URL
        let temp: TemporaryDirectory
    }

    func makeFixture(text: String) throws -> Fixture {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data(text.utf8).write(to: file)
        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = editor.view
        try editor.open(file)
        editor.view.layoutSubtreeIfNeeded()
        return Fixture(window: window, editor: editor, file: file, temp: temp)
    }

    func quickFixAction(
        title: String,
        url: URL,
        edits: [LSPTextEdit],
        isPreferred: Bool = true
    ) -> LSPCodeAction {
        LSPCodeAction(
            title: title,
            kind: LSPCodeAction.quickFixKind,
            isPreferred: isPreferred,
            edit: LSPCodeActionEdit(changes: [url.standardizedFileURL.absoluteString: edits])
        )
    }

    func includeStdioAction(for file: URL) -> LSPCodeAction {
        let origin = LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0))
        return quickFixAction(
            title: "Include <stdio.h> for symbol printf",
            url: file,
            edits: [LSPTextEdit(range: origin, newText: "#include <stdio.h>\n")]
        )
    }
}
