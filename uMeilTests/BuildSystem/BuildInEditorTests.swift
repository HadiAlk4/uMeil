import AppKit
import Testing
@testable import uMeil

/// Building from the editor window, with the real compiler.
@MainActor
@Suite(.enabled(if: BuildTestEnvironment.canBuild))
struct BuildInEditorTests {
    /// A window showing a new Blinky project, with its main.c open.
    private func makeBlinkyWindow(in folder: TemporaryFolder) throws -> MainWindowController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let controller = MainWindowController(defaults: defaults)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        try controller.createProject(named: "Blinky", in: folder.url)
        return controller
    }

    /// Replaces the whole text of the open file, as typing would.
    private func type(_ text: String, into controller: MainWindowController) {
        let textView = controller.editor.textView
        let everything = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText(text, replacementRange: everything)
    }

    @Test func aNewProjectOpensWithItsMainFileShowing() throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)

        #expect(controller.folder?.lastPathComponent == "Blinky")
        #expect(controller.editor.document?.url.lastPathComponent == "main.c")
        #expect(controller.editor.textView.string.contains("GPIOPinWrite"))
        #expect(controller.navigator.root?.children.map(\.name).contains("Blinky.umeil") == true)
        #expect(!controller.isIssuesPanelVisible)
    }

    @Test func buildingBlinkyReportsSuccessAndShowsTheIssuesPanel() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)

        let result = try #require(await controller.build())

        #expect(result.succeeded, "Build failed:\n\(result.log)")
        #expect(controller.isIssuesPanelVisible)
        #expect(controller.issues.statusLabel.stringValue.hasPrefix("Build succeeded"))
        #expect(controller.issues.diagnostics.isEmpty)
        #expect(controller.editor.markers.isEmpty)
    }

    @Test func buildingSavesTheOpenFileFirst() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)
        let main = try #require(controller.editor.document?.url)
        type("int main(void) {\n    for (;;) {\n    }\n}\n", into: controller)
        #expect(controller.editor.isModified)

        let result = try #require(await controller.build())

        #expect(result.succeeded, "Build failed:\n\(result.log)")
        #expect(!controller.editor.isModified)
        #expect(try String(contentsOf: main, encoding: .utf8) == "int main(void) {\n    for (;;) {\n    }\n}\n")
    }

    @Test func anErrorIsListedAndMarkedOnItsLine() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)
        type("int main(void) {\n    int unused;\n    return missing_variable;\n}\n", into: controller)

        let result = try #require(await controller.build())

        #expect(!result.succeeded)
        #expect(controller.issues.statusLabel.stringValue == "Build failed: 1 error, 1 warning")
        #expect(controller.issues.tableView.numberOfRows == controller.issues.diagnostics.count)
        #expect(controller.editor.markers == [2: .warning, 3: .error])
    }

    @Test func choosingAnIssueMovesTheCursorToIt() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)
        let code = "int main(void) {\n    return missing_variable;\n}\n"
        type(code, into: controller)
        await controller.build()
        let error = try #require(controller.issues.diagnostics.first { $0.severity == .error })

        controller.issues.onSelect?(error)

        // Line 2, at the start of "missing_variable".
        let expected = (code as NSString).range(of: "missing_variable").location
        #expect(controller.editor.textView.selectedRange() == NSRange(location: expected, length: 0))
    }

    @Test func choosingAnIssueInAnotherFileOpensThatFile() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)
        let projectFolder = try #require(controller.folder)
        let startup = projectFolder.appending(path: "startup/startup.c")
        let original = try String(contentsOf: startup, encoding: .utf8)
        try Data(("#error broken on purpose\n" + original).utf8).write(to: startup)
        await controller.build()
        let error = try #require(controller.issues.diagnostics.first { $0.severity == .error })

        controller.issues.onSelect?(error)

        #expect(controller.editor.document?.url.lastPathComponent == "startup.c")
        // The compiler points at "error", just after the "#" that starts line 1.
        #expect(controller.editor.textView.selectedRange() == NSRange(location: 1, length: 0))
        #expect(controller.editor.markers == [1: .error])
    }

    @Test func fixingTheErrorClearsTheMarkers() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)
        type("int main(void) {\n    return missing_variable;\n}\n", into: controller)
        await controller.build()
        #expect(controller.editor.markers == [2: .error])

        type("int main(void) {\n    return 0;\n}\n", into: controller)
        let result = try #require(await controller.build())

        #expect(result.succeeded, "Build failed:\n\(result.log)")
        #expect(controller.editor.markers.isEmpty)
        #expect(controller.issues.diagnostics.isEmpty)
    }

    @Test func markersAreDroppedWhenLinesMove() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)
        type("int main(void) {\n    return missing_variable;\n}\n", into: controller)
        await controller.build()

        // Adding a line shifts everything below it, so the old line numbers are wrong.
        controller.editor.textView.insertText("\n", replacementRange: NSRange(location: 0, length: 0))

        #expect(controller.editor.markers.isEmpty)
    }

    @Test func aFolderWithoutAProjectFileSaysSo() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)
        let empty = folder.url.appending(path: "Empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        controller.openFolder(empty)

        let result = await controller.build()

        #expect(result == nil)
        #expect(controller.issues.statusLabel.stringValue == "Build failed")
        #expect(controller.issues.diagnostics.map(\.message) == [
            "This folder has no uMeil project file (.umeil) to build."
        ])
    }

    @Test func aMissingCompilerSaysWhereToInstallIt() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder)
        controller.makeToolLocator = { ToolLocator(searchDirectories: []) }

        let result = await controller.build()

        #expect(result == nil)
        #expect(controller.issues.diagnostics.first?.message.contains("Toolchain Status") == true)
    }

    @Test func buildIsOnlyOfferedWhenAFolderIsOpen() throws {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = MainWindowController(defaults: defaults)
        let build = NSMenuItem(
            title: "Build",
            action: #selector(MainWindowController.buildProject(_:)),
            keyEquivalent: "b"
        )

        #expect(!controller.validateMenuItem(build))

        let folder = try TemporaryFolder()
        controller.openFolder(folder.url)
        #expect(controller.validateMenuItem(build))
        defaults.removePersistentDomain(forName: suite)
    }
}
