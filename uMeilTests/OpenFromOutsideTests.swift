import AppKit
import Testing
@testable import uMeil

/// Opening folders and files handed to the app from outside: dropped on the
/// Dock icon, opened from Finder, or passed to `open -a uMeil`.
@MainActor
struct OpenFromOutsideTests {
    private func makeWindow() throws -> MainWindowController {
        let defaults = TestDefaults()
        return MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
    }

    /// A Blinky project on disk that no window has opened yet.
    private func makeBlinky(in folder: TemporaryFolder) throws -> URL {
        let template = try #require(try ProjectTemplate.all().first)
        return try template.createProject(named: "Blinky", in: folder.url)
    }

    @Test func aFolderIsShownWithNoFileOpen() throws {
        let folder = try TemporaryFolder()
        let project = try makeBlinky(in: folder).deletingLastPathComponent()
        let controller = try makeWindow()

        controller.openItem(at: project)

        #expect(controller.folder == project)
        #expect(controller.editor.document == nil)
        #expect(controller.navigator.root?.children.map(\.name).contains("Blinky.umeil") == true)
    }

    @Test func aProjectFileOpensItsFolderWithTheMainSourceShowing() throws {
        let folder = try TemporaryFolder()
        let projectFile = try makeBlinky(in: folder)
        let controller = try makeWindow()

        controller.openItem(at: projectFile)

        #expect(controller.folder?.lastPathComponent == "Blinky")
        #expect(controller.editor.document?.url.lastPathComponent == "main.c")
    }

    @Test func aProjectFileThatCannotBeReadIsShownItself() throws {
        let folder = try TemporaryFolder()
        let projectFile = try makeBlinky(in: folder)
        try Data("not json".utf8).write(to: projectFile)
        let controller = try makeWindow()

        controller.openItem(at: projectFile)

        #expect(controller.folder?.lastPathComponent == "Blinky")
        #expect(controller.editor.document?.url.lastPathComponent == "Blinky.umeil")
    }

    @Test func anyOtherFileOpensItsFolderWithThatFileShowing() throws {
        let folder = try TemporaryFolder()
        let project = try makeBlinky(in: folder).deletingLastPathComponent()
        let controller = try makeWindow()

        controller.openItem(at: project.appending(path: "startup/startup.c"))

        #expect(controller.folder?.lastPathComponent == "startup")
        #expect(controller.editor.document?.url.lastPathComponent == "startup.c")
    }

    @Test func somethingThatDoesNotExistLeavesTheWindowAlone() throws {
        let folder = try TemporaryFolder()
        let project = try makeBlinky(in: folder).deletingLastPathComponent()
        let controller = try makeWindow()
        controller.openItem(at: project)

        controller.openItem(at: folder.url.appending(path: "Missing"))

        #expect(controller.folder == project)
    }

    @Test func theAppTellsMacOSItOpensFoldersAndProjectFiles() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let documentTypes = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let opened = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        #expect(opened.sorted() == ["com.keil.uvprojx", "io.github.hadialk4.umeil-project", "public.folder"])

        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let tags = try #require(exported.first?["UTTypeTagSpecification"] as? [String: [String]])
        #expect(tags["public.filename-extension"] == [ProjectFile.fileExtension])

