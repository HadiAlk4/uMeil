import Foundation

/// A single atomic text edit produced by a line-editing operation, expressed in
/// UTF-16 code units to match `NSTextView` and `NSRange`.
struct LineEditResult: Equatable {
    let affectedRange: NSRange
    let replacement: String
    let newSelection: NSRange

    func applying(to text: String) -> String {
        (text as NSString).replacingCharacters(in: affectedRange, with: replacement)
    }
}

/// Tracks an active `⌘D` select-next-occurrence session.
struct MultiOccurrenceSession: Equatable {
    var ranges: [NSRange]
    var primaryIndex: Int
    var lastAddedRange: NSRange
    var searchQuery: String
    var wholeWord: Bool

    var primaryRange: NSRange {
        guard !ranges.isEmpty else { return NSRange(location: 0, length: 0) }
        return ranges[min(max(primaryIndex, 0), ranges.count - 1)]
    }
}

/// Synchronized replacement across all active occurrences in a `MultiOccurrenceSession`.
struct MultiOccurrenceEdit: Equatable {
    struct Replacement: Equatable {
        let range: NSRange
        let text: String
    }

    let replacements: [Replacement]
    let updatedSession: MultiOccurrenceSession

    func applying(to text: String) -> String {
        let mutable = NSMutableString(string: text)
        for item in replacements.reversed() {
            mutable.replaceCharacters(in: item.range, with: item.text)
        }
        return mutable as String
    }
}

/// Pure line-editing (`⌥↑`, `⌥↓`, `⇧⌥↓`) and select-next-match (`⌘D`) transformations.
enum LineEditing {
    private struct LineSpan {
        let start: Int
        let contentEnd: Int
        let end: Int

        var contentLength: Int { contentEnd - start }
        var lineBreakLength: Int { end - contentEnd }
    }

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
        let maxOffset = (blockLast.contentEnd - blockFirst.start) + above.lineBreakLength
        let newSelection = relocatedSelection(
            clamped,
            fromBlockStart: blockFirst.start,
            toBlockStart: above.start,
            maxRelativeOffset: maxOffset
        )
        return LineEditResult(affectedRange: affectedRange, replacement: replacement, newSelection: newSelection)
    }

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
        let maxOffset = (blockLast.contentEnd - blockFirst.start) + below.lineBreakLength
        let newSelection = relocatedSelection(
            clamped,
            fromBlockStart: blockFirst.start,
            toBlockStart: newBlockStart,
            maxRelativeOffset: maxOffset
        )
        return LineEditResult(affectedRange: affectedRange, replacement: replacement, newSelection: newSelection)
    }

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
            let separator = firstIndex > 0
                ? substring(nsText, from: lines[firstIndex - 1].contentEnd, to: lines[firstIndex - 1].end)
                : "\n"
            replacement = separator + blockContent
            newBlockStart = blockLast.end + (separator as NSString).length
        }

        let maxOffset = (blockLast.contentEnd - blockFirst.start) + blockLast.lineBreakLength
        let newSelection = relocatedSelection(
            clamped,
            fromBlockStart: blockFirst.start,
            toBlockStart: newBlockStart,
            maxRelativeOffset: maxOffset
        )
        return LineEditResult(affectedRange: affectedRange, replacement: replacement, newSelection: newSelection)
    }

    private static func splitLines(in nsText: NSString) -> [LineSpan] {
        let length = nsText.length
        var lines: [LineSpan] = []
        var lineStart = 0
        for index in 0..<length where nsText.character(at: index) == 0x0A {
            let contentEnd = (index > lineStart && nsText.character(at: index - 1) == 0x0D) ? index - 1 : index
            lines.append(LineSpan(start: lineStart, contentEnd: contentEnd, end: index + 1))
            lineStart = index + 1
        }
        lines.append(LineSpan(start: lineStart, contentEnd: length, end: length))
        return lines
    }

    static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let start = min(max(range.location, 0), length)
        let end = min(max(NSMaxRange(range), start), length)
        return NSRange(location: start, length: end - start)
    }

    private static func selectedLineRange(in lines: [LineSpan], selection: NSRange) -> (Int, Int) {
        let first = lineIndex(in: lines, atOffset: selection.location)
        let last = selection.length == 0 ? first : lineIndex(in: lines, atOffset: NSMaxRange(selection) - 1)
        return (first, last)
    }

    private static func lineIndex(in lines: [LineSpan], atOffset offset: Int) -> Int {
        var low = 0, high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].start <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private static func relocatedSelection(
        _ selection: NSRange,
        fromBlockStart oldStart: Int,
        toBlockStart newStart: Int,
        maxRelativeOffset: Int
    ) -> NSRange {
        let relStart = min(max(selection.location - oldStart, 0), maxRelativeOffset)
        let relEnd = min(max(NSMaxRange(selection) - oldStart, relStart), maxRelativeOffset)
        return NSRange(location: newStart + relStart, length: relEnd - relStart)
    }

    private static func substring(_ nsText: NSString, from start: Int, to end: Int) -> String {
        end > start ? nsText.substring(with: NSRange(location: start, length: end - start)) : ""
    }
}

