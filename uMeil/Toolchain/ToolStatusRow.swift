import Foundation

/// The text shown for one tool in the toolchain status table.
struct ToolStatusRow: Equatable {
    let name: String
    let state: String
    let version: String
    let location: String

    private static let placeholder = "—"

    init(tool: Tool, status: ToolStatus) {
        name = tool.displayName

        switch status {
        case .installed(let installed):
            state = "Installed"
            version = installed.version.description
            location = Self.displayPath(installed.url)
        case .notWorking(let url, let reason):
            state = "Not working: \(reason)"
            version = Self.placeholder
            location = Self.displayPath(url)
        case .missing:
            state = "Not found"
            version = Self.placeholder
            location = Self.placeholder
        }
    }

    /// One row per tool, in a fixed order. Tools without a status count as missing.
    static func rows(for statuses: [Tool: ToolStatus]) -> [ToolStatusRow] {
        Tool.allCases.map { ToolStatusRow(tool: $0, status: statuses[$0] ?? .missing) }
    }

    /// A one-line summary such as "2 of 3 tools found".
    static func summary(for statuses: [Tool: ToolStatus]) -> String {
        let total = Tool.allCases.count
        let installed = Tool.allCases.filter {
            if case .installed = statuses[$0] { true } else { false }
        }.count
        return installed == total ? "All \(total) tools found" : "\(installed) of \(total) tools found"
    }

    /// The status line shown while a package is being installed, such as
    /// "Downloading Arm GNU Toolchain: 64 MB of 142 MB".
    static func installMessage(for entry: ToolchainCatalogEntry, progress: ToolchainInstallProgress) -> String {
        switch progress {
        case .downloading(let fraction):
            let done = Int64(Double(entry.downloadSize) * min(max(fraction, 0), 1))
            let doneText = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
            let totalText = ByteCountFormatter.string(fromByteCount: entry.downloadSize, countStyle: .file)
            return "Downloading \(entry.displayName): \(doneText) of \(totalText)"
        case .verifying:
            return "Verifying \(entry.displayName)…"
        case .unpacking:
            return "Unpacking \(entry.displayName)…"
        }
    }

    /// The path with the home folder shortened to `~`.
    private static func displayPath(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}
