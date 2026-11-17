import AppKit
import UniformTypeIdentifiers

extension MainWindowController {
    /// File > Import Keil Project…
    @objc func importKeilProject(_ sender: Any?) {
        guard confirmDiscardingChanges() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: KeilImporter.fileExtension)].compactMap { $0 }
        panel.prompt = "Import"
        panel.message = "Choose a Keil µVision project (.uvprojx) to make a uMeil project from"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        openKeilProjectShowingNotes(at: url)
    }

    /// File > Open…: a folder, a uMeil project, or a Keil project.
    @objc func openDocument(_ sender: Any?) {
        guard confirmDiscardingChanges() else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: ProjectFile.fileExtension),
            UTType(filenameExtension: KeilImporter.fileExtension),
            .folder
        ].compactMap { $0 }
        panel.prompt = "Open"
        panel.message = "Choose a project folder, a uMeil project (.umeil), or a Keil µVision project (.uvprojx)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        openItem(at: url)
    }

    /// Opens a Keil project and tells the user anything they should know
    /// about how it was imported.
    func openKeilProjectShowingNotes(at url: URL) {
        do {
            let result = try openKeilProject(at: url)
            if !result.notes.isEmpty {
                showImportNotes(result.notes, result.project.name)
            }
        } catch {
            presentError(error)
        }
    }

    /// Opens the Keil project at `url` as a uMeil project: imports it the
    /// first time and reuses that import after, then opens its folder with
    /// its first source file showing.
    @discardableResult
    func openKeilProject(at url: URL) throws -> KeilImport {
        let result = try KeilImporter.openProject(at: url)
        let folder = result.projectFile.deletingLastPathComponent()
        openFolder(folder)
        if let main = result.project.sources.first {
            openFile(folder.appending(path: main))
        }
        return result
    }

    /// Makes a uMeil project next to the Keil project at `url`, opens its
    /// folder, and shows its first source file.
    @discardableResult
    func importKeilProject(at url: URL) throws -> KeilImport {
        try openKeilProject(at: url)
    }

    /// The uMeil project to build in `folder`. A folder that only has a Keil
    /// project gets one made from it, so a Keil project can be built straight
    /// after opening its folder.
    func projectFileImportingKeil(in folder: URL) throws -> URL? {
        if let projectFile = BuildSummary.projectFile(in: folder) {
            return projectFile
        }
        guard let keilFile = KeilImporter.keilProjectFile(in: folder) else { return nil }
        let result = try KeilImporter.openProject(at: keilFile)
        navigator.reloadFromDisk()
        return result.projectFile
    }

    static func alertImportNotes(_ notes: [String], for name: String) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” was imported, with \(notes.count == 1 ? "one thing" : "some things") to know"
        alert.informativeText = notes.map { "• " + $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
