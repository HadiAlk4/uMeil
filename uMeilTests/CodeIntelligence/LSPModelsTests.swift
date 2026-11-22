import AppKit
import Testing
@testable import uMeil

struct LSPModelsTests {
    @Test func convertsBetweenUTF16OffsetsAndLSPPositions() {
        // Line 1: "é😀\n" -> UTF-16 length 4 ("é" = 1, "😀" = 2, "\n" = 1)
        // Line 2: "int x;"
        let text = "é😀\nint x;"
        let index = LineIndex(text)

        #expect(index.lspPosition(atUTF16Offset: 0) == LSPPosition(line: 0, character: 0))
        #expect(index.lspPosition(atUTF16Offset: 3) == LSPPosition(line: 0, character: 3))
        #expect(index.lspPosition(atUTF16Offset: 4) == LSPPosition(line: 1, character: 0))
        #expect(index.lspPosition(atUTF16Offset: 8) == LSPPosition(line: 1, character: 4))

        #expect(index.utf16Offset(for: LSPPosition(line: 0, character: 3)) == 3)
        #expect(index.utf16Offset(for: LSPPosition(line: 1, character: 4)) == 8)
        // Clamps out-of-bounds positions safely.
        #expect(index.utf16Offset(for: LSPPosition(line: 99, character: 10)) == index.length)
        #expect(index.utf16Range(for: LSPRange(
            start: LSPPosition(line: 1, character: 4),
            end: LSPPosition(line: 1, character: 5)
        )) == NSRange(location: 8, length: 1))
    }

    @Test func decodesCompletionItemWithMarkupDocumentationAndLeadingSpace() throws {
        let json = """
        {
          "label": " GPIOPinWrite(uint32_t ui32Port, uint8_t ui8Pins, uint8_t ui8Val)",
          "kind": 3,
          "detail": "void",
          "documentation": { "kind": "markdown", "value": "From \\"driverlib/gpio.h\\"" },
          "insertText": "GPIOPinWrite",
          "filterText": "GPIOPinWrite",
          "textEdit": {
            "range": { "start": { "line": 10, "character": 4 }, "end": { "line": 10, "character": 11 } },
            "newText": "GPIOPinWrite"
          }
        }
        """
        let item = try JSONDecoder().decode(LSPCompletionItem.self, from: Data(json.utf8))

        #expect(item.kind == .function)
        #expect(item.displayLabel == "GPIOPinWrite(uint32_t ui32Port, uint8_t ui8Pins, uint8_t ui8Val)")
        #expect(item.insertionText == "GPIOPinWrite")
        #expect(item.documentation == "From \"driverlib/gpio.h\"")
        #expect(item.kind?.badge == "f")
    }

    @Test func summarizesDiagnosticsIntoLineMarkersWithErrorPriority() throws {
        let json = """
        {
          "uri": "file:///tmp/Blinky/src/main.c",
          "version": 3,
          "diagnostics": [
            {
              "range": { "start": { "line": 1, "character": 4 }, "end": { "line": 1, "character": 10 } },
              "severity": 2,
              "message": "unused variable"
            },
            {
              "range": { "start": { "line": 1, "character": 12 }, "end": { "line": 1, "character": 15 } },
              "severity": 1,
              "code": 101,
              "message": "undeclared identifier"
            },
            {
              "range": { "start": { "line": 4, "character": 0 }, "end": { "line": 4, "character": 4 } },
              "severity": 3,
              "message": "note"
            }
          ]
        }
        """
        let params = try JSONDecoder().decode(LSPPublishDiagnosticsParams.self, from: Data(json.utf8))

        #expect(params.url?.path == "/tmp/Blinky/src/main.c")
        #expect(params.diagnostics[1].code == "101")
        // 0-based line 1 -> 1-based line 2; error outranks warning; info/hint ignored in gutter.
        #expect(params.lineMarkers == [2: .error])
    }

    @Test func decodesCodeActionWithChanges() throws {
        let changesJSON = """
        {
          "title": "Include <stdio.h> for symbol printf",
          "kind": "quickfix",
          "isPreferred": true,
          "diagnostics": [
            {
              "range": { "start": { "line": 1, "character": 4 }, "end": { "line": 1, "character": 10 } },
              "severity": 1,
              "code": "-Wimplicit-function-declaration",
              "source": "clang",
              "message": "Call to undeclared library function 'printf'"
            }
          ],
          "edit": {
            "changes": {
              "file:///tmp/Blinky/src/main.c": [
                {
                  "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 0 } },
                  "newText": "#include <stdio.h>\\n"
                }
              ]
            }
          }
        }
        """
        let action = try JSONDecoder().decode(LSPCodeAction.self, from: Data(changesJSON.utf8))
        #expect(action.title == "Include <stdio.h> for symbol printf")
        #expect(action.isQuickFix)
        #expect(action.isPreferred == true)
        #expect(action.diagnostics?.count == 1)
        let targetURL = URL(filePath: "/tmp/Blinky/src/main.c")
        let edits = try #require(action.quickFixEdits(targeting: targetURL))
        #expect(edits == [
            LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
                newText: "#include <stdio.h>\n"
            )
        ])
    }

    @Test func decodesCodeActionWithDocumentChanges() throws {
        let docChangesJSON = """
        {
          "title": "Insert semicolon",
          "kind": "quickfix.clang",
          "edit": {
            "documentChanges": [
              {
                "textDocument": { "uri": "file:///tmp/Blinky/src/main.c", "version": 4 },
                "edits": [
                  {
                    "range": { "start": { "line": 2, "character": 12 }, "end": { "line": 2, "character": 12 } },
                    "newText": ";"
                  }
                ]
              }
            ]
          }
        }
        """
        let targetURL = URL(filePath: "/tmp/Blinky/src/main.c")
        let docAction = try JSONDecoder().decode(LSPCodeAction.self, from: Data(docChangesJSON.utf8))
        #expect(docAction.isQuickFix)
        let docEdits = try #require(docAction.quickFixEdits(targeting: targetURL))
        #expect(docEdits.map(\.newText) == [";"])
    }

    @Test func workspaceEditSecurityRejectsOtherFilesResourceOpsAndUnsafeURIs() throws {
        let temp = try TemporaryDirectory()
        let spaceDir = try temp.directory("My Project")
        let openFile = spaceDir.appending(path: "main.c")
        let otherFile = spaceDir.appending(path: "other.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: openFile)
        try Data("int other(void) { return 1; }\n".utf8).write(to: otherFile)

        let symlinkFile = temp.url.appending(path: "link-main.c")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: openFile)

        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
            newText: "#include <stdio.h>\n"
        )
        let openURI = openFile.standardizedFileURL.absoluteString
        let otherURI = otherFile.standardizedFileURL.absoluteString
        let symlinkURI = symlinkFile.standardizedFileURL.absoluteString

        // Symlink and percent-encoded spaces resolving to the open document are allowed.
        #expect(LSPWorkspaceEdit(changes: [symlinkURI: [edit]]).edits(targeting: openFile) == [edit])
        #expect(LSPWorkspaceEdit(changes: [openURI: [edit]]).edits(targeting: symlinkFile) == [edit])

        // Edits targeting another file, or mixing open + other file, are rejected completely.
        #expect(LSPWorkspaceEdit(changes: [otherURI: [edit]]).edits(targeting: openFile) == nil)
        #expect(LSPWorkspaceEdit(changes: [openURI: [edit], otherURI: [edit]]).edits(targeting: openFile) == nil)

        // Non-file URIs, remote file hosts, path traversal, and %00 are rejected.
        #expect(LSPWorkspaceEdit(changes: ["https://example.com/main.c": [edit]]).edits(targeting: openFile) == nil)
        #expect(LSPWorkspaceEdit(changes: ["file://evil.example\(openFile.path)": [edit]])
            .edits(targeting: openFile) == nil)
        #expect(LSPWorkspaceEdit(changes: ["file:///tmp/../etc/passwd": [edit]]).edits(targeting: openFile) == nil)
        #expect(LSPWorkspaceEdit(changes: ["\(openURI)%00": [edit]]).edits(targeting: openFile) == nil)

        // Resource operations (create/rename/delete) inside documentChanges are rejected.
        let createJSON = """
        {
          "documentChanges": [
            {
              "textDocument": { "uri": "\(openURI)", "version": 1 },
              "edits": [{
                "range": { "start": { "line": 0, "character": 0 }, "end": { "line": 0, "character": 0 } },
                "newText": ";"
              }]
            },
            { "kind": "create", "uri": "\(otherURI)" }
          ]
        }
        """
        let workspaceEdit = try JSONDecoder().decode(LSPWorkspaceEdit.self, from: Data(createJSON.utf8))
        #expect(workspaceEdit.edits(targeting: openFile) == nil)
    }

    @Test func preferredQuickFixSelectsPreferredEnabledQuickFixForTargetFile() {
        let target = URL(filePath: "/tmp/main.c")
        let other = URL(filePath: "/tmp/other.c")
        let edit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
            newText: "#include <stdio.h>\n"
        )
        let refactor = LSPCodeAction(
            title: "Extract function",
            kind: "refactor.extract",
            isPreferred: true,
            edit: LSPWorkspaceEdit(changes: [target.absoluteString: [edit]])
        )
        let foreignFix = LSPCodeAction(
            title: "Fix other file",
            kind: "quickfix",
            isPreferred: true,
            edit: LSPWorkspaceEdit(changes: [other.absoluteString: [edit]])
        )
        let disabledFix = LSPCodeAction(
            title: "Disabled fix",
            kind: "quickfix",
            isPreferred: true,
            disabled: .init(reason: "unavailable"),
            edit: LSPWorkspaceEdit(changes: [target.absoluteString: [edit]])
        )
        let secondaryFix = LSPCodeAction(
            title: "Insert declaration",
            kind: "quickfix",
            isPreferred: false,
            edit: LSPWorkspaceEdit(changes: [target.absoluteString: [edit]])
        )
        let preferredFix = LSPCodeAction(
            title: "Include <stdio.h>",
            kind: "quickfix",
            isPreferred: true,
            edit: LSPWorkspaceEdit(changes: [target.absoluteString: [edit]])
        )

        let picked = LSPCodeAction.preferredQuickFix(
            from: [refactor, foreignFix, disabledFix, secondaryFix, preferredFix],
            targeting: target
        )
        #expect(picked == preferredFix)

        let fallback = LSPCodeAction.preferredQuickFix(from: [refactor, secondaryFix], targeting: target)
        #expect(fallback == secondaryFix)
    }
}

