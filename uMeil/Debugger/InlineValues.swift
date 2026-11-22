import Foundation

/// Works out which variable values to print after each line of code while
/// the program is stopped, as dim text such as `count = 4`.
///
/// Only the lines of the stopped function, from its start down to the line
/// that runs next, are annotated: they are the ones whose variables have
/// the values GDB reports for the frame.
enum InlineValues {
    /// The most values shown after one line.
    static let maximumPerLine = 4
    /// Values longer than this are cut short with an ellipsis.
    static let maximumValueLength = 40
    /// How far above the stopped line to look for the function's start.
    static let maximumLinesAbove = 200

    /// Maps line numbers (from 1) to the text to show after them.
    ///
    /// - Parameters:
    ///   - source: The text of the file the frame is in.
    ///   - line: The line the frame has stopped on.
    ///   - variables: The frame's locals and arguments. Those without a
    ///     simple value, such as arrays and structs, are left out.
    static func annotations(source: String, stoppedAt line: Int, variables: [DebugVariable]) -> [Int: String] {
        var values: [String: String] = [:]
        for variable in variables {
            guard let value = variable.value, !value.isEmpty, values[variable.name] == nil else { continue }
            values[variable.name] = shortened(value)
        }
        guard !values.isEmpty, line >= 1 else { return [:] }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard line <= lines.count else { return [:] }
        let first = functionStart(in: lines, above: line)

        var result: [Int: String] = [:]
        var inBlockComment = false
        for number in first...line {
            let code = codeText(String(lines[number - 1]), inBlockComment: &inBlockComment)
            var seen: [String] = []
            for name in identifiers(in: code) where values[name] != nil && !seen.contains(name) {
                seen.append(name)
                if seen.count == maximumPerLine { break }
            }
            guard !seen.isEmpty else { continue }
            result[number] = seen.map { "\($0) = \(values[$0] ?? "")" }.joined(separator: ", ")
        }
        return result
    }

    /// The first line of the function that `line` is in: the nearest line
    /// above it that starts in the first column with something other than a
    /// brace, a comment, or a preprocessor directive, as a C function's
    /// signature does.
    static func functionStart(in lines: [Substring], above line: Int) -> Int {
        let lowest = max(1, line - maximumLinesAbove)
        var number = line
        while number > lowest {
            let text = lines[number - 1]
            if let first = text.first, !first.isWhitespace, !"{}#/*".contains(first) {
                return number
            }
            number -= 1
        }
        return lowest
    }

    /// `line` without comments and string or character literals, so names
    /// in them are not mistaken for variables.
    static func codeText(_ line: String, inBlockComment: inout Bool) -> String {
        var result = ""
        let characters = Array(line)
        var index = 0
        var quote: Character?
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inBlockComment {
                if character == "*", next == "/" {
                    inBlockComment = false
                    index += 1
                }
            } else if let open = quote {
                if character == "\\" {
                    index += 1
                } else if character == open {
                    quote = nil
                }
            } else if character == "/", next == "/" {
                break
            } else if character == "/", next == "*" {
                inBlockComment = true
                index += 1
                result.append(" ")
            } else if character == "\"" || character == "'" {
                quote = character
                result.append(" ")
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    /// The C identifiers in `code`, in order. Members after `.` or `->` are
    /// left out: they name fields, not the frame's variables.
    static func identifiers(in code: String) -> [String] {
        var result: [String] = []
        var current = ""
        // The punctuation since the last identifier or number, without spaces.
        var previous: [Character] = []
        func finish() {
            guard let first = current.first else { return }
            let isMember = previous.last == "." || previous.suffix(2) == ["-", ">"]
            if !first.isNumber, !isMember { result.append(current) }
            current = ""
            previous = []
        }
        for character in code {
            if character == "_" || character.isLetter || character.isNumber, character.isASCII {
                current.append(character)
                continue
            }
            finish()
            if !character.isWhitespace {
                previous.append(character)
            }
        }
        finish()
        return result
    }

    private static func shortened(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > maximumValueLength else { return flat }
        return String(flat.prefix(maximumValueLength - 1)) + "…"
    }
}
