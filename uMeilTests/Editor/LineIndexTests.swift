import Foundation
import Testing
@testable import uMeil

struct LineIndexTests {
    @Test func emptyTextHasOneEmptyLine() {
        let index = LineIndex("")

        #expect(index.lineCount == 1)
        #expect(index.length == 0)
        #expect(index.lineNumber(atOffset: 0) == 1)
        #expect(index.range(ofLine: 1) == NSRange(location: 0, length: 0))
    }

    @Test func countsLinesWithAndWithoutATrailingNewline() {
        #expect(LineIndex("one").lineCount == 1)
        #expect(LineIndex("one\ntwo").lineCount == 2)
        // A trailing newline starts a new, empty last line.
        #expect(LineIndex("one\ntwo\n").lineCount == 3)
        #expect(LineIndex("\n\n\n").lineCount == 4)
    }

    @Test func findsTheLineForAnOffset() {
        // Offsets:      0123 4567 89
        let index = LineIndex("abc\ndef\ngh")

        #expect(index.lineNumber(atOffset: 0) == 1)
        #expect(index.lineNumber(atOffset: 3) == 1) // the newline belongs to its line
        #expect(index.lineNumber(atOffset: 4) == 2)
        #expect(index.lineNumber(atOffset: 7) == 2)
        #expect(index.lineNumber(atOffset: 8) == 3)
        #expect(index.lineNumber(atOffset: 10) == 3) // end of text
        #expect(index.lineNumber(atOffset: 999) == 3) // past the end
    }

    @Test func findsWhereALineStartsAndItsRange() {
        let index = LineIndex("abc\ndef\ngh")

        #expect(index.offset(ofLine: 1) == 0)
        #expect(index.offset(ofLine: 2) == 4)
        #expect(index.offset(ofLine: 3) == 8)
        #expect(index.offset(ofLine: 0) == nil)
        #expect(index.offset(ofLine: 4) == nil)

        #expect(index.range(ofLine: 1) == NSRange(location: 0, length: 4)) // includes "\n"
        #expect(index.range(ofLine: 3) == NSRange(location: 8, length: 2))
        #expect(index.range(ofLine: 4) == nil)
    }

    @Test func treatsWindowsLineEndingsAsOneLineBreak() {
        let index = LineIndex("ab\r\ncd\r\n")

        #expect(index.lineCount == 3)
        #expect(index.offset(ofLine: 2) == 4)
        #expect(index.lineNumber(atOffset: 3) == 1) // the "\n" of the first "\r\n"
    }

    @Test func countsOffsetsInUTF16LikeTheTextView() {
        // "é" is one UTF-16 unit, "😀" is two.
        let text = "é😀\nx"
        let index = LineIndex(text)

        #expect(index.length == (text as NSString).length)
        #expect(index.offset(ofLine: 2) == 4)
    }

    @Test func convertsCompilerLineAndColumnToAnOffset() {
        let index = LineIndex("int main(void) {\n    return 0;\n}\n")

        #expect(index.offset(line: 1, column: 1) == 0)
        #expect(index.offset(line: 2, column: 5) == 21) // the "r" of "return"
        // A column past the end of the line stops at the line's end,
        // before its newline, not at the start of the next line.
        #expect(index.offset(line: 3, column: 99) == 32)
        #expect(index.offset(line: 1, column: 18) == 16)
        #expect(index.offset(line: 4, column: 5) == 33)
        #expect(index.offset(line: 9, column: 1) == nil)
    }

    @Test func aColumnPastTheEndStopsBeforeAWindowsLineEnding() {
        let index = LineIndex("ab\r\ncd\r\n")

        #expect(index.offset(line: 1, column: 3) == 2)
        #expect(index.offset(line: 1, column: 50) == 2)
        #expect(index.offset(line: 2, column: 50) == 6)
    }

    @Test func handlesATenThousandLineFile() {
        let text = String(repeating: "    GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_0, GPIO_PIN_0);\n", count: 10_000)
        let index = LineIndex(text)

        #expect(index.lineCount == 10_001)
        #expect(index.lineNumber(atOffset: index.length) == 10_001)
        let lastFullLine = index.range(ofLine: 10_000)
        #expect(lastFullLine.map { index.lineNumber(atOffset: $0.location) } == 10_000)
    }

    @Test func gccByteColumnsBecomeEditorColumnsOnLinesWithNonASCIIText() {
        // `;` is byte column 17 (µ takes two bytes) but UTF-16 column 16.
        #expect(EditorViewController.utf16Column(fromUTF8Column: 17, in: "/* 5 µs */ x = ;") == 16)
        #expect(EditorViewController.utf16Column(fromUTF8Column: 5, in: "int x;") == 5)
        #expect(EditorViewController.utf16Column(fromUTF8Column: 1, in: "µ") == 1)
    }
}
