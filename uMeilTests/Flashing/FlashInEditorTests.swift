import AppKit
import Testing
@testable import uMeil

/// Build and Flash from the editor window: the real compiler, and a stand-in
/// for OpenOCD and the board.
@MainActor
@Suite(.enabled(if: BuildTestEnvironment.canBuild))
struct FlashInEditorTests {
    private struct Window {
        let controller: MainWindowController
        let board: FakeBoardMonitor
    }

    /// A window showing a new Blinky project, where flashing "prints" `log`.
    private func makeBlinkyWindow(
        in folder: TemporaryFolder,
        openOCD: FakeOpenOCD = FakeOpenOCD(log: FlashLog.success)
    ) throws -> Window {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let board = FakeBoardMonitor()
        let controller = MainWindowController(defaults: defaults, boardMonitor: board)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        try controller.createProject(named: "Blinky", in: folder.url)
        controller.flasher = Flasher(runner: openOCD)

        // The real compiler, plus a stand-in for OpenOCD in case it is not installed.
        let bin = folder.url.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FakeTool.install(.openOCD, in: bin, script: "exit 0")
        controller.makeToolLocator = {
            ToolLocator(searchDirectories: ToolLocator.defaultSearchDirectories() + [bin])
        }
        return Window(controller: controller, board: board)
    }

