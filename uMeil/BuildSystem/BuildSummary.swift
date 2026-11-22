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

    /// What the editor writes at the end of a line the build complained about.
    struct LineMessage: Equatable, Sendable {
        var severity: Diagnostic.Severity
        var text: String
        /// Other errors and warnings on the same line, not shown.
        var moreCount = 0
    }

    /// The most serious message on each line of `file`, for showing beside
    /// the code. Notes are left out, as for the gutter markers.
    static func lineMessages(for file: URL, in diagnostics: [Diagnostic]) -> [Int: LineMessage] {
        let wanted = file.resolvingSymlinksInPath().standardizedFileURL
        var messages: [Int: LineMessage] = [:]

        for diagnostic in diagnostics where diagnostic.severity != .note {
            guard let line = diagnostic.line,
                  diagnostic.file?.resolvingSymlinksInPath().standardizedFileURL == wanted
            else { continue }
            guard var existing = messages[line] else {
                messages[line] = LineMessage(severity: diagnostic.severity, text: diagnostic.message)
                continue
            }
            existing.moreCount += 1
            if existing.severity == .warning, diagnostic.severity == .error {
                existing.severity = .error
                existing.text = diagnostic.message
            }
            messages[line] = existing
        }
        return messages
    }

    /// For example "Build succeeded: 1.4 KB flash, 16 bytes RAM
    /// (Code=1300 RO-data=96 RW-data=8 ZI-data=16)" or
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
            var text = "\(flash) flash, \(ram) RAM"
            if let sections = result.sections {
                text += " (Code=\(sections.code) RO-data=\(sections.readOnlyData)"
                    + " RW-data=\(sections.readWriteData) ZI-data=\(sections.zeroInitializedData))"
            }
            parts.append(text)
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
