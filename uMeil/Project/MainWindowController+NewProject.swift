import AppKit

extension MainWindowController {
    /// File > New Project…
    @objc func newProject(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.message = "Choose a name and location for a new Blinky project"
        panel.nameFieldLabel = "Project Name:"
        panel.nameFieldStringValue = "Blinky"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let target = chooseWindow?(url) ?? self
        guard target.confirmDiscardingChanges() else { return }
        target.window?.makeKeyAndOrderFront(nil)
        do {
            try target.createProject(named: url.lastPathComponent, in: url.deletingLastPathComponent())
        } catch {
            target.presentError(error)
        }
    }

    /// Creates a project from the Blinky template in `parent/name`, opens
    /// its folder, and shows its main source file.
    func createProject(named name: String, in parent: URL) throws {
        guard let template = try ProjectTemplate.all().first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let projectFile = try template.createProject(named: name, in: parent)
        let projectFolder = projectFile.deletingLastPathComponent()
        openFolder(projectFolder)

        let project = try ProjectFile.load(from: projectFile)
        if let main = project.sources.first {
            openFile(projectFolder.appending(path: main))
        }
    }
}
