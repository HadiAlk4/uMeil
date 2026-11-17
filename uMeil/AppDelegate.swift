import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private lazy var toolchainWindowController = ToolchainWindowController()
    private lazy var serialMonitorWindowController = SerialMonitorWindowController()
    /// What the app was launched to open, instead of the last folder.
    private var launchItem: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(appName: AppInfo.name)

        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        if let launchItem {
            controller.openItem(at: launchItem)
        } else {
            reopenLastFolder(in: controller)
        }
        launchItem = nil

        NSApp.activate()
        showToolchainStatusIfToolsAreMissing()
    }

    /// A folder or file dropped on the Dock icon, opened from Finder, or
    /// passed to `open -a uMeil`. There is one window, so only the first
    /// item is opened.
    ///
    /// When this is what launches the app, it is called before the window
    /// exists, and the item is kept until launch finishes.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let mainWindowController {
            mainWindowController.openItem(at: url)
        } else {
            launchItem = url
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindowController?.confirmDiscardingChanges() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.terminal.terminate()
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

    /// Window > Serial Monitor
    @objc func showSerialMonitor(_ sender: Any?) {
        serialMonitorWindowController.showWindow(sender)
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
