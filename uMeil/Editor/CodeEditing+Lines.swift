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

// MARK: - Commenting lines

extension CodeEditing {
    /// Comments out the selected lines with `prefix` (such as `//`), or
    /// uncomments them if every one is already commented. Blank lines are
    /// skipped, unless only blank lines are selected. `// ` goes in at the
    /// smallest indentation of the lines, so they stay lined up.
    static func toggleLineComment(in text: NSString, selection: NSRange, prefix: String) -> TextEdit? {
        let lines = lines(in: text, coveredBy: selection)
        let filled = lines.filter { !isBlank($0, in: text) }
        let targets = filled.isEmpty ? lines : filled
        let prefixLength = (prefix as NSString).length

        let indents = targets.map { whitespaceLength(in: text, from: $0.location, limit: NSMaxRange($0)) }
        let commented = zip(targets, indents).allSatisfy { line, indent in
            indent + prefixLength <= line.length
                && text.substring(with: NSRange(location: line.location + indent, length: prefixLength)) == prefix
        }

        let changes: [LineChange]
        if commented && !filled.isEmpty {
            changes = zip(targets, indents).map { line, indent in
                let start = line.location + indent
                let afterPrefix = start + prefixLength
                let space = afterPrefix < NSMaxRange(line) && text.character(at: afterPrefix) == Self.space ? 1 : 0
                return LineChange(location: start, deleteLength: prefixLength + space)
            }
        } else {
            let column = indents.min() ?? 0
            changes = targets.map { LineChange(location: $0.location + column, insertion: prefix + " ") }
        }
        return edit(applying: changes, to: lines, in: text, selection: selection)
    }
}
