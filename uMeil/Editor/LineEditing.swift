import Foundation

/// A single atomic text edit produced by a line-editing operation, expressed in
/// UTF-16 code units to match `NSTextView` and `NSRange`.
struct LineEditResult: Equatable {
    /// The range in the original text that should be replaced.
    let affectedRange: NSRange
    /// The text that replaces `affectedRange`.
    let replacement: String
    /// The selection range to restore after applying the edit.
    let newSelection: NSRange

    /// Returns the result of applying this edit to `text`.
    func applying(to text: String) -> String {
        (text as NSString).replacingCharacters(in: affectedRange, with: replacement)
    }
}

/// Pure line-editing transformations (`⌥↑`, `⌥↓`, `⇧⌥↓`).
enum LineEditing {
    private struct LineSpan {
        /// UTF-16 start offset of the line.
        let start: Int
        /// UTF-16 offset right before the line's ending (`\n` or `\r\n`), or `end` if none.
        let contentEnd: Int
        /// UTF-16 offset immediately after the line's ending (or the end of the text).
        let end: Int

        var contentLength: Int { contentEnd - start }
        var lineBreakLength: Int { end - contentEnd }
    }

    /// Moves the current line — or all lines touched by a multi-line selection —
    /// up by one line, preserving the relative cursor/selection offset.
    /// Returns `nil` when the selection already starts on the first line.
    static func moveLinesUp(in text: String, selection: NSRange) -> LineEditResult? {
        let nsText = text as NSString
        let lines = splitLines(in: nsText)
        let clamped = clamp(selection, length: nsText.length)
        let (firstIndex, lastIndex) = selectedLineRange(in: lines, selection: clamped)
        guard firstIndex > 0 else { return nil }

        let above = lines[firstIndex - 1]
        let blockFirst = lines[firstIndex]
        let blockLast = lines[lastIndex]

        let aboveContent = substring(nsText, from: above.start, to: above.contentEnd)
        let aboveBreak = substring(nsText, from: above.contentEnd, to: above.end)
        let blockContent = substring(nsText, from: blockFirst.start, to: blockLast.contentEnd)
        let blockTrailingBreak = substring(nsText, from: blockLast.contentEnd, to: blockLast.end)

        let affectedRange = NSRange(location: above.start, length: blockLast.end - above.start)
        let replacement = blockContent + aboveBreak + aboveContent + blockTrailingBreak

        let blockContentLength = blockLast.contentEnd - blockFirst.start
        let newBlockMaxOffset = blockContentLength + above.lineBreakLength
        let newSelection = relocatedSelection(
            clamped,
            fromBlockStart: blockFirst.start,
            toBlockStart: above.start,
            maxRelativeOffset: newBlockMaxOffset
        )

        return LineEditResult(
            affectedRange: affectedRange,
            replacement: replacement,
            newSelection: newSelection
        )
    }

    /// Moves the current line — or all lines touched by a multi-line selection —
    /// down by one line, preserving the relative cursor/selection offset.
    /// Returns `nil` when the selection already reaches the last line.
    static func moveLinesDown(in text: String, selection: NSRange) -> LineEditResult? {
        let nsText = text as NSString
        let lines = splitLines(in: nsText)
        let clamped = clamp(selection, length: nsText.length)
        let (firstIndex, lastIndex) = selectedLineRange(in: lines, selection: clamped)
        guard lastIndex < lines.count - 1 else { return nil }

        let blockFirst = lines[firstIndex]
        let blockLast = lines[lastIndex]
        let below = lines[lastIndex + 1]

        let blockContent = substring(nsText, from: blockFirst.start, to: blockLast.contentEnd)
        let blockTrailingBreak = substring(nsText, from: blockLast.contentEnd, to: blockLast.end)
        let belowContent = substring(nsText, from: below.start, to: below.contentEnd)
        let belowBreak = substring(nsText, from: below.contentEnd, to: below.end)

        let affectedRange = NSRange(location: blockFirst.start, length: below.end - blockFirst.start)
        let replacement = belowContent + blockTrailingBreak + blockContent + belowBreak

        let newBlockStart = blockFirst.start + below.contentLength + blockLast.lineBreakLength
        let blockContentLength = blockLast.contentEnd - blockFirst.start
        let newBlockMaxOffset = blockContentLength + below.lineBreakLength
        let newSelection = relocatedSelection(
            clamped,
            fromBlockStart: blockFirst.start,
            toBlockStart: newBlockStart,
            maxRelativeOffset: newBlockMaxOffset
        )

        return LineEditResult(
            affectedRange: affectedRange,
            replacement: replacement,
            newSelection: newSelection
        )
    }

