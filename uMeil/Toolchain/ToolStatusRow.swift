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

    /// The path with the home folder shortened to `~`.
    private static func displayPath(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}
