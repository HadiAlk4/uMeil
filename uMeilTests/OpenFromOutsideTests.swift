import AppKit
import Testing
@testable import uMeil

/// Opening folders and files handed to the app from outside: dropped on the
/// Dock icon, opened from Finder, or passed to `open -a uMeil`.
@MainActor
struct OpenFromOutsideTests {
    private func makeWindow() throws -> MainWindowController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
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
        #expect(opened.sorted() == ["io.github.hadialk4.umeil-project", "public.folder"])

        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let tags = try #require(exported.first?["UTTypeTagSpecification"] as? [String: [String]])
        #expect(tags["public.filename-extension"] == [ProjectFile.fileExtension])
    }
}
