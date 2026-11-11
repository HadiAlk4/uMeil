import Foundation
import Testing
@testable import uMeil

struct TextDocumentTests {
    @Test func loadsAndSavesUTF8() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "main.c")
        try Data("int main(void) { return 0; } // é\n".utf8).write(to: url)

        var document = try TextDocument.load(from: url)
        #expect(document.text == "int main(void) { return 0; } // é\n")
        #expect(document.encoding == .utf8)

        document.text += "// more\n"
        try document.save()

        #expect(try String(contentsOf: url, encoding: .utf8) == "int main(void) { return 0; } // é\n// more\n")
    }

    @Test func readsFilesThatAreNotValidUTF8AndWritesTheSameBytesBack() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "legacy.h")
        // "µC" in Latin-1: 0xB5 on its own is not valid UTF-8.
        let original = Data([0x2F, 0x2F, 0x20, 0xB5, 0x43, 0x0A])
        try original.write(to: url)

        let document = try TextDocument.load(from: url)
        #expect(document.text == "// µC\n")
        #expect(document.encoding == .isoLatin1)

        try document.save()
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func fallsBackToUTF8WhenNewTextDoesNotFitTheOriginalEncoding() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "legacy.h")
        try Data([0xB5, 0x0A]).write(to: url)

        var document = try TextDocument.load(from: url)
        document.text = "µ → λ\n" // the arrow and lambda are not in Latin-1
        try document.save()

        #expect(try String(contentsOf: url, encoding: .utf8) == "µ → λ\n")
    }

    @Test func preservesWindowsLineEndings() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "crlf.c")
        try Data("a\r\nb\r\n".utf8).write(to: url)

        let document = try TextDocument.load(from: url)
        try document.save()

        #expect(try Data(contentsOf: url) == Data("a\r\nb\r\n".utf8))
    }

    @Test func refusesBinaryFiles() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "firmware.bin")
        try Data([0x00, 0x20, 0x00, 0x20, 0xFF]).write(to: url)

        #expect(throws: TextDocumentError.notText) {
            try TextDocument.load(from: url)
        }
    }

    @Test func reportsAMissingFile() throws {
        let temp = try TemporaryDirectory()

        #expect(throws: (any Error).self) {
            try TextDocument.load(from: temp.url.appending(path: "nope.c"))
        }
    }

    @Test func loadsAnEmptyFile() throws {
        let temp = try TemporaryDirectory()
        let url = temp.url.appending(path: "empty.c")
        try Data().write(to: url)

        #expect(try TextDocument.load(from: url).text.isEmpty)
    }
}
