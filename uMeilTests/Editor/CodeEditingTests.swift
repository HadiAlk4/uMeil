import Foundation
import Testing
@testable import uMeil

/// Text with the selection marked in it: `‸` for the cursor, or `«` and `»`
/// around selected text. Lets the editing tests read like the editor looks.
struct MarkedText: Equatable, CustomStringConvertible {
    let text: String
    let selection: NSRange

    init(_ marked: String) {
        var text = ""
        var start: Int?
        var end: Int?
        for character in marked {
            let offset = (text as NSString).length
            switch character {
            case "‸": start = offset; end = offset
            case "«": start = offset
            case "»": end = offset
            default: text.append(character)
            }
        }
        let location = start ?? 0
        self.text = text
        selection = NSRange(location: location, length: (end ?? location) - location)
    }

    init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }

    /// The text after `edit`, with its new selection marked.
    func applying(_ edit: TextEdit?) -> String? {
        guard let edit else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return MarkedText(text: result, selection: edit.selection).description
    }

    var description: String {
        let marked = NSMutableString(string: text)
        if selection.length == 0 {
            marked.insert("‸", at: selection.location)
        } else {
            marked.insert("»", at: NSMaxRange(selection))
            marked.insert("«", at: selection.location)
        }
        return marked as String
    }
}

struct CodeEditingTests {
    private func edit(
        _ marked: String,
        _ make: (NSString, NSRange) -> TextEdit?
    ) -> String? {
        let start = MarkedText(marked)
        return start.applying(make(start.text as NSString, start.selection))
    }

    // MARK: - Indent style

    @Test func anIndentLevelIsFourSpacesOrATab() {
        #expect(IndentStyle.fourSpaces.unit == "    ")
        #expect(IndentStyle.tabs.unit == "\t")
    }

    @Test func columnsCountTabsToTheNextStop() {
        #expect(IndentStyle.fourSpaces.column(after: "ab") == 2)
        #expect(IndentStyle.fourSpaces.column(after: "ab\t") == 4)
        #expect(IndentStyle.fourSpaces.column(after: "\t\t") == 8)
        #expect(IndentStyle.fourSpaces.column(after: "\tx") == 5)
    }

    // MARK: - Lines

    @Test func aSelectionCoversTheLinesItTouches() {
        let text = "one\ntwo\nthree" as NSString
        let lines = CodeEditing.lines(in: text, coveredBy: NSRange(location: 1, length: 5))
        #expect(lines == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
    }

    @Test func aSelectionEndingAtALineStartLeavesThatLineOut() {
        let text = "one\ntwo\nthree" as NSString
        let lines = CodeEditing.lines(in: text, coveredBy: NSRange(location: 0, length: 8))
        #expect(lines == [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
    }

    @Test func theEmptyLastLineCanBeTheCursorsLine() {
        let text = "one\n" as NSString
        let lines = CodeEditing.lines(in: text, coveredBy: NSRange(location: 4, length: 0))
        #expect(lines == [NSRange(location: 4, length: 0)])
    }

    // MARK: - Tab and Backspace

    @Test func tabInsertsSpacesToTheNextTabStop() {
        #expect(edit("‸x") { CodeEditing.tab(in: $0, selection: $1, style: .fourSpaces) } == "    ‸x")
        #expect(edit("ab‸") { CodeEditing.tab(in: $0, selection: $1, style: .fourSpaces) } == "ab  ‸")
        #expect(edit("ab‸") { CodeEditing.tab(in: $0, selection: $1, style: .tabs) } == "ab\t‸")
    }

    @Test func backspaceInIndentationDeletesBackToTheLastTabStop() {
        let backspace: (NSString, NSRange) -> TextEdit? = {
            CodeEditing.deleteIndentation(in: $0, selection: $1, style: .fourSpaces)
        }
        #expect(edit("        ‸x", backspace) == "    ‸x")
        #expect(edit("      ‸x", backspace) == "    ‸x")
        // One space, or past the indentation, is an ordinary backspace.
        #expect(edit("     ‸x", backspace) == nil)
        #expect(edit("    x ‸", backspace) == nil)
        #expect(edit("\t‸x") { CodeEditing.deleteIndentation(in: $0, selection: $1, style: .tabs) } == nil)
    }
}
