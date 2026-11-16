import Foundation
import Testing
@testable import uMeil

struct SerialTextTests {
    private func decode(_ batches: [[UInt8]]) -> [String] {
        var decoder = SerialTextDecoder()
        return batches.map { decoder.decode(Data($0)) }
    }

    @Test func plainTextComesThroughAsItIs() {
        #expect(decode([Array("Hello, world".utf8)]) == ["Hello, world"])
    }

    @Test(arguments: ["one\r\ntwo\r\n", "one\rtwo\r", "one\ntwo\n"])
    func everyKindOfLineEndingBecomesOneNewline(text: String) {
        #expect(decode([Array(text.utf8)]) == ["one\ntwo\n"])
    }

    @Test func aLineEndingSplitAcrossTwoBatchesIsStillOneNewline() {
        #expect(decode([Array("one\r".utf8), Array("\ntwo".utf8)]) == ["one\n", "two"])
    }

    @Test func blankLinesAreKept() {
        #expect(decode([Array("a\r\n\r\nb\n\nc\r\rd".utf8)]) == ["a\n\nb\n\nc\n\nd"])
    }

    @Test func aCharacterSplitAcrossBatchesIsPutBackTogether() {
        let degree = Array("25 °C".utf8) // "°" is two bytes.
        #expect(decode([Array(degree[..<4]), Array(degree[4...])]) == ["25 ", "°C"])

        let emoji = Array("ok 👍".utf8) // Four bytes, delivered one at a time.
        #expect(decode(emoji.map { [$0] }).joined() == "ok 👍")
    }

    @Test func bytesThatAreNotTextBecomeTheReplacementCharacter() {
        #expect(decode([[0x41, 0xFF, 0x42]]) == ["A\u{FFFD}B"])
        // The start of a two-byte character that is never finished.
        #expect(decode([[0x41, 0xC2], [0x42]]) == ["A", "\u{FFFD}B"])
    }

    @Test func anEmptyBatchGivesNoText() {
        #expect(decode([[]]) == [""])
    }

    @Test func lineEndingsToSend() {
        #expect(SerialLineEnding.allCases.map(\.text) == ["", "\r", "\n", "\r\n"])
        #expect(SerialLineEnding.standard == .carriageReturn)
    }
}
