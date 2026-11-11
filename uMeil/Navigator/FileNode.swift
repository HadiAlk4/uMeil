import Foundation

/// A file or folder in the navigator's tree.
///
/// A class, not a struct, because `NSOutlineView` tracks rows by object
/// identity. A folder's contents are only read from disk when first needed.
final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var name: String { url.lastPathComponent }

    /// The folder's contents, read from disk on first use. Empty for files.
    var children: [FileNode] {
        if let loadedChildren {
            return loadedChildren
        }
        let loaded = isDirectory ? Self.loadChildren(of: url) : []
        loadedChildren = loaded
        return loaded
    }

    /// Forgets the cached contents so they are read from disk again.
    func reload() {
        loadedChildren = nil
    }

    /// Finds the node for `target` at or below this one, loading folders along the way.
    func node(for target: URL) -> FileNode? {
        let wanted = target.standardizedFileURL.pathComponents
        let own = url.standardizedFileURL.pathComponents
        guard wanted.starts(with: own) else { return nil }

        var current = self
        for component in wanted.dropFirst(own.count) {
            guard let next = current.children.first(where: { $0.name == component }) else { return nil }
            current = next
        }
        return current
    }

    /// Lists a folder: folders first, then files, each sorted the way Finder
    /// sorts names ("file2" before "file10"). Hidden items are left out.
    private static func loadChildren(of directory: URL) -> [FileNode] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return (contents ?? [])
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return FileNode(url: url, isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }
}