// MARK: - Select Next Occurrence (⌘D) & Multi-Occurrence Rename

extension LineEditing {
    static func selectNextOccurrence(
        in text: String,
        currentSelection: NSRange,
        session: MultiOccurrenceSession?
    ) -> MultiOccurrenceSession? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        if let session {
            return addingNextMatch(in: nsText, to: session) ?? session
        }

        let clamped = clamp(currentSelection, length: nsText.length)
        if clamped.length == 0 {
            guard let wordRange = wordRangeAtCursor(in: nsText, offset: clamped.location),
                  wordRange.length > 0
            else { return nil }
            return MultiOccurrenceSession(
                ranges: [wordRange],
                primaryIndex: 0,
                lastAddedRange: wordRange,
                searchQuery: nsText.substring(with: wordRange),
                wholeWord: true
            )
        }

        let initial = MultiOccurrenceSession(
            ranges: [clamped],
            primaryIndex: 0,
            lastAddedRange: clamped,
            searchQuery: nsText.substring(with: clamped),
            wholeWord: false
        )
        return addingNextMatch(in: nsText, to: initial) ?? initial
    }

    static func wordRangeAtCursor(in nsText: NSString, offset: Int) -> NSRange? {
        let length = nsText.length
        guard length > 0 else { return nil }
        let cursor = min(max(offset, 0), length)
        if cursor < length, isIdentifierUnit(nsText.character(at: cursor)) {
            return expandRange(in: nsText, around: cursor, isIdentifier: true)
        }
        if cursor > 0, isIdentifierUnit(nsText.character(at: cursor - 1)) {
            return expandRange(in: nsText, around: cursor - 1, isIdentifier: true)
        }
        if cursor < length, isFallbackWordUnit(nsText.character(at: cursor)) {
            return expandRange(in: nsText, around: cursor, isIdentifier: false)
        }
        if cursor > 0, isFallbackWordUnit(nsText.character(at: cursor - 1)) {
            return expandRange(in: nsText, around: cursor - 1, isIdentifier: false)
        }
        return nil
    }

    static func applyInsertText(
        _ inserted: String,
        in text: String,
        session: MultiOccurrenceSession
    ) -> MultiOccurrenceEdit {
        let replacements = session.ranges.map { MultiOccurrenceEdit.Replacement(range: $0, text: inserted) }
        return buildMultiOccurrenceEdit(replacements: replacements, session: session)
    }

    static func applyDeleteBackward(in text: String, session: MultiOccurrenceSession) -> MultiOccurrenceEdit? {
        let nsText = text as NSString
        var replacements: [MultiOccurrenceEdit.Replacement] = []
        var previousMax = 0
        for range in session.ranges {
            if range.length > 0 {
                replacements.append(.init(range: range, text: ""))
                previousMax = NSMaxRange(range)
            } else if range.location > previousMax {
                let charRange = nsText.rangeOfComposedCharacterSequence(at: range.location - 1)
                let start = max(charRange.location, previousMax)
                let deleteRange = NSRange(location: start, length: range.location - start)
                replacements.append(.init(range: deleteRange, text: ""))
                previousMax = NSMaxRange(deleteRange)
            } else {
                replacements.append(.init(range: NSRange(location: range.location, length: 0), text: ""))
            }
        }
        guard replacements.contains(where: { $0.range.length > 0 }) else { return nil }
        return buildMultiOccurrenceEdit(replacements: replacements, session: session)
    }

    static func applyDeleteForward(in text: String, session: MultiOccurrenceSession) -> MultiOccurrenceEdit? {
        let nsText = text as NSString
        let count = session.ranges.count
        var replacements: [MultiOccurrenceEdit.Replacement] = []
        for (index, range) in session.ranges.enumerated() {
            let nextStart = (index + 1 < count) ? session.ranges[index + 1].location : nsText.length
            if range.length > 0 {
                replacements.append(.init(range: range, text: ""))
            } else if range.location < nextStart {
                let charRange = nsText.rangeOfComposedCharacterSequence(at: range.location)
                let end = min(NSMaxRange(charRange), nextStart)
                let deleteRange = NSRange(location: range.location, length: end - range.location)
                replacements.append(.init(range: deleteRange, text: ""))
            } else {
                replacements.append(.init(range: NSRange(location: range.location, length: 0), text: ""))
            }
        }
        guard replacements.contains(where: { $0.range.length > 0 }) else { return nil }
        return buildMultiOccurrenceEdit(replacements: replacements, session: session)
    }

    private static func addingNextMatch(
        in nsText: NSString,
        to session: MultiOccurrenceSession
    ) -> MultiOccurrenceSession? {
        guard !session.searchQuery.isEmpty else { return nil }
        let start = min(max(NSMaxRange(session.lastAddedRange), 0), nsText.length)
        let tail = NSRange(location: start, length: nsText.length - start)
        let full = NSRange(location: 0, length: nsText.length)
        guard let match = findNextMatch(in: nsText, range: tail, session: session)
                ?? findNextMatch(in: nsText, range: full, session: session)
        else { return nil }

        var updated = session
        let insertIndex = updated.ranges.firstIndex { $0.location > match.location } ?? updated.ranges.count
        updated.ranges.insert(match, at: insertIndex)
        if insertIndex <= updated.primaryIndex { updated.primaryIndex += 1 }
        updated.lastAddedRange = match
        return updated
    }

    private static func findNextMatch(
        in nsText: NSString,
        range searchRange: NSRange,
        session: MultiOccurrenceSession
    ) -> NSRange? {
        var cursor = searchRange.location
        let limit = NSMaxRange(searchRange)
        let isIdent = session.searchQuery.utf16.allSatisfy { isIdentifierUnit($0) }
        while cursor < limit {
            let found = nsText.range(
                of: session.searchQuery,
                options: [.literal],
                range: NSRange(location: cursor, length: limit - cursor)
            )
            guard found.location != NSNotFound else { return nil }
            let overlaps = session.ranges.contains { NSIntersectionRange($0, found).length > 0 || $0 == found }
            let validBoundary = !session.wholeWord || hasWordBoundaries(found, in: nsText, isIdentifierQuery: isIdent)
            if !overlaps && validBoundary { return found }
            cursor = found.location + 1
        }
        return nil
    }

    private static func hasWordBoundaries(_ range: NSRange, in nsText: NSString, isIdentifierQuery: Bool) -> Bool {
        let leftOK = range.location == 0
            || !matchesWordUnit(nsText.character(at: range.location - 1), isIdentifier: isIdentifierQuery)
        let endOffset = NSMaxRange(range)
        let rightOK = endOffset >= nsText.length
            || !matchesWordUnit(nsText.character(at: endOffset), isIdentifier: isIdentifierQuery)
        return leftOK && rightOK
    }

    private static func buildMultiOccurrenceEdit(
        replacements: [MultiOccurrenceEdit.Replacement],
        session: MultiOccurrenceSession
    ) -> MultiOccurrenceEdit {
        var newRanges: [NSRange] = []
        var delta = 0
        for item in replacements {
            let insertedLen = (item.text as NSString).length
            let caret = NSRange(location: item.range.location + delta + insertedLen, length: 0)
            if newRanges.last != caret { newRanges.append(caret) }
            delta += insertedLen - item.range.length
        }
        var updated = session
        updated.ranges = newRanges
        updated.primaryIndex = min(updated.primaryIndex, max(newRanges.count - 1, 0))
        if let last = newRanges.last { updated.lastAddedRange = last }
        return MultiOccurrenceEdit(replacements: replacements, updatedSession: updated)
    }

    private static func expandRange(in nsText: NSString, around index: Int, isIdentifier: Bool) -> NSRange {
        var start = index, end = index + 1
        while start > 0, matchesWordUnit(nsText.character(at: start - 1), isIdentifier: isIdentifier) { start -= 1 }
        while end < nsText.length, matchesWordUnit(nsText.character(at: end), isIdentifier: isIdentifier) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func matchesWordUnit(_ unit: UInt16, isIdentifier: Bool) -> Bool {
        isIdentifier ? isIdentifierUnit(unit) : isFallbackWordUnit(unit)
    }

    static func isIdentifierUnit(_ unit: UInt16) -> Bool {
        (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit) || (0x30...0x39).contains(unit) || unit == 0x5F
    }

    private static func isFallbackWordUnit(_ unit: UInt16) -> Bool {
        !(unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D) && !isIdentifierUnit(unit)
    }
}
