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

// MARK: - Return and closing braces

struct AutoIndentTests {
    private func newline(_ marked: String, style: IndentStyle = .fourSpaces) -> String? {
        let start = MarkedText(marked)
        return start.applying(CodeEditing.newline(in: start.text as NSString, selection: start.selection, style: style))
    }

    private func closeBrace(_ marked: String) -> String? {
        let start = MarkedText(marked)
        return start.applying(
            CodeEditing.closingBrace(in: start.text as NSString, selection: start.selection, style: .fourSpaces)
        )
    }

    @Test func returnKeepsTheLinesIndentation() {
        #expect(newline("    x = 1;‸") == "    x = 1;\n    ‸")
        #expect(newline("\tx = 1;‸", style: .tabs) == "\tx = 1;\n\t‸")
        #expect(newline("x = 1;‸") == "x = 1;\n‸")
    }

    @Test func returnAfterABraceIndentsOneLevelMore() {
        #expect(newline("int main(void) {‸") == "int main(void) {\n    ‸")
        #expect(newline("    if (x) {  ‸") == "    if (x) {\n        ‸")
        #expect(newline("\tif (x) {‸", style: .tabs) == "\tif (x) {\n\t\t‸")
    }

    @Test func aBraceInACommentOrStringDoesNotIndent() {
        #expect(newline("x = 1; // {‸") == "x = 1; // {\n‸")
        #expect(newline("puts(\"{‸") == "puts(\"{\n‸")
    }

    @Test func returnBetweenBracesPutsTheCloserOnItsOwnLine() {
        #expect(newline("    if (x) {‸}") == "    if (x) {\n        ‸\n    }")
        #expect(newline("void f(void) {‸ }") == "void f(void) {\n    ‸\n}")
    }

    @Test func returnDropsSpacesAroundTheBreak() {
        #expect(newline("    x = 1;   ‸") == "    x = 1;\n    ‸")
        #expect(newline("    a = b;‸   c = d;") == "    a = b;\n    ‸c = d;")
    }

    @Test func returnOnABlankIndentedLineLeavesNoSpacesBehind() {
        #expect(newline("{\n    ‸\n}") == "{\n\n    ‸\n}")
        #expect(newline("‸    x = 1;") == "\n‸    x = 1;")
    }

    @Test func returnReplacesTheSelection() {
        #expect(newline("    a«bc»d") == "    a\n    ‸d")
    }

    @Test func aClosingBraceLinesUpWithItsOpeningLine() {
        #expect(closeBrace("    if (x) {\n        y();\n        ‸") == "    if (x) {\n        y();\n    }‸")
        #expect(closeBrace("int main(void) {\n    ‸") == "int main(void) {\n}‸")
        #expect(closeBrace("int main(void) {\n‸") == nil)
    }

    @Test func aClosingBraceWithNoOpeningOneOutdentsALevel() {
        #expect(closeBrace("        ‸") == "    }‸")
        #expect(closeBrace("  ‸") == "}‸")
    }

    @Test func aClosingBraceAfterOtherTextIsLeftAlone() {
        #expect(closeBrace("int main(void) {\n    x = 1; ‸") == nil)
        #expect(closeBrace("int main(void) {\n    /* ‸") == nil)
    }
}

// MARK: - Shifting lines

struct ShiftLinesTests {
    private func shift(
        _ marked: String,
        _ direction: CodeEditing.ShiftDirection,
        style: IndentStyle = .fourSpaces
    ) -> String? {
        let start = MarkedText(marked)
        return start.applying(
            CodeEditing.shiftLines(
                in: start.text as NSString,
                selection: start.selection,
                style: style,
                direction: direction
            )
        )
    }

    @Test func shiftingRightIndentsEverySelectedLine() {
        #expect(shift("«a\nb»\nc", .right) == "«    a\n    b»\nc")
        #expect(shift("a\n«b\n»c", .right) == "a\n«    b\n»c")
        #expect(shift("x‸ = 1;", .right) == "    x‸ = 1;")
        #expect(shift("«a\nb»", .right, style: .tabs) == "«\ta\n\tb»")
    }

    @Test func shiftingRightLeavesEmptyLinesEmpty() {
        #expect(shift("«a\n\nb»", .right) == "«    a\n\n    b»")
    }

    @Test func shiftingLeftRemovesOneLevel() {
        #expect(shift("«        a\n    b»", .left) == "«    a\nb»")
        #expect(shift("«\ta\n  b»", .left) == "«a\nb»")
        #expect(shift("    x‸ = 1;", .left) == "x‸ = 1;")
    }

    @Test func shiftingLeftWithNothingToRemoveDoesNothing() {
        #expect(shift("«a\nb»", .left) == nil)
    }

    @Test func aCursorInTheIndentationStaysAtTheLineStart() {
        #expect(shift("  ‸  a", .left) == "‸a")
    }
}

// MARK: - Commenting lines

struct LineCommentTests {
    private func toggle(_ marked: String) -> String? {
        let start = MarkedText(marked)
        return start.applying(
            CodeEditing.toggleLineComment(in: start.text as NSString, selection: start.selection, prefix: "//")
        )
    }

    @Test func commentsTheCursorsLine() {
        #expect(toggle("x‸ = 1;") == "// x‸ = 1;")
        #expect(toggle("    x‸ = 1;") == "    // x‸ = 1;")
    }

    @Test func uncommentsACommentedLine() {
        #expect(toggle("// x‸ = 1;") == "x‸ = 1;")
        #expect(toggle("    //x = 1;‸") == "    x = 1;‸")
    }

    @Test func commentsSelectedLinesAtTheirSmallestIndentation() {
        #expect(toggle("«    if (x) {\n        y();\n    }»\n") == "«    // if (x) {\n    //     y();\n    // }»\n")
    }

    @Test func skipsBlankLines() {
        #expect(toggle("«a();\n\nb();»") == "«// a();\n\n// b();»")
        #expect(toggle("«// a();\n\n// b();»") == "«a();\n\nb();»")
    }

    @Test func aMixOfCommentedAndPlainLinesIsCommented() {
        #expect(toggle("«// a();\nb();»") == "«// // a();\n// b();»")
    }

    @Test func anEmptyLineCanBeCommented() {
        #expect(toggle("‸") == "// ‸")
    }

    @Test func togglingTwiceGivesBackTheText() {
        let start = MarkedText("«    a();\n\tb();\n»c();")
        let text = start.text as NSString
        let once = CodeEditing.toggleLineComment(in: text, selection: start.selection, prefix: "//")
        let commented = text.replacingCharacters(in: once!.range, with: once!.replacement) as NSString
        let twice = CodeEditing.toggleLineComment(in: commented, selection: once!.selection, prefix: "//")
        let restored = commented.replacingCharacters(in: twice!.range, with: twice!.replacement)
        #expect(restored == start.text)
    }
}
