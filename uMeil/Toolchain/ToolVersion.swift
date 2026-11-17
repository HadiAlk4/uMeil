import Foundation

/// A tool's version number, parsed from its `--version` output.
struct ToolVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Parses the text a tool prints for `--version`.
    ///
    /// Examples of what this handles:
    /// - `arm-none-eabi-gcc (Arm GNU Toolchain 13.2.Rel1 (Build arm-13.7)) 13.2.1 20231009`
    /// - `GNU gdb (GDB) 15.2`
    /// - `Open On-Chip Debugger 0.12.0+dev-01685-gb9224c0c0 (2024-08-02-19:51)`
    /// - `Apple clangd version 21.0.0 (clang-2100.4.1.1)`
    static func parse(versionOutput: String, for tool: Tool) -> ToolVersion? {
        guard let text = versionText(in: versionOutput, for: tool),
              let match = text.firstMatch(of: #/(\d+)\.(\d+)(?:\.(\d+))?/#),
              let major = Int(match.1),
              let minor = Int(match.2)
        else { return nil }

        let patch = match.3.flatMap { Int($0) } ?? 0
        return ToolVersion(major, minor, patch)
    }

    /// Narrows the output down to the part that holds the tool's own version,
    /// skipping version-like numbers that belong to something else.
    private static func versionText(in output: String, for tool: Tool) -> Substring? {
        let lines = output.split(whereSeparator: \.isNewline)

        switch tool {
        case .compiler, .debugger:
            // The first line is "<name> (<distribution>) <version> ...". The
            // distribution often contains its own version, so skip past it.
            guard let line = lines.first else { return nil }
            return textAfterFirstParenthesizedGroup(in: line) ?? line

        case .openOCD:
            // OpenOCD may print other lines first, and prefixes vary by build.
            let marker = "Open On-Chip Debugger"
            for line in lines {
                if let range = line.range(of: marker) {
                    return line[range.upperBound...]
                }
            }
            return nil

        case .clangd:
            // "Apple clangd version 21.0.0 (clang-2100.4.1.1)" or "clangd version 23.1.0 (...)".
            // Stop before "(" so Apple's internal clang build tag is not read instead.
            let marker = "clangd version"
            for line in lines {
                if let range = line.range(of: marker) {
                    let after = line[range.upperBound...]
                    if let paren = after.firstIndex(of: "(") {
                        return after[..<paren]
                    }
                    return after
                }
            }
            return nil
        }
    }

    /// Returns what follows the first `(...)` group, which may itself contain
    /// nested parentheses. `nil` if the line has no complete group.
    private static func textAfterFirstParenthesizedGroup(in line: Substring) -> Substring? {
        guard let opening = line.firstIndex(of: "(") else { return nil }

        var depth = 0
        for index in line[opening...].indices {
            switch line[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return line[line.index(after: index)...]
                }
            default:
                break
            }
        }
        return nil
    }
}
