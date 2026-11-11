import Foundation

/// A starting point for a new project, shipped inside the app.
///
/// Each template is a folder with three things in it:
/// - `template.json`: the name and summary shown to the user,
/// - `project.json`: the project file, without a final name,
/// - `files/`: the sources copied into the new project as they are.
struct ProjectTemplate: Equatable, Sendable {
    /// The template's folder name, for example `Blinky`.
    let identifier: String
    let name: String
    let summary: String
    let directory: URL

    private struct Manifest: Codable {
        var name: String
        var summary: String
    }

    /// The folder in the app bundle that holds the built-in templates.
    static var bundledDirectory: URL {
        Bundle.main.resourceURL?.appending(path: "Templates.bundle", directoryHint: .isDirectory)
            ?? URL(filePath: "Templates.bundle", directoryHint: .isDirectory)
    }

    /// Every template in `directory`, sorted by name.
    static func all(in directory: URL = bundledDirectory) throws -> [ProjectTemplate] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "template.json").path) }
            .map(ProjectTemplate.init(directory:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(directory: URL) throws {
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: directory.appending(path: "template.json"))
        )
        self.identifier = directory.lastPathComponent
        self.name = manifest.name
        self.summary = manifest.summary
        self.directory = directory
    }

    /// Creates the folder `parent/name`, fills it from the template, and
    /// writes `name.umeil` inside it. Nothing is left behind if this fails.
    ///
    /// - Returns: The URL of the new project file.
    @discardableResult
    func createProject(named name: String, in parent: URL) throws -> URL {
        guard Self.isValidProjectName(name) else {
            throw ProjectTemplateError.invalidName(name)
        }
        let destination = parent.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProjectTemplateError.alreadyExists(destination)
        }

        var project = try ProjectFile.load(from: directory.appending(path: "project.json"))
        project.name = name

        try FileManager.default.copyItem(at: directory.appending(path: "files"), to: destination)
        do {
            let projectFile = destination.appending(path: "\(name).\(ProjectFile.fileExtension)")
            try ProjectFile.save(project, to: projectFile)
            return projectFile
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// A project name becomes a folder and a file name, so it must be a
    /// single visible path component.
    static func isValidProjectName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.hasPrefix(".")
            && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.contains { $0 == "/" || $0 == ":" || $0.isNewline }
    }
}

enum ProjectTemplateError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case alreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            "\"\(name)\" cannot be used as a project name."
        case .alreadyExists(let url):
            "\"\(url.lastPathComponent)\" already exists in that folder."
        }
    }
}
