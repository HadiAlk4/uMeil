import Foundation

/// The `.d` files GCC writes with `-MMD`: for each object file, the source
/// and headers it was built from. uMeil reads them to decide what to
/// recompile, which is how a header change rebuilds every file that uses it.
///
/// The format is a Makefile rule:
///
///     build/obj/src/main.c.o: src/main.c src/board.h \
///      src/my\ header.h
enum DependencyFile {
    /// The files the object depends on, in the order listed, without the
    /// target itself. Empty if the text is not a dependency rule.
    static func dependencies(in text: String) -> [String] {
        // A backslash at the end of a line continues the rule on the next.
        let joined = text
            .replacingOccurrences(of: "\\\r\n", with: " ")
            .replacingOccurrences(of: "\\\n", with: " ")

        // With -MP there are extra empty rules ("src/board.h:") after the
        // first; only the first rule lists the dependencies.
        guard let rule = joined.split(whereSeparator: \.isNewline).first(where: { !$0.allSatisfy(\.isWhitespace) }),
              let colon = targetSeparator(in: rule)
        else { return [] }

        return splitPaths(rule[rule.index(after: colon)...])
    }

    /// The colon that ends the target: the first one followed by whitespace
    /// or the end of the line, so a colon inside a path is not mistaken for it.
    private static func targetSeparator(in rule: Substring) -> Substring.Index? {
        var index = rule.startIndex
        while index < rule.endIndex {
            if rule[index] == ":" {
                let next = rule.index(after: index)
                if next == rule.endIndex || rule[next].isWhitespace {
                    return index
                }
            }
            index = rule.index(after: index)
        }
        return nil
    }

    /// Splits on whitespace, treating `\ ` as a space inside a path and
    /// `$$` as a dollar sign, as Make does.
    private static func splitPaths(_ text: Substring) -> [String] {
        var paths: [String] = []
        var current = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)

            if character == "\\", next < text.endIndex, text[next] == " " || text[next] == "#" || text[next] == "\\" {
                current.append(text[next])
                index = text.index(after: next)
            } else if character == "$", next < text.endIndex, text[next] == "$" {
                current.append("$")
                index = text.index(after: next)
            } else if character.isWhitespace {
                if !current.isEmpty {
                    paths.append(current)
                    current = ""
                }
                index = next
            } else {
                current.append(character)
                index = next
            }
        }
        if !current.isEmpty {
            paths.append(current)
        }
        return paths
    }
}
