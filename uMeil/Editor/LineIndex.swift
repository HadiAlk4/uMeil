import Foundation

/// Maps between line numbers and character offsets in a piece of text.
///
/// Offsets are UTF-16 code units, the same units `NSTextView` and `NSRange`
/// use. Line numbers start at 1. A line ends at `\n`, so `\r\n` endings work.
struct LineIndex: Equatable {
    /// The offset at which each line starts. Never empty: line 1 starts at 0.
    private let lineStarts: [Int]
    /// Where each line's text ends, before its `\n` or `\r\n`.
    private let contentEnds: [Int]
    /// The length of the whole text.
    let length: Int

    init(_ text: String) {
        var starts = [0]
        var ends: [Int] = []
        var offset = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == 0x0A {
                ends.append(previous == 0x0D ? offset - 1 : offset)
                starts.append(offset + 1)
            }
            offset += 1
            previous = unit
        }
        ends.append(offset)
        lineStarts = starts
        contentEnds = ends
        length = offset
    }

    /// The number of lines. Empty text has one (empty) line, and text that
    /// ends with a newline has an empty last line, as editors show it.
    var lineCount: Int { lineStarts.count }

    /// The line that contains `offset`. Offsets past the end count as the last line.
    func lineNumber(atOffset offset: Int) -> Int {
        // Binary search for the last line start that is <= offset.
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low + 1
    }

    /// Where `line` starts, or `nil` if there is no such line.
    func offset(ofLine line: Int) -> Int? {
        guard line >= 1, line <= lineStarts.count else { return nil }
        return lineStarts[line - 1]
    }

    /// The range of `line`, including its line ending if it has one.
    func range(ofLine line: Int) -> NSRange? {
        guard let start = offset(ofLine: line) else { return nil }
        let end = line < lineStarts.count ? lineStarts[line] : length
        return NSRange(location: start, length: end - start)
    }

    /// The offset of a 1-based line and column, as compilers report them.
    /// Columns past the end of the line are clamped to the line's end.
    func offset(line: Int, column: Int) -> Int? {
        guard let start = offset(ofLine: line) else { return nil }
        return min(start + max(column - 1, 0), contentEnds[line - 1])
    }
}
