import Foundation

/// Scores how well a typed query matches a file path, the way Xcode's Open
/// Quickly does: the query's letters must appear in order, and matches in
/// the file name, at the start of words, and in runs score higher.
enum FuzzyMatch {
    struct Result: Equatable {
        var score: Int
        /// Positions in the path's characters that matched, for bolding.
        var matchedIndices: [Int]
    }

    /// The match of `query` in `path` (relative to the project, with
    /// forward slashes), or `nil` if its letters are not all there in order.
    /// Case is ignored, and so are spaces in the query.
    static func match(_ query: String, in path: String) -> Result? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Result(score: 0, matchedIndices: []) }
        let original = Array(path)
        let haystack = Array(path.lowercased())
        guard haystack.count == original.count else { return nil }
        let nameStart = (original.lastIndex(of: "/").map { $0 + 1 }) ?? 0

        // Prefer matching inside the file name: try it there first, then the whole path.
        if let inName = greedyMatch(needle, haystack, original, from: nameStart) {
            return Result(score: score(inName, original, nameStart: nameStart) + 50, matchedIndices: inName)
        }
        if let anywhere = greedyMatch(needle, haystack, original, from: 0) {
            return Result(score: score(anywhere, original, nameStart: nameStart), matchedIndices: anywhere)
        }
        return nil
    }

    /// Ranks `paths` for `query`, best first. Ties go to the shorter path,
    /// then alphabetical order.
    static func rank(_ paths: [String], for query: String, limit: Int = 50) -> [(path: String, match: Result)] {
        paths.compactMap { path in match(query, in: path).map { (path: path, match: $0) } }
            .sorted { lhs, rhs in
                if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
                if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Matches each query letter at the first place it fits, preferring the
    /// start of a word when one is close by, so "uc" in "uart_config.c"
    /// takes the "c" of "config".
    private static func greedyMatch(
        _ needle: [Character],
        _ haystack: [Character],
        _ original: [Character],
        from start: Int
    ) -> [Int]? {
        var indices: [Int] = []
        var position = start
        for letter in needle {
            guard let found = haystack[position...].firstIndex(of: letter) else { return nil }
            // A later word start with the same letter is a better match,
            // unless this letter carries on a run.
            let continuesRun = indices.last.map { $0 + 1 == found } ?? false
            var chosen = found
            if !continuesRun, !isWordStart(found, original),
               let wordStart = haystack[found...].indices.first(where: {
                   haystack[$0] == letter && isWordStart($0, original)
               }),
               canFinish(needle.dropFirst(indices.count + 1), haystack, after: wordStart) {
                chosen = wordStart
            }
            indices.append(chosen)
            position = chosen + 1
        }
        return indices
    }

    private static func canFinish(_ rest: ArraySlice<Character>, _ haystack: [Character], after index: Int) -> Bool {
        var position = index + 1
        for letter in rest {
            guard position <= haystack.endIndex,
                  let found = haystack[position...].firstIndex(of: letter) else { return false }
            position = found + 1
        }
        return true
    }

    private static func isWordStart(_ index: Int, _ text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1], current = text[index]
        if "/_-. ".contains(previous) { return true }
        return previous.isLowercase && current.isUppercase
    }

    private static func score(_ indices: [Int], _ text: [Character], nameStart: Int) -> Int {
        var total = 0
        for (offset, index) in indices.enumerated() {
            total += 10
            if isWordStart(index, text) { total += 15 }
            if index == nameStart { total += 20 }
            if offset > 0, indices[offset - 1] + 1 == index { total += 12 }
        }
        // A tight match beats one spread across the path.
        if let first = indices.first, let last = indices.last {
            total -= (last - first + 1 - indices.count)
        }
        return total
    }
}
