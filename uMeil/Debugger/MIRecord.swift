import Foundation

/// A value in GDB's machine interface (GDB/MI): text, a tuple of named
/// fields, or a list.
enum MIValue: Equatable, Sendable {
    case string(String)
    /// `{name="value",...}`. Fields keep their order, and a name can repeat.
    case tuple([MIField])
    /// `[value,...]` or `[name=value,...]`. The names in the second form are
    /// all the same (`frame=`, `bkpt=`), so they are dropped.
    case list([MIValue])

    static let empty = MIValue.tuple([])

    /// The first field called `name`, if this is a tuple that has one.
    subscript(name: String) -> MIValue? {
        guard case .tuple(let fields) = self else { return nil }
        return fields.first { $0.name == name }?.value
    }

    var string: String? {
        if case .string(let text) = self { text } else { nil }
    }

    var list: [MIValue]? {
        if case .list(let items) = self { items } else { nil }
    }

    /// The text of the field called `name`.
    func text(_ name: String) -> String? {
        self[name]?.string
    }

    /// The field called `name` as a decimal number, as in `line="21"`.
    func integer(_ name: String) -> Int? {
        text(name).flatMap { Int($0) }
    }

    /// The field called `name` as an address, as in `addr="0x0000020a"`.
    func address(_ name: String) -> UInt64? {
        text(name).flatMap(MIValue.address)
    }

    /// Reads `0x0000020a`. GDB sometimes follows an address with a symbol,
    /// as in `0x20a <main+2>`, which is ignored.
    static func address(_ text: String) -> UInt64? {
        guard text.hasPrefix("0x") else { return nil }
        return UInt64(text.dropFirst(2).prefix { $0.isHexDigit }, radix: 16)
    }
}

struct MIField: Equatable, Sendable {
    var name: String
    var value: MIValue
}

/// One line of GDB/MI output.
enum MIRecord: Equatable, Sendable {
    /// The answer to a command: `^done,...`, `^running`, `^error,msg="..."`.
    /// `token` is the number the command was sent with.
    case result(token: Int?, outcome: Outcome, values: MIValue)
    /// Something that happened by itself: `*stopped,...`, `=breakpoint-modified,...`.
    case event(kind: EventKind, name: String, values: MIValue)
    /// Text for a person to read: `~"..."`, `@"..."`, `&"..."`.
    case stream(kind: StreamKind, text: String)
    /// `(gdb)`: GDB has finished what it was printing.
    case prompt

    enum Outcome: String, Sendable {
        case done, running, connected, error, exit
    }

    enum EventKind: Character, Sendable {
        /// The program started or stopped running.
        case exec = "*"
        /// Progress of a slow command, such as a download.
        case status = "+"
        /// Extra news: a breakpoint changed, a thread appeared.
        case notify = "="
    }

    enum StreamKind: Character, Sendable {
        /// What GDB's command line would have printed.
        case console = "~"
        /// What the program being debugged printed.
        case target = "@"
        /// GDB's own messages and errors.
        case log = "&"
    }
}

struct MIParseError: Error, Equatable {
    /// The line that could not be read.
    var line: String
}

/// Reads lines of GDB/MI output.
///
/// The format is described in the GDB manual under "GDB/MI Output Syntax".
enum MIParser {
    /// Reads one line, without its line ending. Lines that are not GDB/MI,
    /// such as raw output from the program, throw `MIParseError`.
    static func parse(_ line: String) throws -> MIRecord {
        var scanner = Scanner(line)
        guard let record = scanner.record(), scanner.isAtEnd else {
            throw MIParseError(line: line)
        }
        return record
    }

    private struct Scanner {
        private static let maximumNestingDepth = 64

        private let bytes: [UInt8]
        private var position = 0
        private var depth = 0

        init(_ line: String) {
            bytes = Array(line.utf8)
        }

        var isAtEnd: Bool { position == bytes.count }

        private var next: UInt8? {
            position < bytes.count ? bytes[position] : nil
        }

        private mutating func take(_ character: Character) -> Bool {
            guard next == character.asciiValue else { return false }
            position += 1
            return true
        }

        mutating func record() -> MIRecord? {
            if bytes.elementsEqual("(gdb)".utf8) || bytes.elementsEqual("(gdb) ".utf8) {
                position = bytes.count
                return .prompt
            }

            let token = number()
            guard let marker = next.map({ Character(UnicodeScalar($0)) }) else { return nil }
            position += 1

            if let kind = MIRecord.StreamKind(rawValue: marker) {
                guard token == nil, let text = cString() else { return nil }
                return .stream(kind: kind, text: text)
            }

            let name = word()
            guard let values = results() else { return nil }
            if marker == "^" {
                guard let outcome = MIRecord.Outcome(rawValue: name) else { return nil }
                return .result(token: token, outcome: outcome, values: .tuple(values))
            }
            guard let kind = MIRecord.EventKind(rawValue: marker), !name.isEmpty else { return nil }
            return .event(kind: kind, name: name, values: .tuple(values))
        }

