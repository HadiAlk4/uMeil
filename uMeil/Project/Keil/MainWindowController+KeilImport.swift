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

        do {
            let result = try importKeilProject(at: url)
            if !result.notes.isEmpty {
                showImportNotes(result.notes, for: result.project.name)
            }
        } catch KeilImportError.alreadyImported(let projectFile) {
            // Imported before: open what is there and change nothing.
            openItem(at: projectFile)
        } catch {
            presentError(error)
        }
    }

    /// Makes a uMeil project next to the Keil project at `url`, opens its
    /// folder, and shows its first source file.
    @discardableResult
    func importKeilProject(at url: URL) throws -> KeilImport {
        let result = try KeilImporter.importProject(at: url)
        let folder = result.projectFile.deletingLastPathComponent()
        openFolder(folder)
        if let main = result.project.sources.first {
            openFile(folder.appending(path: main))
        }
        return result
    }

    private func showImportNotes(_ notes: [String], for name: String) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” was imported, with \(notes.count == 1 ? "one thing" : "some things") to know"
        alert.informativeText = notes.map { "• " + $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
