import Foundation

// MARK: - Shifting lines

extension CodeEditing {
    enum ShiftDirection {
        case right
        case left
    }

    /// Indents or outdents every line the selection touches by one level.
    /// Empty lines are left empty. `nil` when there is nothing to outdent.
    static func shiftLines(
        in text: NSString,
        selection: NSRange,
        style: IndentStyle,
        direction: ShiftDirection
    ) -> TextEdit? {
        let lines = lines(in: text, coveredBy: selection)
        let changes: [LineChange] = lines.compactMap { line in
            switch direction {
            case .right:
                return line.length == 0 ? nil : LineChange(location: line.location, insertion: style.unit)
            case .left:
                let remove = outdentLength(of: line, in: text, style: style)
                return remove == 0 ? nil : LineChange(location: line.location, deleteLength: remove)
            }
        }
        return edit(applying: changes, to: lines, in: text, selection: selection)
    }

    /// How much one level less indentation takes off the start of `line`:
    /// a tab, or up to a level's worth of spaces.
    private static func outdentLength(of line: NSRange, in text: NSString, style: IndentStyle) -> Int {
        guard line.length > 0 else { return 0 }
        if text.character(at: line.location) == tab { return 1 }
        var count = 0
        while count < min(style.width, line.length), text.character(at: line.location + count) == space {
            count += 1
        }
        return count
    }
}
