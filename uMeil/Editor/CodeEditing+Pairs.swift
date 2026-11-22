import Foundation

/// The closing brackets and quotes the editor put in by itself, which
/// typing can step over and Backspace can remove with their opener.
/// Offsets follow the text as it changes, and are forgotten once the
/// cursor leaves the line or goes past them.
struct AutoClosedPairs: Equatable, Sendable {
    private(set) var offsets: Set<Int> = []

    func contains(_ offset: Int) -> Bool {
        offsets.contains(offset)
    }

    mutating func insert(_ offset: Int) {
        offsets.insert(offset)
    }

    mutating func remove(_ offset: Int) {
        offsets.remove(offset)
    }

    mutating func removeAll() {
        offsets.removeAll()
    }

    /// Moves the offsets along with an edit that replaced `range` with
    /// `replacementLength` characters. Closers that were replaced are forgotten.
    mutating func textChanged(in range: NSRange, replacementLength: Int) {
        let delta = replacementLength - range.length
        offsets = Set(offsets.compactMap { offset in
            if offset < range.location { return offset }
            if offset >= NSMaxRange(range) { return offset + delta }
            return nil
        })
    }

    /// Keeps only closers still ahead of the cursor on its line.
    mutating func cursorMoved(to cursor: Int, lineEnd: Int) {
        offsets = offsets.filter { $0 >= cursor && $0 < lineEnd }
    }
}

// MARK: - Bracket and quote pairs

extension CodeEditing {
    /// What typing a bracket or quote does.
    enum PairAction: Equatable {
        /// Move the cursor past the closer already at the cursor.
        case stepOver
        /// Make `edit`, which puts in a closer at `closer` too.
        case insertPair(TextEdit, closer: Int)
    }

    static let closers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]

    /// Typing `typed` with `autoClosed` closers ahead: step over a matching
    /// closer the editor added, or add a closer after an opening bracket or
    /// quote. `nil` to type the character as usual. Brackets typed inside
    /// strings and comments, or right before other text, are not paired.
    static func pairAction(
        for typed: Character,
        in text: NSString,
        selection: NSRange,
        autoClosed: AutoClosedPairs
    ) -> PairAction? {
        guard selection.length == 0 else { return nil }
        let caret = selection.location
        let next: Character? = caret < text.length ? character(at: caret, in: text) : nil

        if next == typed, autoClosed.contains(caret), closers.values.contains(typed) {
            return .stepOver
        }
        guard let closer = closers[typed],
              next.map({ $0.isWhitespace || ")]};,".contains($0) }) ?? true,
              CodeScan(text, upTo: caret).context == .code
        else { return nil }

        if typed == "\"" || typed == "'" {
            // After a letter or digit a quote is more likely an apostrophe or
            // the end of something, and after a backslash it is escaped.
            let previous: Character? = caret > 0 ? character(at: caret - 1, in: text) : nil
            if let previous, previous.isLetter || previous.isNumber || previous == "_" || previous == "\\" {
                return nil
            }
        }

        let edit = TextEdit(
            range: selection,
            replacement: String([typed, closer]),
            selection: NSRange(location: caret + 1, length: 0)
        )
        return .insertPair(edit, closer: caret + 1)
    }

    /// Backspace between an opener and the closer the editor added for it:
    /// both go.
    static func deletePair(in text: NSString, selection: NSRange, autoClosed: AutoClosedPairs) -> TextEdit? {
        let caret = selection.location
        guard selection.length == 0, caret > 0, caret < text.length, autoClosed.contains(caret),
              let closer = closers[character(at: caret - 1, in: text)],
              character(at: caret, in: text) == closer
        else { return nil }
        let range = NSRange(location: caret - 1, length: 2)
        return TextEdit(range: range, replacement: "", selection: NSRange(location: caret - 1, length: 0))
    }

    private static func character(at offset: Int, in text: NSString) -> Character {
        Character(UnicodeScalar(text.character(at: offset)) ?? " ")
    }
}
