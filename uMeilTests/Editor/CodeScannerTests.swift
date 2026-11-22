import Foundation
import Testing
@testable import uMeil

struct CodeScannerTests {
    /// What the text is at `‸`.
    private func context(_ marked: String) -> CodeContext {
        let start = MarkedText(marked)
        return CodeScan(start.text as NSString, upTo: start.selection.location).context
    }

    @Test func tellsCodeFromStringsAndComments() {
        #expect(context("int x = ‸1;") == .code)
        #expect(context("puts(\"hi ‸there\");") == .string)
        #expect(context("char c = '‸a';") == .character)
        #expect(context("x = 1; // set ‸x") == .lineComment)
        #expect(context("/* one\n two ‸*/") == .blockComment)
    }

    @Test func findsWhereStringsAndCommentsEnd() {
        #expect(context("puts(\"hi\");‸") == .code)
        #expect(context("puts(\"say \\\"hi\\\" ‸\");") == .string)
        #expect(context("// note\nint ‸x;") == .code)
        #expect(context("/* a */ int ‸x;") == .code)
        #expect(context("puts(\"never closed\n‸") == .code)
    }

    @Test func aSlashJustBeforeTheCursorIsStillCode() {
        #expect(context("x = a /‸") == .code)
    }

    @Test func tracksOpenBracesOutsideStringsAndComments() {
        let text = "int main(void) {\n    if (x) { }\n    puts(\"{\"); // {\n    ‸" as NSString
        let scan = CodeScan(text, upTo: text.length)
        #expect(scan.openBraces == [15])
    }
}