    private func type(_ text: String, into controller: MainWindowController) {
        let textView = controller.editor.textView
        let everything = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText(text, replacementRange: everything)
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test func buildAndFlashBuildsThenWritesTheNewFirmware() async throws {
        let folder = try TemporaryFolder()
        let openOCD = FakeOpenOCD(log: FlashLog.success)
        let controller = try makeBlinkyWindow(in: folder, openOCD: openOCD).controller

        let result = try #require(await controller.buildAndFlash())

        #expect(result.succeeded, "Flash failed:\n\(result.log)")
        #expect(controller.lastBuild?.succeeded == true)
        #expect(controller.issues.statusLabel.stringValue == "Flashed: 16 KB written to the board")
        #expect(controller.issues.diagnostics.isEmpty)
        #expect(controller.issues.progressBar.isHidden)
        #expect(controller.isIssuesPanelVisible)
        #expect(!controller.isFlashing)

        // OpenOCD was given the image the build just made.
        let arguments = try #require(openOCD.calls.withLock { $0 }.first)
        let image = try #require(controller.lastBuild?.elf)
        #expect(FileManager.default.fileExists(atPath: image.path(percentEncoded: false)))
        #expect(arguments.contains("flash write_image erase \(FlashPlan.tclQuoted(image.path(percentEncoded: false)))"))
    }

    @Test func aFailedBuildIsNotFlashed() async throws {
        let folder = try TemporaryFolder()
        let openOCD = FakeOpenOCD(log: FlashLog.success)
        let controller = try makeBlinkyWindow(in: folder, openOCD: openOCD).controller
        type("int main(void) {\n    return missing_variable;\n}\n", into: controller)

        let result = await controller.buildAndFlash()

        #expect(result == nil)
        #expect(openOCD.calls.withLock { $0 }.isEmpty)
        #expect(controller.issues.statusLabel.stringValue == "Build failed: 1 error")
        #expect(!controller.isFlashing)
    }

    @Test func noBoardIsExplainedInTheIssuesList() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(
            in: folder,
            openOCD: FakeOpenOCD(log: FlashLog.noBoard, exitCode: 1)
        ).controller

        let result = try #require(await controller.buildAndFlash())

        #expect(result.failure == .boardNotConnected)
        #expect(controller.issues.statusLabel.stringValue == "Flash failed")
        #expect(controller.issues.diagnostics == [
            Diagnostic(
                severity: .error,
                message: "No board found. Plug the LaunchPad's DEBUG USB port into this Mac, then try again."
            )
        ])
        #expect(controller.issues.tableView.numberOfRows == 1)
        #expect(controller.issues.progressBar.isHidden)
    }

    @Test func aFlashFailureIsListedAboveTheBuildsWarnings() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(
            in: folder,
            openOCD: FakeOpenOCD(log: FlashLog.wrongChip, exitCode: 1)
        ).controller
        type("int main(void) {\n    int unused;\n    for (;;) {\n    }\n}\n", into: controller)

        await controller.buildAndFlash()

        let diagnostics = controller.issues.diagnostics
        #expect(diagnostics.map(\.severity) == [.error, .warning])
        #expect(diagnostics.first?.message.contains("TM4C123GH6PM") == true)
        #expect(controller.editor.markers == [2: .warning])
    }

    @Test func missingOpenOCDSaysWhereToInstallIt() async throws {
        let folder = try TemporaryFolder()
        let openOCD = FakeOpenOCD(log: FlashLog.success)
        let controller = try makeBlinkyWindow(in: folder, openOCD: openOCD).controller
        // Build first, then take every tool away: only OpenOCD is looked up
        // again, because nothing needs compiling.
        try #require(await controller.build()?.succeeded == true)
        let compiler = try #require(ToolLocator.standard().locate(.compiler))
        let onlyCompiler = folder.url.appending(path: "compiler-only", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: onlyCompiler, withIntermediateDirectories: true)
        for tool in ["arm-none-eabi-gcc", "arm-none-eabi-objcopy", "arm-none-eabi-size"] {
            try FileManager.default.createSymbolicLink(
                at: onlyCompiler.appending(path: tool),
                withDestinationURL: compiler.deletingLastPathComponent().appending(path: tool)
            )
        }
        controller.makeToolLocator = { ToolLocator(searchDirectories: [onlyCompiler]) }

        let result = await controller.buildAndFlash()

        #expect(result?.failure == .openOCDNotFound)
        #expect(openOCD.calls.withLock { $0 }.isEmpty)
        #expect(controller.issues.toolchainBanner.tools == [.openOCD])
        #expect(!controller.issues.toolchainBanner.isHidden)
        #expect(!controller.issues.diagnostics.contains { $0.message.contains("Toolchain Status") })
    }

    @Test func theProgressBarFollowsTheStages() throws {
        let folder = try TemporaryFolder()
        let issues = try makeBlinkyWindow(in: folder).controller.issues

        issues.showFlashing(.connecting)
        #expect(!issues.progressBar.isHidden)
        #expect(issues.statusLabel.stringValue == "Connecting to the board…")
        let atStart = issues.progressBar.doubleValue

        issues.showFlashing(.verifying)
        #expect(issues.statusLabel.stringValue == "Verifying…")
        #expect(issues.progressBar.doubleValue > atStart)

        issues.show(FlashResult(failure: nil, bytesWritten: 1396, log: ""))
        #expect(issues.progressBar.isHidden)
    }

    @Test func stopEndsAFlashThatIsHanging() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(
            in: folder,
            openOCD: FakeOpenOCD(log: "", hangsUntilStopped: true)
        ).controller
        let stop = menuItem(#selector(MainWindowController.stopFlashing(_:)))
        let flash = menuItem(#selector(MainWindowController.flashProject(_:)))
        let build = menuItem(#selector(MainWindowController.buildProject(_:)))
        #expect(!controller.validateMenuItem(stop))
        #expect(controller.validateMenuItem(flash))

        controller.flashProject(nil)
        let task = try #require(controller.flashTask)
        while controller.issues.progressBar.isHidden {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.isFlashing)
        #expect(controller.validateMenuItem(stop))
        #expect(!controller.validateMenuItem(flash))
        #expect(!controller.validateMenuItem(build))

        controller.stopFlashing(nil)
        await task.value

        #expect(controller.issues.statusLabel.stringValue == "Flash stopped")
        #expect(controller.issues.diagnostics.first?.message.hasPrefix("Flashing was stopped.") == true)
        #expect(!controller.isFlashing)
        #expect(controller.flashTask == nil)
        #expect(!controller.validateMenuItem(stop))
        #expect(controller.validateMenuItem(flash))
    }

    @Test func flashIsOnlyOfferedWhenAFolderIsOpen() throws {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        let flash = menuItem(#selector(MainWindowController.flashProject(_:)))
        #expect(!controller.validateMenuItem(flash))

        let folder = try TemporaryFolder()
        controller.openFolder(folder.url)

        #expect(controller.validateMenuItem(flash))
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Toolbar

    @Test func theToolbarHasBuildAndFlashButtonsThatFollowTheMenu() throws {
        let folder = try TemporaryFolder()
        let controller = try makeBlinkyWindow(in: folder).controller
        // Build and Flash come first; the debugger's buttons follow them.
        let items = Array(try #require(controller.window?.toolbar?.items).filter { $0.action != nil }.prefix(2))
        let actions = items.compactMap(\.action)

        #expect(actions == [
            #selector(MainWindowController.buildProject(_:)),
            #selector(MainWindowController.flashProject(_:))
        ])
        for item in items where item.action != nil {
            #expect(controller.validateToolbarItem(item))
        }

        controller.isFlashing = true
        for item in items where item.action != nil {
            #expect(!controller.validateToolbarItem(item))
        }
    }

    @Test func theToolbarShowsWhetherABoardIsPluggedIn() throws {
        let folder = try TemporaryFolder()
        let window = try makeBlinkyWindow(in: folder)
        let label = window.controller.toolbar.boardLabel
        #expect(window.board.isStarted)
        #expect(label.stringValue == "No board")

        window.board.setConnected(true)
        #expect(label.stringValue == "Board connected")

        window.board.setConnected(false)
        #expect(label.stringValue == "No board")
    }
}
