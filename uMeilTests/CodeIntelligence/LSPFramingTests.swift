import Foundation
import Testing
@testable import uMeil

struct LSPFramingTests {
    @Test func encodesContentLengthHeaderInUTF8Bytes() {
        let payload = Data("{\"text\":\"😀\"}".utf8)
        let encoded = LSPFraming.encode(payload)
        let prefix = "Content-Length: \(payload.count)\r\n\r\n"
        #expect(encoded == Data(prefix.utf8) + payload)
    }

    @Test func decodesSingleAndMultipleMessagesAcrossArbitraryChunks() throws {
        let first = Data("{\"id\":1,\"msg\":\"héllo 😀\"}".utf8)
        let second = Data("{\"id\":2}".utf8)
        let stream = LSPFraming.encode(first) + LSPFraming.encode(second)

        var buffer = LSPFraming.MessageBuffer()
        var decoded: [Data] = []
        // Feed 3 bytes at a time to exercise split headers and multi-byte bodies.
        var index = stream.startIndex
        while index < stream.endIndex {
            let end = min(index + 3, stream.endIndex)
            decoded += try buffer.append(Data(stream[index..<end]))
            index = end
        }

        #expect(decoded == [first, second])
    }

    @Test func acceptsCaseInsensitiveContentLengthAndLFHeaders() throws {
        let payload = Data("{\"ok\":true}".utf8)
        let header = "content-type: application/vscode-jsonrpc; charset=utf-8\ncontent-length: \(payload.count)\n\n"
        var raw = Data(header.utf8)
        raw.append(payload)

        var buffer = LSPFraming.MessageBuffer()
        let decoded = try buffer.append(raw)

        #expect(decoded == [payload])
    }

    @Test func rejectsHeadersWithoutValidContentLength() {
        var buffer = LSPFraming.MessageBuffer()
        let bad = Data("Content-Type: application/json\r\n\r\n{}".utf8)

        #expect(throws: LSPFramingError.invalidHeader) {
            try buffer.append(bad)
        }
    }
}
