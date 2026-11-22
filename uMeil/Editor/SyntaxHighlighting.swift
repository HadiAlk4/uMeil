import Foundation
import SwiftTreeSitter
import TreeSitterC

/// The kinds of code the editor draws in their own color.
enum HighlightKind: String, CaseIterable, Sendable {
    case keyword
    case preprocessor
    case type
    case string
    case number
    case constant
    case function
    case comment
}

/// A stretch of text and what kind of code it is. Ranges are in UTF-16
/// units, like everything else that talks to the text view.
struct HighlightToken: Equatable, Sendable {
    let range: NSRange
    let kind: HighlightKind
}

/// Finds the highlightable parts of C source using tree-sitter.
///
/// An actor so that parsing runs off the main thread and the parser, which
/// is not thread-safe, is only ever used by one task at a time.
actor CSyntaxHighlighter {
    private let parser = Parser()
    private let query: Query

    /// Which syntax nodes get which `HighlightKind`. Capture names are the
    /// raw values of `HighlightKind`; `@plain` marks code with no color.
    ///
    /// When two patterns capture the same text, the later pattern wins, so
    /// the general rules come first and the specific ones after.
    private static let querySource = """
    (identifier) @plain

    ((identifier) @constant
     (#match? @constant "^[A-Z][A-Z\\\\d_]*$"))

    [
      "break" "case" "const" "continue" "default" "do" "else" "enum" "extern"
      "for" "goto" "if" "inline" "return" "sizeof" "static" "struct" "switch"
      "typedef" "union" "volatile" "while"
    ] @keyword

    [
      "#define" "#elif" "#else" "#endif" "#if" "#ifdef" "#ifndef" "#include"
    ] @preprocessor
    (preproc_directive) @preprocessor

    (string_literal) @string
    (system_lib_string) @string

    (null) @constant
    (true) @constant
    (false) @constant
    (number_literal) @number
    (char_literal) @number

    (type_identifier) @type
    (primitive_type) @type
    (sized_type_specifier) @type

    (call_expression
      function: (identifier) @function)
    (call_expression
      function: (field_expression
        field: (field_identifier) @function))
    (function_declarator
      declarator: (identifier) @function)
    (preproc_function_def
      name: (identifier) @function)

    (comment) @comment
    """

    init() throws {
        let language = Language(tree_sitter_c())
        try parser.setLanguage(language)
        query = try Query(language: language, data: Data(Self.querySource.utf8))
    }

    /// Parses `text` and returns its tokens, sorted by where they start
    /// (an enclosing token before the ones inside it).
    func tokens(in text: String) -> [HighlightToken] {
        guard let tree = parser.parse(text) else { return [] }

        // For each captured range, keep the capture from the latest pattern.
        var winners: [NSRange: (pattern: Int, kind: HighlightKind?)] = [:]
        let matches = query.execute(in: tree).resolve(with: Predicate.Context(string: text))
        for match in matches {
            for capture in match.captures {
                guard let name = capture.name, capture.range.length > 0 else { continue }
                if let existing = winners[capture.range], existing.pattern > match.patternIndex {
                    continue
                }
                winners[capture.range] = (match.patternIndex, HighlightKind(rawValue: name))
            }
        }

        return winners
            .compactMap { range, winner in winner.kind.map { HighlightToken(range: range, kind: $0) } }
            .sorted { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                return lhs.range.length > rhs.range.length
            }
    }
}

/// Tokens arranged so the ones touching a given range can be found quickly.
/// The editor only colors what is on screen, so this is what keeps
/// scrolling a large file cheap.
struct HighlightMap: Sendable {
    /// Sorted by start location.
    let tokens: [HighlightToken]
    /// `furthestEnds[i]` is the furthest end of any token in `tokens[0...i]`.
    /// It never decreases, which makes it searchable.
    private let furthestEnds: [Int]

    static let empty = HighlightMap(tokens: [])

    init(tokens: [HighlightToken]) {
        self.tokens = tokens
        var furthest = 0
        furthestEnds = tokens.map { token in
            furthest = max(furthest, NSMaxRange(token.range))
            return furthest
        }
    }

    /// Every token that overlaps `range`, in order.
    func tokens(intersecting range: NSRange) -> [HighlightToken] {
        let rangeEnd = NSMaxRange(range)

        // The first token that could reach into the range: everything
        // before it ends at or before the range starts.
        var low = 0
        var high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            if furthestEnds[middle] > range.location {
                high = middle
            } else {
                low = middle + 1
            }
        }

        var result: [HighlightToken] = []
        for token in tokens[low...] {
            if token.range.location >= rangeEnd { break }
            if NSMaxRange(token.range) > range.location {
                result.append(token)
            }
        }
        return result
    }
}

/// The languages the editor can highlight.
enum SourceLanguage: Equatable, Sendable {
    case c

    /// The language of a file, judged by its extension, or `nil` if the
    /// editor shows it as plain text.
    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "c", "h": self = .c
        default: return nil
        }
    }

    /// What starts a comment that runs to the end of the line.
    var lineCommentPrefix: String {
        switch self {
        case .c: "//"
        }
    }
}
