import Foundation

/// Formats C code with `clang-format`, which ships beside `clangd` in
/// Xcode, the Command Line Tools, and Homebrew's `llvm`.
struct ClangFormatter: Sendable {
    enum Failure: Error, Equatable, LocalizedError {
        case notFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                "clang-format wasn’t found. It comes with Xcode or the Command Line Tools "
                    + "(xcode-select --install)."
            case .failed(let message):
                message.isEmpty ? "clang-format could not format this code." : message
            }
        }
    }

    /// The style used when the project has no `.clang-format` file: four
    /// spaces, function braces on their own line, and includes left in the
    /// order written, since TivaWare needs `<stdint.h>` and `<stdbool.h>`
    /// before `driverlib`. Blinky is already in this style.
    static let defaultStyle = "{BasedOnStyle: LLVM, IndentWidth: 4, BreakBeforeBraces: Linux, ColumnLimit: 100, "
        + "SortIncludes: Never, AllowShortFunctionsOnASingleLine: None, AllowShortIfStatementsOnASingleLine: Never}"

    let executable: URL
    var runner: any ProcessRunning = ProcessRunner()

    /// `clang-format` next to `clangd` if there is one there, otherwise the
    /// first one in the usual places.
    static func locate(near clangd: URL?, locator: ToolLocator = .standard()) -> URL? {
        var directories: [URL] = []
        if let clangd {
            directories.append(clangd.resolvingSymlinksInPath().deletingLastPathComponent())
            directories.append(clangd.deletingLastPathComponent())
        }
        directories += locator.searchDirectories + ToolLocator.clangdSearchDirectories()
        return directories
            .map { $0.appending(path: "clang-format", directoryHint: .notDirectory) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    /// The `--style` value for `file`: its project's `.clang-format` (or
    /// `_clang-format`) when it has one, found as clang-format itself
    /// would, by looking up from the file's folder; `defaultStyle` otherwise.
    static func style(for file: URL) -> String {
        var directory = file.deletingLastPathComponent().standardizedFileURL
        while true {
            for name in [".clang-format", "_clang-format"] {
                let candidate = directory.appending(path: name, directoryHint: .notDirectory)
                if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                    return "file:\(candidate.path(percentEncoded: false))"
                }
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path(percentEncoded: false) == directory.path(percentEncoded: false) { break }
            directory = parent
        }
        return defaultStyle
    }

    /// `text` (the contents of `file`, saved or not) with `lines` (1-based)
    /// reformatted and everything else left alone.
    func format(_ text: String, of file: URL, lines: ClosedRange<Int>) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "uMeil-format-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appending(path: file.lastPathComponent, directoryHint: .notDirectory)
        try Data(text.utf8).write(to: copy)

        let output = try await runner.run(executable, arguments: [
            "--style=\(Self.style(for: file))",
            "--fallback-style=none",
            "--lines=\(lines.lowerBound):\(lines.upperBound)",
            copy.path(percentEncoded: false)
        ])
        guard output.exitCode == 0 else {
            throw Failure.failed(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.standardOutput
    }

    /// The one replacement that turns `old` into `new`: everything between
    /// their common start and common end. `nil` when they are the same.
    static func replacement(from old: String, to new: String) -> (range: NSRange, text: String)? {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        while prefix < oldUnits.count, prefix < newUnits.count, oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }
        guard prefix < oldUnits.count || prefix < newUnits.count else { return nil }
        var suffix = 0
        while suffix < oldUnits.count - prefix, suffix < newUnits.count - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }
        let range = NSRange(location: prefix, length: oldUnits.count - prefix - suffix)
        let insertedRange = NSRange(location: prefix, length: newUnits.count - prefix - suffix)
        return (range, (new as NSString).substring(with: insertedRange))
    }
}
