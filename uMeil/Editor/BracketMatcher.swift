import Foundation

/// Finds the matching `()`, `[]`, or `{}` bracket adjacent to a UTF-16 cursor
/// offset.
///
/// In `.c` mode, brackets inside `//` comments, `/* */` comments, `"..."`
/// string literals, and `'...'` character literals (including backslash
/// escapes) are ignored so they never pair with real code brackets.
/// In `.plainText` mode, every bracket character is matched directly.
enum BracketMatcher {
    enum Mode: Equatable, Sendable {
        case c
        case plainText
    }

    struct Match: Equatable, Sendable {
        /// UTF-16 offset of the bracket adjacent to the cursor.
        let anchorOffset: Int
        /// UTF-16 offset of its matching counterpart bracket.
        let matchOffset: Int
    }

    private struct Token {
        let offset: Int
        let unit: UInt16
    }

    private static let openParen: UInt16 = 0x28     // (
    private static let closeParen: UInt16 = 0x29    // )
    private static let openBracket: UInt16 = 0x5B   // [
    private static let closeBracket: UInt16 = 0x5D  // ]
    private static let openBrace: UInt16 = 0x7B     // {
    private static let closeBrace: UInt16 = 0x7D    // }

    private static let slash: UInt16 = 0x2F         // /
    private static let star: UInt16 = 0x2A          // *
    private static let doubleQuote: UInt16 = 0x22   // "
    private static let singleQuote: UInt16 = 0x27   // '
    private static let backslash: UInt16 = 0x5C     // \
    private static let newline: UInt16 = 0x0A       // \n
    private static let carriageReturn: UInt16 = 0x0D // \r

    /// Uses C-aware scanning for `.c`/`.h` files and plain-text scanning
    /// for everything else.
    static func mode(for url: URL?) -> Mode {
        url.flatMap(SourceLanguage.init(url:)) == .c ? .c : .plainText
    }

    /// True when `string` is a single closing bracket (`)`, `]`, or `}`).
    static func isClosingBracket(_ string: String) -> Bool {
        string == ")" || string == "]" || string == "}"
    }

    static func isBracket(_ unit: UInt16) -> Bool {
        counterpart(for: unit) != nil
    }

    static func isOpeningBracket(_ unit: UInt16) -> Bool {
        unit == openParen || unit == openBracket || unit == openBrace
    }

    static func isClosingBracket(_ unit: UInt16) -> Bool {
        unit == closeParen || unit == closeBracket || unit == closeBrace
    }

    static func counterpart(for unit: UInt16) -> UInt16? {
        switch unit {
        case openParen: closeParen
        case closeParen: openParen
        case openBracket: closeBracket
        case closeBracket: openBracket
        case openBrace: closeBrace
        case closeBrace: openBrace
        default: nil
        }
    }

    /// Checks the character immediately before `cursor` (`cursor - 1`) first;
    /// if that is not an active bracket, checks the character at `cursor`.
    static func match(in text: String, cursor: Int, mode: Mode = .c) -> Match? {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0, cursor >= 0, cursor <= length else { return nil }

        // Fast path: most cursor positions are not adjacent to any bracket.
        let beforeIsBracket = cursor > 0 && isBracket(nsText.character(at: cursor - 1))
        let atIsBracket = cursor < length && isBracket(nsText.character(at: cursor))
        guard beforeIsBracket || atIsBracket else { return nil }

        let units = Array(text.utf16)
        let tokens = activeBrackets(in: units, mode: mode)
        guard !tokens.isEmpty else { return nil }

        if beforeIsBracket, let anchorIndex = tokenIndex(atOffset: cursor - 1, in: tokens) {
            return matchFrom(anchorIndex: anchorIndex, in: tokens)
        }
        if atIsBracket, let anchorIndex = tokenIndex(atOffset: cursor, in: tokens) {
            return matchFrom(anchorIndex: anchorIndex, in: tokens)
        }
        return nil
    }