        let imported = try #require(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let keilTags = try #require(imported.first?["UTTypeTagSpecification"] as? [String: [String]])
        #expect(keilTags["public.filename-extension"] == [KeilImporter.fileExtension])
    }

    // MARK: - Keil projects

    /// A window that records import notes instead of showing an alert.
    private func makeWindow(collectingNotesIn notes: NotesBox) throws -> MainWindowController {
        let controller = try makeWindow()
        controller.showImportNotes = { found, _ in notes.notes += found }
        return controller
    }

    @Test func aKeilProjectIsImportedTheFirstTimeItIsOpened() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        let notes = NotesBox()
        let controller = try makeWindow(collectingNotesIn: notes)

        controller.openItem(at: keilFile)

        #expect(controller.folder == folder.url)
        #expect(controller.editor.document?.url.lastPathComponent == "main.c")
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "Template.umeil").path))
        #expect(notes.notes.contains { $0.contains("Lib4.lib was replaced") })
    }

    @Test func reopeningAKeilProjectKeepsItsSettingsAndRefreshesGeneratedFiles() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        let notes = NotesBox()
        let controller = try makeWindow(collectingNotesIn: notes)
        controller.openItem(at: keilFile)

        // The user changed a setting; an older uMeil wrote an older library
        // and the header, which the user then edited.
        let projectFile = folder.url.appending(path: "Template.umeil")
        var project = try ProjectFile.load(from: projectFile)
        project.build.defines.append("MINE")
        try ProjectFile.save(project, to: projectFile)
        let library = folder.url.appending(path: "uMeil/es_lib.c")
        try "// Course support library for the GNU toolchain, written by uMeil (old)\n"
            .write(to: library, atomically: true, encoding: .utf8)
        let header = folder.url.appending(path: "uMeil/TM4C129.h")
        try "// my own header\n".write(to: header, atomically: true, encoding: .utf8)
        notes.notes = []

        controller.openItem(at: keilFile)

        #expect(try ProjectFile.load(from: projectFile).build.defines.contains("MINE"))
        #expect(try String(contentsOf: library, encoding: .utf8).contains("ES_WEAK void ES_Serial"))
        #expect(try String(contentsOf: header, encoding: .utf8) == "// my own header\n")
        #expect(notes.notes == ["uMeil/TM4C129.h was not updated, because it has been edited."])
        #expect(controller.editor.document?.url.lastPathComponent == "main.c")
    }

    @Test func reopeningAddsTheCourseLibraryAnOlderImportLeftOut() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        let first = try KeilImporter.importProject(at: keilFile)
        var project = first.project
        project.sources.removeAll { $0 == "uMeil/es_lib.c" }
        try ProjectFile.save(project, to: first.projectFile)

        let reopened = try KeilImporter.openProject(at: keilFile)

        #expect(reopened.project.sources.suffix(2) == ["uMeil/es_lib.c", "uMeil/startup_gcc.c"])
        #expect(try ProjectFile.load(from: first.projectFile) == reopened.project)
    }

    @Test func buildingAFolderWithOnlyAKeilProjectImportsIt() throws {
        let folder = try TemporaryFolder()
        try KeilFixture.make(in: folder.url)
        let controller = try makeWindow()
        controller.openItem(at: folder.url)

        let projectFile = try controller.projectFileImportingKeil(in: folder.url)

        #expect(projectFile?.lastPathComponent == "Template.umeil")
        #expect(controller.navigator.root?.children.map(\.name).contains("Template.umeil") == true)

        let empty = try TemporaryFolder()
        #expect(try controller.projectFileImportingKeil(in: empty.url) == nil)
    }

    @Test func fileOpenAcceptsFoldersAndBothKindsOfProject() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let fileMenu = try #require(menu.items.compactMap(\.submenu).first { $0.title == "File" })
        let open = try #require(fileMenu.items.first { $0.title == "Open…" })
        #expect(open.action == #selector(MainWindowController.openDocument(_:)))
        #expect(open.keyEquivalent == "o")
        let openFolder = try #require(fileMenu.items.first { $0.title == "Open Folder…" })
        #expect(openFolder.keyEquivalentModifierMask == [.command, .option])
    }

    @Test func refusesToAutoOpenMainSourceEscapingTheProjectFolder() throws {
        let outer = try TemporaryFolder()
        let secret = outer.url.appending(path: "secret.txt")
        try Data("do not open".utf8).write(to: secret)

        let projectDir = outer.url.appending(path: "Project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: projectDir.appending(path: "link.c"),
            withDestinationURL: secret
        )

        var project = Project(
            name: "Evil",
            target: .init(chip: .tm4c1294ncpdt, board: nil),
            sources: ["../secret.txt"],
            includePaths: ["."],
            build: .init(
                cStandard: "gnu11",
                optimization: .none,
                defines: [],
                compilerFlags: [],
                linkerFlags: [],
                linkerScript: "tm4c1294ncpdt.ld",
                useDriverLib: false
            )
        )
        let projectFile = projectDir.appending(path: "Evil.umeil")
        try ProjectFile.save(project, to: projectFile)

        let controller = try makeWindow()
        controller.openItem(at: projectFile)
        #expect(controller.folder == projectDir)
        #expect(controller.editor.document == nil)

        project.sources = ["link.c"]
        try ProjectFile.save(project, to: projectFile)
        controller.openItem(at: projectFile)
        #expect(controller.editor.document == nil)

        // Also test Keil reopen when pre-existing .umeil has an escaping sources.first.
        let keilFolder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: keilFolder.url)
        let imported = try KeilImporter.importProject(at: keilFile)
        var reopenedProject = imported.project
        reopenedProject.sources = ["../secret.txt"] + reopenedProject.sources
        try ProjectFile.save(reopenedProject, to: imported.projectFile)

        let keilController = try makeWindow(collectingNotesIn: NotesBox())
        keilController.openItem(at: keilFile)
        #expect(keilController.folder == keilFolder.url)
        #expect(keilController.editor.document == nil)
    }
}

/// Collects what a window would have shown in an alert.
@MainActor
private final class NotesBox {
    var notes: [String] = []
}
