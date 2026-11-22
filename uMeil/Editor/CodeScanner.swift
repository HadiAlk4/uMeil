import Foundation

/// What kind of C text an offset falls in.
enum CodeContext: Equatable, Sendable {
    case code
    case string
    case character
    case lineComment
    case blockComment
}

/// A quick pass over C source, enough for the typing aids: whether the
/// cursor is in code or inside a string or comment, and which `{` braces
/// before it are still open.
///
/// This runs on every relevant keystroke, so it reads the text directly
/// rather than waiting for the syntax highlighter, which runs a moment after
/// typing stops and so can be out of date.
struct CodeScan: Equatable, Sendable {
    /// What the text at the end of the scan is.
    var context: CodeContext
    /// The offsets of `{` braces in code that are not closed yet, innermost last.
    var openBraces: [Int]

    /// Scans `text` from the start up to `end`.
    init(_ text: NSString, upTo end: Int) {
        let end = min(max(end, 0), text.length)
        var characters = [unichar](repeating: 0, count: end)
        text.getCharacters(&characters, range: NSRange(location: 0, length: end))

        var context = CodeContext.code
        var openBraces: [Int] = []
        var index = 0
        while index < end {
            let character = characters[index]
            if context == .code, character == Self.openBrace {
                openBraces.append(index)
            } else if context == .code, character == Self.closeBrace {
                _ = openBraces.popLast()
            }
            let next: unichar? = index + 1 < end ? characters[index + 1] : nil
            let step = Self.step(from: context, at: character, next: next)
            context = step.context
            index += step.length
        }
        self.context = context
        self.openBraces = openBraces
    }

    /// What the text is after `character`, and how many characters that
    /// used up: two for `//`, `/*`, `*/` and escapes, otherwise one.
    private static func step(
        from context: CodeContext,
        at character: unichar,
        next: unichar?
    ) -> (context: CodeContext, length: Int) {
        switch context {
        case .code:
            return stepInCode(at: character, next: next)
        case .string, .character:
            let quote = context == .string ? doubleQuote : singleQuote
            if character == backslash { return (context, 2) }
            // A line break ends a string that was never closed.
            if character == quote || character == newline { return (.code, 1) }
            return (context, 1)
        case .lineComment:
            return (character == newline ? .code : .lineComment, 1)
        case .blockComment:
            if character == star, next == slash { return (.code, 2) }
            return (.blockComment, 1)
        }
    }

    private static func stepInCode(at character: unichar, next: unichar?) -> (context: CodeContext, length: Int) {
        switch character {
        case slash where next == slash: (.lineComment, 2)
        case slash where next == star: (.blockComment, 2)
        case doubleQuote: (.string, 1)
        case singleQuote: (.character, 1)
        default: (.code, 1)
        }
    }

    private static let slash = unichar(UInt8(ascii: "/"))
    private static let star = unichar(UInt8(ascii: "*"))
    private static let backslash = unichar(UInt8(ascii: "\\"))
    private static let doubleQuote = unichar(UInt8(ascii: "\""))
    private static let singleQuote = unichar(UInt8(ascii: "'"))
    private static let openBrace = unichar(UInt8(ascii: "{"))
    private static let closeBrace = unichar(UInt8(ascii: "}"))
    private static let newline = unichar(UInt8(ascii: "\n"))
}
