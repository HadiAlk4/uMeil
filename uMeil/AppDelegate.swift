import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private lazy var toolchainWindowController = ToolchainWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(appName: AppInfo.name)

        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        reopenLastFolder(in: controller)

        NSApp.activate()
        showToolchainStatusIfToolsAreMissing()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindowController?.confirmDiscardingChanges() == false ? .terminateCancel : .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Window > Toolchain Status
    @objc func showToolchainStatus(_ sender: Any?) {
        toolchainWindowController.showWindow(sender)
    }

    /// Reopens the folder from the previous session, if it still exists.
    private func reopenLastFolder(in controller: MainWindowController) {
        guard let path = UserDefaults.standard.string(forKey: MainWindowController.lastFolderDefaultsKey) else {
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            controller.openFolder(URL(filePath: path, directoryHint: .isDirectory))
        }
    }

    /// On launch, brings up the toolchain window only when something needs installing.
    private func showToolchainStatusIfToolsAreMissing() {
        Task {
            let statuses = await ToolchainChecker(locator: .standard()).checkAll()
            if !ToolchainCatalog.entriesNeeded(for: statuses).isEmpty {
                showToolchainStatus(nil)
            }
        }
    }
}
