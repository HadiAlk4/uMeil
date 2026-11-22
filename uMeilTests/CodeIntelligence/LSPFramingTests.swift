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

    @Test func rejectsDuplicateContentLengthHeaders() {
        var buffer = LSPFraming.MessageBuffer()
        let duplicate = Data("Content-Length: 2\r\nContent-Length: 99\r\n\r\n{}".utf8)

        #expect(throws: LSPFramingError.invalidHeader) {
            try buffer.append(duplicate)
        }
    }

    @Test func rejectsContentLengthExceedingMaximumMessageLength() {
        var buffer = LSPFraming.MessageBuffer()
        let oversized = Data("Content-Length: \(LSPFraming.maximumMessageLength + 1)\r\n\r\n{}".utf8)

        #expect(throws: LSPFramingError.messageTooLarge) {
            try buffer.append(oversized)
        }
    }

    @Test func rejectsOverflowingContentLength() {
        var maxIntBuffer = LSPFraming.MessageBuffer()
        let maxIntHeader = Data("Content-Length: \(Int.max)\r\n\r\n{}".utf8)
        #expect(throws: LSPFramingError.messageTooLarge) {
            try maxIntBuffer.append(maxIntHeader)
        }

        var beyondIntBuffer = LSPFraming.MessageBuffer()
        let beyondIntHeader = Data("Content-Length: 99999999999999999999999999999\r\n\r\n{}".utf8)
        #expect(throws: LSPFramingError.invalidHeader) {
            try beyondIntBuffer.append(beyondIntHeader)
        }
    }

    @Test func rejectsOversizedHeadersWhileWaitingForTerminatorAndWithTerminator() throws {
        var singleChunkBuffer = LSPFraming.MessageBuffer()
        let unterminated = Data(repeating: 0x41, count: LSPFraming.maximumHeaderLength + 1)
        #expect(throws: LSPFramingError.headerTooLarge) {
            try singleChunkBuffer.append(unterminated)
        }

        var incrementalBuffer = LSPFraming.MessageBuffer()
        let half = Data(repeating: 0x41, count: LSPFraming.maximumHeaderLength / 2)
        #expect(try incrementalBuffer.append(half).isEmpty)
        #expect(try incrementalBuffer.append(half).isEmpty)
        #expect(throws: LSPFramingError.headerTooLarge) {
            try incrementalBuffer.append(Data([0x41]))
        }

        var terminatedBuffer = LSPFraming.MessageBuffer()
        var oversizedTerminated = Data(repeating: 0x41, count: LSPFraming.maximumHeaderLength + 1)
        oversizedTerminated.append(Data("\r\nContent-Length: 2\r\n\r\n{}".utf8))
        #expect(throws: LSPFramingError.headerTooLarge) {
            try terminatedBuffer.append(oversizedTerminated)
        }
    }

    @Test func decodesMultiChunkBodyLargerThanMaximumHeaderLength() throws {
        let payload = Data(repeating: 0x78, count: LSPFraming.maximumHeaderLength + 2048)
        let packet = LSPFraming.encode(payload)
        let splitIndex = packet.count / 2

        var buffer = LSPFraming.MessageBuffer()
        #expect(try buffer.append(Data(packet[..<splitIndex])).isEmpty)
        let decoded = try buffer.append(Data(packet[splitIndex...]))
        #expect(decoded == [payload])
    }
}
