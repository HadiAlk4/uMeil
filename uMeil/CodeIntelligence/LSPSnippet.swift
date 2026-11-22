import Foundation

/// An LSP snippet such as `GPIOPinWrite(${1:uint32_t ui32Port}, ${2:uint8_t ui8Pins})`
/// turned into plain text plus the ranges the user can Tab between.
struct LSPSnippet: Equatable, Sendable {
    /// The text to insert, with every `$1`/`${1:…}` marker replaced by its placeholder text.
    var text: String
    /// The placeholder ranges in `text` (UTF-16), in Tab order.
    var placeholders: [NSRange]
    /// Where the cursor ends up after the last placeholder (`$0`), or `nil`
    /// for the end of the text.
    var finalOffset: Int?

    init(text: String, placeholders: [NSRange], finalOffset: Int?) {
        self.text = text
        self.placeholders = placeholders
        self.finalOffset = finalOffset
    }

    /// Parses the snippet syntax `clangd` uses: `$N`, `${N}`, `${N:text}`,
    /// and backslash escapes of `$`, `}` and `\`. Anything else is kept as
    /// written. When `shortenParameters` is set, a placeholder such as
    /// `uint32_t ui32Port` is shown as just `ui32Port`.
    init(parsing snippet: String, shortenParameters: Bool = true) {
        var output = ""
        var byIndex: [(index: Int, range: NSRange)] = []
        var finalOffset: Int?
        let chars = Array(snippet)
        var position = 0

        func utf16Length(_ string: String) -> Int { (string as NSString).length }

        while position < chars.count {
            let char = chars[position]
            if char == "\\", position + 1 < chars.count, "$}\\".contains(chars[position + 1]) {
                output.append(chars[position + 1])
                position += 2
                continue
            }
            guard char == "$", let parsed = Self.parseTabStop(chars, at: position) else {
                output.append(char)
                position += 1
                continue
            }
            position = parsed.end
            let shown = shortenParameters ? Self.shortParameterName(parsed.text) : parsed.text
            let start = utf16Length(output)
            output += shown
            if parsed.index == 0 {
                finalOffset = start
            } else {
                byIndex.append((parsed.index, NSRange(location: start, length: utf16Length(shown))))
            }
        }

        text = output
        placeholders = byIndex.sorted { $0.index < $1.index }.map(\.range)
        self.finalOffset = finalOffset
    }

    private struct TabStop {
        var index: Int
        var text: String
        /// The position just past the tab stop in the snippet.
        var end: Int
    }

    /// A placeholder `${N:…}` or `$N` starting at `start`, or `nil` when the
    /// `$` there is plain text.
    private static func parseTabStop(_ chars: [Character], at start: Int) -> TabStop? {
        var position = start + 1
        guard position < chars.count else { return nil }

        if chars[position] != "{" {
            guard let index = readNumber(chars, at: &position) else { return nil }
            return TabStop(index: index, text: "", end: position)
        }
        position += 1
        guard let index = readNumber(chars, at: &position), position < chars.count else { return nil }
        if chars[position] == "}" {
            return TabStop(index: index, text: "", end: position + 1)
        }
        guard chars[position] == ":" else { return nil }
        position += 1
        guard let text = readPlaceholderText(chars, at: &position) else { return nil }
        return TabStop(index: index, text: text, end: position)
    }

    private static func readNumber(_ chars: [Character], at position: inout Int) -> Int? {
        var digits = ""
        while position < chars.count, chars[position].isASCII, chars[position].isNumber {
            digits.append(chars[position])
            position += 1
        }
        return Int(digits)
    }

    /// Reads up to and past the closing `}`, or returns `nil` if there is none.
    private static func readPlaceholderText(_ chars: [Character], at position: inout Int) -> String? {
        var text = ""
        while position < chars.count, chars[position] != "}" {
            if chars[position] == "\\", position + 1 < chars.count, "$}\\".contains(chars[position + 1]) {
                text.append(chars[position + 1])
                position += 2
                continue
            }
            text.append(chars[position])
            position += 1
        }
        guard position < chars.count else { return nil }
        position += 1
        return text
    }

    /// `uint32_t ui32Port` → `ui32Port`, `const char *pcString` → `pcString`.
    /// Anything that does not end in a plain name after a type, such as a
    /// function pointer or `...`, is left as it is.
    static func shortParameterName(_ declaration: String) -> String {
        let trimmed = declaration.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, last.isLetter || last.isNumber || last == "_" else { return trimmed }
        var nameStart = trimmed.endIndex
        while nameStart > trimmed.startIndex {
            let previous = trimmed[trimmed.index(before: nameStart)]
            guard previous.isLetter || previous.isNumber || previous == "_" else { break }
            nameStart = trimmed.index(before: nameStart)
        }
        guard nameStart > trimmed.startIndex else { return trimmed }
        let separator = trimmed[trimmed.index(before: nameStart)]
        guard separator == " " || separator == "*" || separator == "&" else { return trimmed }
        return String(trimmed[nameStart...])
    }
}
