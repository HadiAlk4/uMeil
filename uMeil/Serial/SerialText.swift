import Foundation

/// Turns the bytes a board sends into text for the console, a batch at a time.
///
/// Bytes arrive in arbitrary pieces, so a character or a line ending can be
/// split across two batches. The decoder keeps what it needs between calls.
struct SerialTextDecoder {
    /// The start of a UTF-8 character whose remaining bytes have not arrived yet.
    private var pending: [UInt8] = []
    /// Whether the last character seen was a carriage return, so that a line
    /// feed following it is not counted as a second line ending.
    private var endedWithCarriageReturn = false

    /// Returns the text for `data`. Every kind of line ending (CR LF, CR or
    /// LF) comes out as a single newline, and bytes that are not valid UTF-8
    /// come out as the replacement character.
    mutating func decode(_ data: Data) -> String {
        var bytes = pending + data
        pending = Self.removeIncompleteCharacter(from: &bytes)

        var text = String.UnicodeScalarView()
        // Lossy on purpose: a board can send bytes that are not text.
        // swiftlint:disable:next optional_data_string_conversion
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar {
            case "\r":
                text.append("\n")
            case "\n" where endedWithCarriageReturn:
                break
            default:
                text.append(scalar)
            }
            endedWithCarriageReturn = scalar == "\r"
        }
        return String(text)
    }

    /// Takes the bytes of an unfinished character off the end of `bytes` and returns them.
    private static func removeIncompleteCharacter(from bytes: inout [UInt8]) -> [UInt8] {
        // A character is at most 4 bytes, so its first byte is within the last 3.
        for back in 1...3 where back <= bytes.count {
            let byte = bytes[bytes.count - back]
            if byte & 0b1100_0000 == 0b1000_0000 { continue } // A continuation byte: keep looking.

            let length: Int = switch byte {
            case 0b1100_0000...0b1101_1111: 2
            case 0b1110_0000...0b1110_1111: 3
            case 0b1111_0000...0b1111_0111: 4
            default: 1
            }
            guard length > back else { break }
            let tail = Array(bytes.suffix(back))
            bytes.removeLast(back)
            return tail
        }
        return []
    }
}

/// What is added to the end of each line the user sends.
enum SerialLineEnding: String, CaseIterable, Sendable {
    case none, carriageReturn, lineFeed, both

    /// What a terminal sends for the Return key, which is what firmware
    /// written against PuTTY or Tera Term expects.
    static let standard = SerialLineEnding.carriageReturn

    var title: String {
        switch self {
        case .none: "No Line Ending"
        case .carriageReturn: "CR"
        case .lineFeed: "LF"
        case .both: "CR LF"
        }
    }

    var text: String {
        switch self {
        case .none: ""
        case .carriageReturn: "\r"
        case .lineFeed: "\n"
        case .both: "\r\n"
        }
    }
}