        /// The digits at the start of a line: the token of the command a
        /// result answers.
        private mutating func number() -> Int? {
            let start = position
            while let byte = next, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                position += 1
            }
            return Int(text(from: start))
        }

        /// A name: a result class such as `done`, or a field name such as
        /// `thread-groups`.
        private mutating func word() -> String {
            let start = position
            while let byte = next, byte != UInt8(ascii: "="), byte != UInt8(ascii: ","),
                  byte != UInt8(ascii: "]"), byte != UInt8(ascii: "}") {
                position += 1
            }
            return text(from: start)
        }

        private func text(from start: Int) -> String {
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: bytes[start..<position], as: UTF8.self)
        }

        /// The `,name=value` pairs that follow a result class.
        private mutating func results() -> [MIField]? {
            var fields: [MIField] = []
            while take(",") {
                // Download progress breaks the syntax with a bare tuple:
                // `+download,{section=".text",...}`. It gets an empty name.
                if next == UInt8(ascii: "{") {
                    guard let value = tuple() else { return nil }
                    fields.append(MIField(name: "", value: value))
                    continue
                }
                guard let field = field() else { return nil }
                fields.append(field)
            }
            return fields
        }

        private mutating func field() -> MIField? {
            let name = word()
            guard !name.isEmpty, take("="), let value = value() else { return nil }
            return MIField(name: name, value: value)
        }

        private mutating func value() -> MIValue? {
            switch next {
            case UInt8(ascii: "\""):
                return cString().map(MIValue.string)
            case UInt8(ascii: "{"):
                return tuple()
            case UInt8(ascii: "["):
                return list()
            default:
                return nil
            }
        }

        private mutating func tuple() -> MIValue? {
            guard depth < Self.maximumNestingDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            guard take("{") else { return nil }
            var fields: [MIField] = []
            if take("}") { return .tuple(fields) }
            repeat {
                guard let field = field() else { return nil }
                fields.append(field)
            } while take(",")
            return take("}") ? .tuple(fields) : nil
        }

        private mutating func list() -> MIValue? {
            guard depth < Self.maximumNestingDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            guard take("[") else { return nil }
            var items: [MIValue] = []
            if take("]") { return .list(items) }
            repeat {
                // An item is a bare value, or a named one whose name is dropped.
                if let byte = next, byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "{")
                    || byte == UInt8(ascii: "[") {
                    guard let item = value() else { return nil }
                    items.append(item)
                } else {
                    guard let field = field() else { return nil }
                    items.append(field.value)
                }
            } while take(",")
            return take("]") ? .list(items) : nil
        }

        /// A quoted string with C escapes. Bytes outside ASCII arrive as
        /// octal escapes (`\303\251`), so the string is rebuilt as bytes and
        /// decoded as UTF-8 at the end.
        private mutating func cString() -> String? {
            guard take("\"") else { return nil }
            var content: [UInt8] = []
            while let byte = next {
                position += 1
                switch byte {
                case UInt8(ascii: "\""):
                    // swiftlint:disable:next optional_data_string_conversion
                    return String(decoding: content, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard let escaped = escape() else { return nil }
                    content.append(escaped)
                default:
                    content.append(byte)
                }
            }
            return nil // The closing quote is missing.
        }

        private static let escapes: [UInt8: UInt8] = [
            UInt8(ascii: "n"): UInt8(ascii: "\n"),
            UInt8(ascii: "t"): UInt8(ascii: "\t"),
            UInt8(ascii: "r"): UInt8(ascii: "\r"),
            UInt8(ascii: "e"): 0x1B,
            UInt8(ascii: "a"): 0x07,
            UInt8(ascii: "b"): 0x08,
            UInt8(ascii: "f"): 0x0C,
            UInt8(ascii: "v"): 0x0B
        ]

        /// The byte an escape stands for, with the backslash already read.
        private mutating func escape() -> UInt8? {
            guard let byte = next else { return nil }
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") {
                var code = 0
                var digits = 0
                while digits < 3, let digit = next, digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "7") {
                    code = code * 8 + Int(digit - UInt8(ascii: "0"))
                    position += 1
                    digits += 1
                }
                return UInt8(truncatingIfNeeded: code)
            }
            position += 1
            // `\"` and `\\` stand for themselves.
            return Self.escapes[byte] ?? byte
        }
    }
}