    // MARK: - Lexing

    private static func activeBrackets(in units: [UInt16], mode: Mode) -> [Token] {
        switch mode {
        case .plainText:
            return plainTextBrackets(in: units)
        case .c:
            return cCodeBrackets(in: units)
        }
    }

    private static func plainTextBrackets(in units: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        for index in units.indices where isBracket(units[index]) {
            tokens.append(Token(offset: index, unit: units[index]))
        }
        return tokens
    }

    private static func cCodeBrackets(in units: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        let count = units.count
        var index = 0

        while index < count {
            let unit = units[index]
            if unit == slash, index + 1 < count {
                let next = units[index + 1]
                if next == slash {
                    index = skipLineComment(in: units, from: index + 2)
                    continue
                }
                if next == star {
                    index = skipBlockComment(in: units, from: index + 2)
                    continue
                }
            }
            if unit == doubleQuote || unit == singleQuote {
                index = skipQuotedLiteral(in: units, from: index + 1, delimiter: unit)
                continue
            }
            if isBracket(unit) {
                tokens.append(Token(offset: index, unit: unit))
            }
            index += 1
        }
        return tokens
    }

    private static func skipLineComment(in units: [UInt16], from start: Int) -> Int {
        let count = units.count
        var index = start
        while index < count {
            if units[index] == backslash {
                if index + 1 < count, units[index + 1] == newline {
                    index += 2
                    continue
                }
                if index + 2 < count, units[index + 1] == carriageReturn, units[index + 2] == newline {
                    index += 3
                    continue
                }
            }
            if units[index] == newline {
                return index + 1
            }
            index += 1
        }
        return count
    }

    private static func skipBlockComment(in units: [UInt16], from start: Int) -> Int {
        let count = units.count
        var index = start
        while index < count {
            if units[index] == star, index + 1 < count, units[index + 1] == slash {
                return index + 2
            }
            index += 1
        }
        return count
    }

    private static func skipQuotedLiteral(in units: [UInt16], from start: Int, delimiter: UInt16) -> Int {
        let count = units.count
        var index = start
        while index < count {
            let unit = units[index]
            if unit == backslash {
                if index + 2 < count, units[index + 1] == carriageReturn, units[index + 2] == newline {
                    index += 3
                } else {
                    index = min(index + 2, count)
                }
                continue
            }
            if unit == delimiter || unit == newline {
                return index + 1
            }
            index += 1
        }
        return count
    }

    // MARK: - Matching

    private static func tokenIndex(atOffset offset: Int, in tokens: [Token]) -> Int? {
        var low = 0
        var high = tokens.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let current = tokens[middle].offset
            if current == offset { return middle }
            if current < offset {
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return nil
    }

    private static func matchFrom(anchorIndex: Int, in tokens: [Token]) -> Match? {
        let anchor = tokens[anchorIndex]
        guard let initialExpected = counterpart(for: anchor.unit) else { return nil }
        var expected = [initialExpected]

        if isOpeningBracket(anchor.unit) {
            for index in (anchorIndex + 1)..<tokens.count {
                let token = tokens[index]
                if isOpeningBracket(token.unit), let closer = counterpart(for: token.unit) {
                    expected.append(closer)
                } else {
                    guard expected.last == token.unit else { return nil }
                    expected.removeLast()
                    if expected.isEmpty {
                        return Match(anchorOffset: anchor.offset, matchOffset: token.offset)
                    }
                }
            }
            return nil
        }

        for index in stride(from: anchorIndex - 1, through: 0, by: -1) {
            let token = tokens[index]
            if isClosingBracket(token.unit), let opener = counterpart(for: token.unit) {
                expected.append(opener)
            } else {
                guard expected.last == token.unit else { return nil }
                expected.removeLast()
                if expected.isEmpty {
                    return Match(anchorOffset: anchor.offset, matchOffset: token.offset)
                }
            }
        }
        return nil
    }
}
