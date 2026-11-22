import Foundation

/// The placeholders left in the text after accepting a snippet completion,
/// such as the three arguments of `GPIOPinWrite(ui32Port, ui8Pins, ui8Val)`.
/// Tab moves between them; the ranges follow the edits made while filling
/// them in.
struct SnippetPlaceholders: Equatable {
    /// Placeholder ranges in the document (UTF-16), in Tab order.
    private(set) var ranges: [NSRange]
    /// The placeholder Tab last moved to.
    private(set) var current = 0
    /// Where the cursor goes after the last placeholder.
    private(set) var finalOffset: Int

    /// `nil` when `snippet` has no placeholders, as nothing would be left to Tab to.
    init?(snippet: LSPSnippet, insertedAt location: Int) {
        guard !snippet.placeholders.isEmpty else { return nil }
        ranges = snippet.placeholders.map { NSRange(location: $0.location + location, length: $0.length) }
        finalOffset = location + (snippet.finalOffset ?? (snippet.text as NSString).length)
    }

    var currentRange: NSRange { ranges[current] }

    /// The whole span the snippet covers; leaving it ends the session.
    var span: NSRange {
        let start = min(ranges.map(\.location).min() ?? finalOffset, finalOffset)
        let end = max(ranges.map(NSMaxRange).max() ?? finalOffset, finalOffset)
        return NSRange(location: start, length: end - start)
    }

    /// Moves to the next placeholder. Returns `nil` after the last one,
    /// when the caller should put the cursor at `finalOffset` and end.
    mutating func next() -> NSRange? {
        guard current + 1 < ranges.count else { return nil }
        current += 1
        return ranges[current]
    }

    /// Moves to the previous placeholder, staying on the first.
    mutating func previous() -> NSRange {
        current = max(current - 1, 0)
        return ranges[current]
    }

    /// Updates the ranges for replacing `edit` with `replacementLength`
    /// UTF-16 units. Returns `false` when the edit cuts across a
    /// placeholder's edge, which ends the session.
    mutating func apply(edit: NSRange, replacementLength: Int) -> Bool {
        let delta = replacementLength - edit.length
        let owner = owningPlaceholder(for: edit)
        if owner == nil, ranges.contains(where: { Self.crossesEdge(edit, of: $0) }) {
            return false
        }
        let ownerEnd = owner.map { NSMaxRange(ranges[$0]) }
        if edit.location < finalOffset || (edit.location == finalOffset && ownerEnd == finalOffset) {
            finalOffset = max(finalOffset + delta, edit.location + replacementLength)
        }
        for index in ranges.indices {
            if index == owner {
                ranges[index].length += delta
            } else if edit.location < ranges[index].location
                        || (edit.location == ranges[index].location && owner.map { $0 < index } == true) {
                ranges[index].location += delta
            }
        }
        return true
    }

    /// The placeholder that contains `edit` (touching its ends counts),
    /// preferring the current one when two empty ones sit together.
    private func owningPlaceholder(for edit: NSRange) -> Int? {
        func contains(_ range: NSRange) -> Bool {
            edit.location >= range.location && NSMaxRange(edit) <= NSMaxRange(range)
        }
        if contains(ranges[current]) { return current }
        return ranges.indices.first { contains(ranges[$0]) }
    }

    private static func crossesEdge(_ edit: NSRange, of range: NSRange) -> Bool {
        let editEnd = NSMaxRange(edit)
        let rangeEnd = NSMaxRange(range)
        let overlaps = edit.location < rangeEnd && editEnd > range.location
        let inside = edit.location >= range.location && editEnd <= rangeEnd
        return overlaps && !inside
    }
}
