import Foundation

enum LSPFramingError: Error, Equatable {
    case invalidHeader
}

/// Encodes and decodes JSON-RPC messages using LSP's `Content-Length` framing.
enum LSPFraming {
    private static let headerTerminatorCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])
    private static let headerTerminatorLF = Data([0x0A, 0x0A])

    /// Wraps a JSON-RPC payload with its `Content-Length` header.
    static func encode(_ payload: Data) -> Data {
        var packet = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        packet.append(payload)
        return packet
    }

    /// Parses the `Content-Length` header value from a raw LSP header block.
    static func contentLength(in headerData: Data) -> Int? {
        guard let headerText = String(data: headerData, encoding: .ascii) else { return nil }
        for rawLine in headerText.split(whereSeparator: \.isNewline) {
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let name = rawLine[..<colon].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                let value = rawLine[rawLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let length = Int(value), length >= 0 {
                    return length
                }
                return nil
            }
        }
        return nil
    }

    /// Accumulates incoming pipe chunks and yields complete JSON-RPC message payloads.
    struct MessageBuffer: Sendable {
        private var buffer = Data()

        mutating func append(_ chunk: Data) throws -> [Data] {
            guard !chunk.isEmpty else { return [] }
            buffer.append(chunk)

            var payloads: [Data] = []
            while let boundary = findHeaderBoundary() {
                let headerData = buffer[..<boundary.headerEnd]
                guard let length = LSPFraming.contentLength(in: headerData) else {
                    throw LSPFramingError.invalidHeader
                }
                let bodyEnd = boundary.bodyStart + length
                guard buffer.count >= bodyEnd else { break }

                payloads.append(Data(buffer[boundary.bodyStart..<bodyEnd]))
                buffer = Data(buffer[bodyEnd...])
            }
            return payloads
        }

        private func findHeaderBoundary() -> (headerEnd: Int, bodyStart: Int)? {
            let crlfRange = buffer.range(of: LSPFraming.headerTerminatorCRLF)
            let lfRange = buffer.range(of: LSPFraming.headerTerminatorLF)

            switch (crlfRange, lfRange) {
            case let (crlf?, lineFeed?):
                let chosen = crlf.lowerBound <= lineFeed.lowerBound ? crlf : lineFeed
                return (chosen.lowerBound, chosen.upperBound)
            case let (crlf?, nil):
                return (crlf.lowerBound, crlf.upperBound)
            case let (nil, lineFeed?):
                return (lineFeed.lowerBound, lineFeed.upperBound)
            case (nil, nil):
                return nil
            }
        }
    }
}
