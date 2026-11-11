import Foundation

/// One message from the compiler or linker.
struct Diagnostic: Hashable, Sendable {
    enum Severity: String, Sendable {
        case error
        case warning
        case note
    }

    var severity: Severity
    var message: String
    /// The file the message is about, if it names one.
    var file: URL?
    /// 1-based, as the compiler reports it.
    var line: Int?
    /// 1-based, as the compiler reports it.
    var column: Int?
}

/// Reads the text GCC and the GNU linker print and picks out the messages.
///
/// Lines that are not messages are skipped: the source excerpts with `^~~~`
/// under them, "In function 'main':" context lines, and so on.
enum DiagnosticParser {
    /// - Parameter workingDirectory: The folder the tool ran in. Relative
    ///   file names in the output are resolved against it.
    static func parse(_ output: String, workingDirectory: URL) -> [Diagnostic] {
        var seen = Set<Diagnostic>()
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine($0, workingDirectory: workingDirectory) }
            // The same header warning is reported by every file that includes it.
            .filter { seen.insert($0).inserted }
    }

    private static func parseLine(_ line: Substring, workingDirectory: URL) -> Diagnostic? {
        // Compiler: "src/main.c:12:5: error: 'x' undeclared". The column is optional.
        if let match = line.wholeMatch(of: #/(.+?):(\d+):(?:(\d+):)? (fatal error|error|warning|note): (.*)/#) {
            return Diagnostic(
                severity: severity(match.4),
                message: String(match.5),
                file: fileURL(match.1, workingDirectory: workingDirectory),
                line: Int(match.2),
                column: match.3.flatMap { Int($0) }
            )
        }

        // Linker, with debug info: "/proj/src/main.c:7:(.text.main+0x4): undefined reference to `foo'".
        // The linker's own path may come first on the same line.
        if let match = line.wholeMatch(of: #/(?:.*?[\/\\]ld: )?(.+?):(\d+):\(\.[^)]*\): (.*)/#) {
            return Diagnostic(
                severity: .error,
                message: String(match.3),
                file: fileURL(match.1, workingDirectory: workingDirectory),
                line: Int(match.2),
                column: nil
            )
        }

        // Linker, no location: ".../bin/ld: cannot find -lfoo: No such file or directory".
        if let match = line.wholeMatch(of: #/.*?[\/\\]ld: (.*)/#) {
            let message = match.1
            // "main.o: in function `main':" only introduces the next line.
            if message.hasSuffix(":") && message.contains("in function") {
                return nil
            }
            if let warning = message.wholeMatch(of: #/warning: (.*)/#) {
                return Diagnostic(severity: .warning, message: String(warning.1))
            }
            return Diagnostic(severity: .error, message: String(message))
        }

        // The driver and its helpers: "cc1: fatal error: src/nope.c: No such file or directory",
        // "collect2: error: ld returned 1 exit status".
        if let match = line.wholeMatch(of: #/[\w.+-]+: (fatal error|error|warning): (.*)/#) {
            return Diagnostic(severity: severity(match.1), message: String(match.2))
        }

        return nil
    }

    private static func severity(_ text: Substring) -> Diagnostic.Severity {
        switch text {
        case "warning": .warning
        case "note": .note
        default: .error // "error" and "fatal error"
        }
    }

    private static func fileURL(_ path: Substring, workingDirectory: URL) -> URL {
        let path = String(path)
        if path.hasPrefix("/") {
            return URL(filePath: path).standardizedFileURL
        }
        return workingDirectory.appending(path: path).standardizedFileURL
    }
}
