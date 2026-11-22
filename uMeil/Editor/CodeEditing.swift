import Foundation

/// What one level of indentation is: a tab, or a number of spaces.
struct IndentStyle: Equatable, Sendable {
    var usesSpaces: Bool
    /// How many columns one level is, and how wide a tab is drawn.
    var width: Int

    static let fourSpaces = IndentStyle(usesSpaces: true, width: 4)
    static let tabs = IndentStyle(usesSpaces: false, width: 4)

    /// The text for one level of indentation.
    var unit: String {
        usesSpaces ? String(repeating: " ", count: width) : "\t"
    }

    /// The column `text` ends at when it starts at column 0, with each tab
    /// reaching the next tab stop.
    func column(after text: some StringProtocol) -> Int {
        var column = 0
        for character in text {
            column = character == "\t" ? (column / width + 1) * width : column + 1
        }
        return column
    }

    /// What Tab inserts at `column`: spaces up to the next tab stop, or a tab.
    func indentation(fromColumn column: Int) -> String {
        usesSpaces ? String(repeating: " ", count: width - column % width) : "\t"
    }
}

/// One change to the editor's text: replace `range` with `replacement`,
/// then select `selection`. Ranges are in UTF-16 units, like the text view's.
struct TextEdit: Equatable, Sendable {
    var range: NSRange
    var replacement: String
    var selection: NSRange
}

/// The editing help the code editor gives while typing: indentation,
/// comments, and bracket pairs. Each function looks at the text and the
/// selection and returns the edit to make, so it can be tested without a
/// text view. `nil` means the key should do what it normally does.
enum CodeEditing {}

// MARK: - Lines

extension CodeEditing {
    static let tab: unichar = 0x09
    static let newline: unichar = 0x0A
    static let space: unichar = 0x20

    static func isHorizontalSpace(_ character: unichar) -> Bool {
        character == space || character == tab
    }

    /// The start of the line holding `offset`.
    static func lineStart(in text: NSString, at offset: Int) -> Int {
        text.lineRange(for: NSRange(location: offset, length: 0)).location
    }

    /// Where the line holding `offset` ends, before its line break.
    static func lineEnd(in text: NSString, at offset: Int) -> Int {
        var end = 0
        text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: offset, length: 0))
        return end
    }

    /// How many spaces and tabs `text` starts with, from `start`, stopping at `limit`.
    static func whitespaceLength(in text: NSString, from start: Int, limit: Int? = nil) -> Int {
        let end = min(limit ?? text.length, text.length)
        var index = start
        while index < end, isHorizontalSpace(text.character(at: index)) {
            index += 1
        }
        return index - start
    }

    /// The spaces and tabs at the start of the line holding `offset`.
    static func indentation(ofLineAt offset: Int, in text: NSString) -> String {
        let start = lineStart(in: text, at: offset)
        let length = whitespaceLength(in: text, from: start, limit: lineEnd(in: text, at: offset))
        return text.substring(with: NSRange(location: start, length: length))
    }

    /// The lines a selection touches, as ranges without their line breaks.
    /// A selection that ends at the very start of a line does not include
    /// that line, so selecting whole lines by dragging works as expected.
    static func lines(in text: NSString, coveredBy selection: NSRange) -> [NSRange] {
        var last = NSMaxRange(selection)
        if selection.length > 0, last > 0, text.character(at: last - 1) == newline {
            last -= 1
        }
        var lines: [NSRange] = []
        var start = lineStart(in: text, at: selection.location)
        while true {
            var next = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &next, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            lines.append(NSRange(location: start, length: contentsEnd - start))
            // The last line has no line break after it.
            guard next > contentsEnd, next <= last else { break }
            start = next
        }
        return lines
    }

    /// Whether a line holds nothing but spaces and tabs.
    static func isBlank(_ line: NSRange, in text: NSString) -> Bool {
        whitespaceLength(in: text, from: line.location, limit: NSMaxRange(line)) == line.length
    }
}

// MARK: - Editing several lines at once

extension CodeEditing {
    /// A change inside one line: delete `deleteLength` characters at
    /// `location`, and put `insertion` there.
    struct LineChange: Equatable {
        var location: Int
        var deleteLength = 0
        var insertion = ""
    }

    /// Makes `changes` (in order, not overlapping) into one edit covering
    /// `lines`, moving the selection along with the text around it.
    static func edit(
        applying changes: [LineChange],
        to lines: [NSRange],
        in text: NSString,
        selection: NSRange
    ) -> TextEdit? {
        guard let first = lines.first, let last = lines.last,
              changes.contains(where: { $0.deleteLength > 0 || !$0.insertion.isEmpty })
        else { return nil }
        let block = NSRange(location: first.location, length: NSMaxRange(last) - first.location)

        var replacement = ""
        var cursor = block.location
        for change in changes {
            replacement += text.substring(with: NSRange(location: cursor, length: change.location - cursor))
            replacement += change.insertion
            cursor = change.location + change.deleteLength
        }
        replacement += text.substring(with: NSRange(location: cursor, length: NSMaxRange(block) - cursor))

        // Where an old offset ends up. A selection's start stays before text
        // inserted right at it, so whole selected lines stay selected; its
        // end, and a lone cursor, move past it.
        func moved(_ offset: Int, pastInsertions: Bool) -> Int {
            var delta = 0
            for change in changes {
                guard change.location < offset || pastInsertions && change.location == offset else { break }
                let inserted = (change.insertion as NSString).length
                if offset < change.location + change.deleteLength {
                    return change.location + delta + inserted
                }
                delta += inserted - change.deleteLength
            }
            return offset + delta
        }

        let newSelection: NSRange
        if selection.length == 0 {
            newSelection = NSRange(location: moved(selection.location, pastInsertions: true), length: 0)
        } else {
            let start = moved(selection.location, pastInsertions: false)
            let end = moved(NSMaxRange(selection), pastInsertions: true)
            newSelection = NSRange(location: start, length: max(end - start, 0))
        }
        return TextEdit(range: block, replacement: replacement, selection: newSelection)
    }
}

// MARK: - Tab and Backspace

extension CodeEditing {
    /// Tab with nothing selected: indentation up to the next tab stop.
    static func tab(in text: NSString, selection: NSRange, style: IndentStyle) -> TextEdit {
        let start = lineStart(in: text, at: selection.location)
        let before = text.substring(with: NSRange(location: start, length: selection.location - start))
        let insertion = style.indentation(fromColumn: style.column(after: before))
        let caret = selection.location + (insertion as NSString).length
        return TextEdit(range: selection, replacement: insertion, selection: NSRange(location: caret, length: 0))
    }

    /// Backspace in the spaces that indent a line: back to the previous tab
    /// stop, so spaces delete like a tab would.
    static func deleteIndentation(in text: NSString, selection: NSRange, style: IndentStyle) -> TextEdit? {
        guard style.usesSpaces, selection.length == 0, selection.location > 0 else { return nil }
        let start = lineStart(in: text, at: selection.location)
        let before = NSRange(location: start, length: selection.location - start)
        guard before.length > 0,
              text.substring(with: before).allSatisfy({ $0 == " " })
        else { return nil }
        let remove = (before.length - 1) % style.width + 1
        guard remove > 1 else { return nil }
        let range = NSRange(location: selection.location - remove, length: remove)
        return TextEdit(range: range, replacement: "", selection: NSRange(location: range.location, length: 0))
    }
}
