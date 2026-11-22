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
