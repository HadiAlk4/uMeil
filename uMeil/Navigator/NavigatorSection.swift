import Foundation

/// A heading in the navigator, such as "Sources", with the files under it.
///
/// A class, not a struct, because `NSOutlineView` tracks rows by object identity.
final class NavigatorSection {
    enum Kind: CaseIterable {
        case sources
        case startup
        case linkerScript
        case files

        var title: String {
            switch self {
            case .sources: "Sources"
            case .startup: "Startup"
            case .linkerScript: "Linker Script"
            case .files: "Files"
            }
        }
    }

    let kind: Kind
    let nodes: [FileNode]

    var title: String { kind.title }

    init(kind: Kind, nodes: [FileNode]) {
        self.kind = kind
        self.nodes = nodes
    }

    /// The files of `project` sorted under headings: what it compiles, the
    /// startup code, and the linker script. Files that are not on disk are
    /// left out, and so are headings with nothing under them.
    static func projectFiles(of project: Project, in folder: URL) -> [(kind: Kind, files: [URL])] {
        let fileManager = FileManager.default
        func existing(_ paths: [String]) -> [URL] {
            paths.compactMap { ProjectSecurity.safeRelativeURL(for: $0, in: folder) }
                .filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        }

        let startup = project.sources.filter(isStartupCode)
        let sources = project.sources.filter { !isStartupCode($0) }
        let groups: [(Kind, [URL])] = [
            (.sources, existing(sources)),
            (.startup, existing(startup)),
            (.linkerScript, existing([project.build.linkerScript].filter { !$0.isEmpty }))
        ]
        return groups.filter { !$0.1.isEmpty }.map { (kind: $0.0, files: $0.1) }
    }

    /// Whether `path` is the code that runs before `main`: the vector table
    /// and reset handler. Both uMeil and Keil projects name it `startup…`
    /// or keep it in a `startup` folder.
    static func isStartupCode(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased().hasPrefix("startup") }
    }
}
