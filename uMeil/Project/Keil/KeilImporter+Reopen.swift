import Foundation

// Opening a Keil project a second time, and the generated files both an
// import and a later open write.
extension KeilImporter {
    /// Opens the Keil project at `keilFile` as a uMeil project: imports it
    /// the first time, and after that reuses the uMeil project made then.
    ///
    /// On a later open the uMeil project file is kept as it is, since the user
    /// may have changed its settings, but the files uMeil generated in the
    /// `uMeil` folder are written again. That way a project imported by an
    /// older uMeil picks up a newer startup file, register header, and course
    /// library. A generated file the user has edited is left alone.
    static func openProject(
        at keilFile: URL,
        linkerScript: URL = defaultLinkerScript
    ) throws -> KeilImport {
        let projectFile = projectFile(for: keilFile)
        guard FileManager.default.fileExists(atPath: projectFile.path(percentEncoded: false)) else {
            return try importProject(at: keilFile, linkerScript: linkerScript)
        }
        return try refreshProject(projectFile, from: keilFile, linkerScript: linkerScript)
    }

    /// Writes the generated files again for a project imported before, and
    /// adds the course library to its sources if it was missing.
    private static func refreshProject(_ projectFile: URL, from keilFile: URL, linkerScript: URL) throws -> KeilImport {
        var project = try ProjectFile.load(from: projectFile)
        let keil = try KeilProject.load(from: keilFile)
        guard let chip = Chip(rawValue: keil.device) else {
            throw KeilImportError.unsupportedDevice(keil.device)
        }
        let folder = keilFile.deletingLastPathComponent()

        var notes: [String] = []
        var librarySymbols: Set<String>?
        _ = sourceFiles(of: keil, in: folder, librarySymbols: &librarySymbols, notes: &notes)
        // Only what changed is worth telling the user about on a later open.
        notes = []
        let context = ImportContext(
            keil: keil, chip: chip, folder: folder, librarySymbols: librarySymbols, linkerScript: linkerScript
        )
        let support = try writeSupportFiles(for: context, overwriteEdited: false, notes: &notes)

        let missing = support.sources.filter { !project.sources.contains($0) }
        if !missing.isEmpty {
            // Keep the startup file last, as a new import lists it.
            let startup = "\(supportDirectoryName)/\(startupFileName)"
            project.sources.removeAll { $0 == startup }
            project.sources += missing.filter { $0 != startup } + [startup]
            if !project.includePaths.contains(supportDirectoryName) {
                project.includePaths.append(supportDirectoryName)
            }
            try ProjectFile.save(project, to: projectFile)
        }
        return KeilImport(projectFile: projectFile, project: project, notes: notes)
    }

    /// What a project's generated files are made from.
    struct ImportContext {
        var keil: KeilProject
        var chip: Chip
        var folder: URL
        /// The functions of the course libraries uMeil stands in for, or
        /// `nil` when the project links none.
        var librarySymbols: Set<String>?
        var linkerScript: URL
    }

    /// What `writeSupportFiles` added to the project.
    struct SupportFiles {
        /// Sources to build, relative to the project folder.
        var sources: [String]
        var linkerScript: String
    }

    /// Writes the startup file, register header, course library, and linker
    /// script into the project's `uMeil` folder.
    ///
    /// - Parameter overwriteEdited: Whether to replace a generated file that
    ///   no longer looks like uMeil wrote it.
    static func writeSupportFiles(
        for context: ImportContext,
        overwriteEdited: Bool,
        notes: inout [String]
    ) throws -> SupportFiles {
        let support = try ProjectSecurity.ensureSafeSubdirectory(named: supportDirectoryName, in: context.folder)

        func write(_ text: String, to name: String) throws {
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
                  name != ".", name != "..",
                  !ProjectSecurity.containsControlOrNewline(name)
            else {
                throw ProjectSecurityError.unsafePath(name)
            }
            let url = support.appending(path: name, directoryHint: .notDirectory)
            try ProjectSecurity.ensureSafeFileDestination(url, in: context.folder)
            if !overwriteEdited, let existing = try? String(contentsOf: url, encoding: .utf8) {
                guard existing != text else { return }
                guard isGenerated(existing) else {
                    notes.append("\(supportDirectoryName)/\(name) was not updated, because it has been edited.")
                    return
                }
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        var sources: [String] = []
        let startup = try startupSource(for: context.keil, chip: context.chip, in: context.folder, notes: &notes)
        try write(startup, to: startupFileName)
        try write(KeilDeviceHeader.source, to: KeilDeviceHeader.fileName)
        if let librarySymbols = context.librarySymbols {
            try write(KeilCourseLibrary.source(providing: librarySymbols), to: KeilCourseLibrary.fileName)
            sources.append("\(supportDirectoryName)/\(KeilCourseLibrary.fileName)")
        }
        let scriptName = context.linkerScript.lastPathComponent
        try write(String(contentsOf: context.linkerScript, encoding: .utf8), to: scriptName)
        sources.append("\(supportDirectoryName)/\(startupFileName)")
        return SupportFiles(sources: sources, linkerScript: "\(supportDirectoryName)/\(scriptName)")
    }

    /// Whether `text` still carries the line uMeil puts at the top of the
    /// files it generates. The linker script comes from uMeil's template and
    /// is recognised by its own first line.
    static func isGenerated(_ text: String) -> Bool {
        let head = text.prefix(400)
        return head.contains("written by uMeil") || head.contains("Linker script for the TM4C1294NCPDT")
    }
}