@MainActor
struct LSPSignatureHelpTests {
    @Test func decodesOffsetLabelsAndFindsTheActiveArgument() throws {
        let json = """
        {"signatures":[{"label":"void GPIOPinWrite(uint32_t ui32Port, uint8_t ui8Pins, uint8_t ui8Val)",
          "documentation":{"kind":"plaintext","value":"Writes a value to the specified pin(s).\\nMore."},
          "parameters":[{"label":[18,35]},{"label":[37,52]},{"label":"uint8_t ui8Val"}]}],
         "activeSignature":0,"activeParameter":1}
        """
        let help = try JSONDecoder().decode(LSPSignatureHelp.self, from: Data(json.utf8))

        #expect(help.activeParameterName == "ui8Pins")
        let signature = try #require(help.active)
        #expect(signature.parameterName(at: 0) == "ui32Port")
        #expect(signature.parameterName(at: 2) == "ui8Val")
        #expect(signature.parameterRange(at: 3) == nil)

        let text = EditorViewController.signatureText(signature, activeParameter: 1)
        #expect(text.string == signature.label + "\nWrites a value to the specified pin(s).")
        let bold = text.attribute(.font, at: 40, effectiveRange: nil) as? NSFont
        #expect(bold?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }
}

@MainActor
struct LSPHoverTests {
    @Test func decodesEveryShapeOfHoverContents() throws {
        let markup = #"{"contents":{"kind":"plaintext","value":"macro GPIO_PIN_1"}}"#
        let marked = #"{"contents":[{"language":"c","value":"int x"},"plain"]}"#
        let plain = #"{"contents":"just text"}"#
        let decoder = JSONDecoder()
        #expect(try decoder.decode(LSPHover.self, from: Data(markup.utf8)).contents == "macro GPIO_PIN_1")
        #expect(try decoder.decode(LSPHover.self, from: Data(marked.utf8)).contents == "int x\n\nplain")
        #expect(try decoder.decode(LSPHover.self, from: Data(plain.utf8)).contents == "just text")
    }

    @Test func tidiesClangdHoverText() {
        let raw = "macro GPIO_PIN_1\n\n\nprovided by \"driverlib/gpio.h\"\n\n---\n#define GPIO_PIN_1 0x00000002\n\n"
        #expect(EditorViewController.hoverText(raw)
            == "macro GPIO_PIN_1\n\nprovided by \"driverlib/gpio.h\"\n\n#define GPIO_PIN_1 0x00000002")
    }
}
