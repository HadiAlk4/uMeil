import AppKit

/// Fills the status line under the editor with the project's chip. The
/// Flash and RAM meters beside it are filled after each build, in
/// `MainWindowController+MemoryUsage.swift`.
extension MainWindowController {
    /// The chip the open folder's project is built for, or `nil` when the
    /// folder has no uMeil project (yet: a Keil project gets one on its
    /// first build).
    var projectChip: Chip? {
        guard let folder, let file = BuildSummary.projectFile(in: folder),
              let project = try? ProjectFile.load(from: file)
        else { return nil }
        return project.target.chip
    }

    /// Called when the folder or the last build changes.
    func refreshStatusBar() {
        editor.statusBar.showChip(projectChip)
    }
}
