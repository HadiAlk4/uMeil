import Foundation

// MARK: - Return and closing braces

extension CodeEditing {
    /// Return: a new line indented like the one before it, one level more
    /// after a `{`. Return between `{` and `}` puts the cursor on an
    /// indented line of its own with the `}` on the line after.
    ///
    /// Spaces left at the end of the line being finished are removed, and so
    /// are spaces after the cursor, which would otherwise push the text
    /// carried to the new line past its indentation.
    static func newline(in text: NSString, selection: NSRange, style: IndentStyle) -> TextEdit {
        let caret = selection.location
        let start = lineStart(in: text, at: caret)
        let indentLength = whitespaceLength(in: text, from: start, limit: caret)
        let indent = text.substring(with: NSRange(location: start, length: indentLength))

        // The end of what is before the cursor, ignoring trailing spaces.
        var contentEnd = caret
        while contentEnd > start, isHorizontalSpace(text.character(at: contentEnd - 1)) {
            contentEnd -= 1
        }
        let opensBlock = contentEnd > start
            && text.character(at: contentEnd - 1) == openBrace
            && CodeScan(text, upTo: contentEnd - 1).context == .code

        let selectionEnd = NSMaxRange(selection)
        let afterStart = selectionEnd + whitespaceLength(
            in: text,
            from: selectionEnd,
            limit: lineEnd(in: text, at: selectionEnd)
        )
        let closesBlock = afterStart < text.length && text.character(at: afterStart) == closeBrace

        // Only indentation before the cursor: the line moves down as it is,
        // leaving an empty line above rather than one holding spaces.
        if contentEnd == start, selection.length == 0 {
            return TextEdit(
                range: NSRange(location: start, length: 0),
                replacement: "\n",
                selection: NSRange(location: caret + 1, length: 0)
            )
        }

        let range = NSRange(location: contentEnd, length: afterStart - contentEnd)
        let innerIndent = opensBlock ? indent + style.unit : indent
        var replacement = "\n" + innerIndent
        let caretAfter = contentEnd + (replacement as NSString).length
        if opensBlock && closesBlock {
            replacement += "\n" + indent
        }
        return TextEdit(range: range, replacement: replacement, selection: NSRange(location: caretAfter, length: 0))
    }

    /// Typing `}` at the start of a line: the line is indented to match the
    /// line with the `{` it closes, or one level less when that cannot be
    /// found. `nil` when the line is already right, or `}` goes elsewhere.
    static func closingBrace(in text: NSString, selection: NSRange, style: IndentStyle) -> TextEdit? {
        let caret = selection.location
        let start = lineStart(in: text, at: caret)
        let before = NSRange(location: start, length: caret - start)
        guard whitespaceLength(in: text, from: start, limit: caret) == before.length else { return nil }

        let scan = CodeScan(text, upTo: start)
        guard scan.context == .code else { return nil }
        let current = text.substring(with: before)
        let indent: String
        if let open = scan.openBraces.last {
            indent = indentation(ofLineAt: open, in: text)
        } else {
            indent = outdented(current, style: style)
        }

        let range = NSRange(location: start, length: NSMaxRange(selection) - start)
        let replacement = indent + "}"
        guard indent != current || selection.length > 0 else { return nil }
        let caretAfter = start + (replacement as NSString).length
        return TextEdit(range: range, replacement: replacement, selection: NSRange(location: caretAfter, length: 0))
    }

    /// `indentation` with one level taken off the end.
    static func outdented(_ indentation: String, style: IndentStyle) -> String {
        if indentation.hasSuffix("\t") { return String(indentation.dropLast()) }
        let trailingSpaces = indentation.reversed().prefix { $0 == " " }.count
        let remove = min(trailingSpaces, style.width)
        return String(indentation.dropLast(remove))
    }

    static let openBrace = unichar(UInt8(ascii: "{"))
    static let closeBrace = unichar(UInt8(ascii: "}"))
}
