import Foundation
import Testing
@testable import uMeil

@MainActor
struct RenameTests {
    private func edit(_ line: Int, _ start: Int, _ end: Int, _ text: String) -> LSPTextEdit {
        let range = LSPRange(
            start: LSPPosition(line: line, character: start),
            end: LSPPosition(line: line, character: end)
        )
        return LSPTextEdit(range: range, newText: text)
    }

    @Test func appliesEditsLastFirstSoRangesStayValid() {
        let text = "int count;\nvoid f(void) { count = count + 1; }\n"
        let edits = [edit(0, 4, 9, "ticks"), edit(1, 15, 20, "ticks"), edit(1, 23, 28, "ticks")]
        #expect(EditorViewController.applying(edits, to: text)
            == "int ticks;\nvoid f(void) { ticks = ticks + 1; }\n")
    }

    @Test func acceptsOnlyCIdentifiers() {
        #expect(CodeIntelligenceController.isValidCIdentifier("led_on"))
        #expect(CodeIntelligenceController.isValidCIdentifier("_LED2"))
        #expect(!CodeIntelligenceController.isValidCIdentifier("2led"))
        #expect(!CodeIntelligenceController.isValidCIdentifier("led on"))
        #expect(!CodeIntelligenceController.isValidCIdentifier(""))
        #expect(!CodeIntelligenceController.isValidCIdentifier("été"))
    }

    @Test func decodesBothShapesOfWorkspaceEdit() throws {
        let range = #"{"start":{"line":0,"character":0},"end":{"line":0,"character":3}}"#
        let changes = #"{"changes":{"file:///p/main.c":[{"range":\#(range),"newText":"x"}]}}"#
        let documents = #"{"documentChanges":[{"textDocument":{"uri":"file:///p/a.h","version":1},"#
            + #""edits":[{"range":\#(range),"newText":"y"}]}]}"#
        let decoder = JSONDecoder()

        let fromChanges = try decoder.decode(LSPWorkspaceEdit.self, from: Data(changes.utf8))
        #expect(fromChanges.edits[URL(filePath: "/p/main.c")]?.first?.newText == "x")
        let fromDocuments = try decoder.decode(LSPWorkspaceEdit.self, from: Data(documents.utf8))
        #expect(fromDocuments.edits[URL(filePath: "/p/a.h")]?.first?.newText == "y")
    }

    @Test func explainsEditsOutsideTheProject() {
        let message = RenameError.outsideProject(["gpio.h"]).localizedDescription
        #expect(message.contains("gpio.h"))
        #expect(message.contains("outside the project"))
    }
}
