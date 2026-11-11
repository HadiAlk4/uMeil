import Foundation

/// Turns build results into what the editor shows: gutter markers and the
/// one-line status under the issues list.
enum BuildSummary {
    /// The lines of `file` that have a message, and the most serious kind on
    /// each. Notes are left out: they only add detail to another message.
    static func markers(for file: URL, in diagnostics: [Diagnostic]) -> [Int: Diagnostic.Severity] {
        let wanted = file.resolvingSymlinksInPath().standardizedFileURL
        var markers: [Int: Diagnostic.Severity] = [:]

        for diagnostic in diagnostics where diagnostic.severity != .note {
            guard let line = diagnostic.line,
                  diagnostic.file?.resolvingSymlinksInPath().standardizedFileURL == wanted
            else { continue }
            if markers[line] != .error {
                markers[line] = diagnostic.severity
            }
        }
        return markers
    }

    /// For example "Build succeeded: 1.4 KB flash, 16 bytes RAM" or
    /// "Build failed: 2 errors, 1 warning".
    static func statusText(for result: BuildResult) -> String {
        let errors = result.diagnostics.filter { $0.severity == .error }.count
        let warnings = result.diagnostics.filter { $0.severity == .warning }.count

        var counts: [String] = []
        if errors > 0 {
            counts.append(errors == 1 ? "1 error" : "\(errors) errors")
        }
        if warnings > 0 {
            counts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings")
        }

        guard result.succeeded else {
            return "Build failed" + (counts.isEmpty ? "" : ": " + counts.joined(separator: ", "))
        }

        var parts: [String] = []
        if let size = result.size {
            let flash = ByteCountFormatter.string(fromByteCount: Int64(size.flash), countStyle: .memory)
            let ram = ByteCountFormatter.string(fromByteCount: Int64(size.ram), countStyle: .memory)
            parts.append("\(flash) flash, \(ram) RAM")
        }
        parts += counts
        return "Build succeeded" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", "))
    }

    /// Where a message points, for the issues list: "main.c:12" or "main.c".
    /// Empty when the message names no file.
    static func locationText(for diagnostic: Diagnostic) -> String {
        guard let file = diagnostic.file else { return "" }
        return diagnostic.line.map { "\(file.lastPathComponent):\($0)" } ?? file.lastPathComponent
    }

    /// The project file in `folder`, if it has exactly the kind uMeil builds.
    static func projectFile(in folder: URL) -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return (contents ?? [])
            .filter { $0.pathExtension == ProjectFile.fileExtension }
            .min { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
