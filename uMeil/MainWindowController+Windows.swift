import AppKit

/// Opening a project: which window it goes in, now that several can be
/// open at once, and what it shows there.
extension MainWindowController {
    /// Opens a folder or file handed to the app from outside: dropped on the
    /// Dock icon, opened from Finder, or passed to `open -a uMeil`.
    ///
    /// A folder is shown as it is. A project file opens its folder with the
    /// project's first source showing. A Keil project is opened as a uMeil
    /// project, imported the first time. Any other file opens its folder with
    /// that file showing.
    func openItem(at url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        else { return }
        // A folder that is already open here is only brought forward.
        if isDirectory.boolValue, isShowingFolder(url) {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        guard confirmDiscardingChanges() else { return }

        window?.makeKeyAndOrderFront(nil)
        if isDirectory.boolValue {
            openFolder(url)
            return
        }

        if url.pathExtension == KeilImporter.fileExtension {
            openKeilProjectShowingNotes(at: url)
            return
        }

        let parent = url.deletingLastPathComponent()
        openFolder(parent)
        if url.pathExtension == ProjectFile.fileExtension,
           let project = try? ProjectFile.load(from: url) {
            if let main = project.sources.first,
               let mainURL = ProjectSecurity.safeRelativeURL(for: main, in: parent) {
                openFile(mainURL)
            }
        } else {
            // Also a project file that cannot be read, so it can be fixed.
            openFile(url)
        }
    }

    /// The window that `url`, a folder or a file in one, opens in.
    func window(forOpening url: URL) -> MainWindowController {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        return chooseWindow?(folder) ?? self
    }

    /// Whether this window shows `folder`.
    func isShowingFolder(_ folder: URL) -> Bool {
        guard let shown = self.folder else { return false }
        return Self.comparablePath(shown) == Self.comparablePath(folder)
    }

    /// The path with symlinks resolved and no trailing slash.
    fileprivate static func comparablePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