    /// Duplicates the current line — or all lines touched by a multi-line selection —
    /// directly below, moving the cursor/selection to the matching position in the copy.
    static func duplicateLinesDown(in text: String, selection: NSRange) -> LineEditResult {
        let nsText = text as NSString
        let lines = splitLines(in: nsText)
        let clamped = clamp(selection, length: nsText.length)
        let (firstIndex, lastIndex) = selectedLineRange(in: lines, selection: clamped)

        let blockFirst = lines[firstIndex]
        let blockLast = lines[lastIndex]
        let blockContent = substring(nsText, from: blockFirst.start, to: blockLast.contentEnd)
        let blockTrailingBreak = substring(nsText, from: blockLast.contentEnd, to: blockLast.end)

        let affectedRange = NSRange(location: blockLast.end, length: 0)
        let replacement: String
        let newBlockStart: Int

        if !blockTrailingBreak.isEmpty {
            replacement = blockContent + blockTrailingBreak
            newBlockStart = blockLast.end
        } else {
            let separator: String
            if firstIndex > 0 {
                let previous = lines[firstIndex - 1]
                separator = substring(nsText, from: previous.contentEnd, to: previous.end)
            } else {
                separator = "\n"
            }
            replacement = separator + blockContent
            newBlockStart = blockLast.end + (separator as NSString).length
        }

        let newBlockMaxOffset = (blockLast.contentEnd - blockFirst.start) + blockLast.lineBreakLength
        let newSelection = relocatedSelection(
            clamped,
            fromBlockStart: blockFirst.start,
            toBlockStart: newBlockStart,
            maxRelativeOffset: newBlockMaxOffset
        )

        return LineEditResult(
            affectedRange: affectedRange,
            replacement: replacement,
            newSelection: newSelection
        )
    }

    // MARK: - Line splitting helpers

    private static func splitLines(in nsText: NSString) -> [LineSpan] {
        let length = nsText.length
        var lines: [LineSpan] = []
        var lineStart = 0
        var index = 0

        while index < length {
            if nsText.character(at: index) == 0x0A {
                let contentEnd = (index > lineStart && nsText.character(at: index - 1) == 0x0D)
                    ? index - 1
                    : index
                lines.append(LineSpan(start: lineStart, contentEnd: contentEnd, end: index + 1))
                lineStart = index + 1
            }
            index += 1
        }
        // Final line (either text without a trailing newline, or the empty line after one).
        lines.append(LineSpan(start: lineStart, contentEnd: length, end: length))
        return lines
    }

    private static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let start = min(max(range.location, 0), length)
        let end = min(max(NSMaxRange(range), start), length)
        return NSRange(location: start, length: end - start)
    }

    private static func selectedLineRange(in lines: [LineSpan], selection: NSRange) -> (Int, Int) {
        let first = lineIndex(in: lines, atOffset: selection.location)
        if selection.length == 0 {
            return (first, first)
        }
        // A selection ending right after `\n` (at column 0 of the next line)
        // belongs to the line ending with that `\n`, not the line below it.
        let last = lineIndex(in: lines, atOffset: NSMaxRange(selection) - 1)
        return (first, last)
    }

    private static func lineIndex(in lines: [LineSpan], atOffset offset: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].start <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    private static func relocatedSelection(
        _ selection: NSRange,
        fromBlockStart oldStart: Int,
        toBlockStart newStart: Int,
        maxRelativeOffset: Int
    ) -> NSRange {
        let relativeStart = min(max(selection.location - oldStart, 0), maxRelativeOffset)
        let relativeEnd = min(max(NSMaxRange(selection) - oldStart, relativeStart), maxRelativeOffset)
        return NSRange(location: newStart + relativeStart, length: relativeEnd - relativeStart)
    }

    private static func substring(_ nsText: NSString, from start: Int, to end: Int) -> String {
        guard end > start else { return "" }
        return nsText.substring(with: NSRange(location: start, length: end - start))
    }
}
