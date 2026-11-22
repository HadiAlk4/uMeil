import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every open project window, oldest first. Each has its own folder,
    /// editor, terminal, and debugger.
    private(set) var windowControllers: [MainWindowController] = []
    private lazy var toolchainWindowController = ToolchainWindowController()
    private var softwareUpdater: SoftwareUpdater?
    /// What the app was launched to open, instead of the last folders.
    private var launchItems: [URL] = []
    private var hasFinishedLaunching = false
    private var isTerminating = false
    /// How long quitting waits for GDB to resume and exit before forcing termination.
    var terminateTimeout: Duration = .milliseconds(2500)
    /// Completes a deferred `.terminateLater` reply. Replaceable in tests.
    var replyToTerminate: (Bool) -> Void = { shouldTerminate in
        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    /// Makes each new project window. Replaceable so tests can use fakes.
    var makeController: () -> MainWindowController = { MainWindowController() }

    /// The folders open when the app last quit, reopened at launch, one window each.
    static let openFoldersDefaultsKey = "OpenFolders"

    /// The project window in front, or the newest if none is.
    var mainWindowController: MainWindowController? {
        let front = NSApp.orderedWindows.lazy
            .compactMap { $0.windowController as? MainWindowController }
            .first { [windowControllers] in windowControllers.contains($0) }
        return front ?? windowControllers.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let updater = SoftwareUpdater()
        softwareUpdater = updater
        NSApp.mainMenu = MainMenu.make(appName: AppInfo.name, updater: updater)
        // Project windows are separate windows, never merged into tabs:
        // each already has its own tabs for files.
        NSWindow.allowsAutomaticWindowTabbing = false
        setUpAppearance()

        if !launchItems.isEmpty {
            for url in launchItems {
                open(url)
            }
        } else if !Self.isTestHost {
            reopenLastFolders()
        }
        launchItems = []
        if windowControllers.isEmpty {
            makeWindow()
        }
        hasFinishedLaunching = true

        NSApp.activate()
        if !Self.isTestHost {
            showToolchainStatusIfToolsAreMissing()
        }
    }

    /// True when the app was launched to host the unit tests. The tests make
    /// their own windows and projects, so the user's last folder is not
    /// reopened: reading it could wait on a permission prompt (for
    /// ~/Downloads, say) and stop the tests from starting.
    static var isTestHost: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
    }

    // MARK: - Windows

    /// Opens a new, empty project window, a little below and right of the
    /// one in front.
    @discardableResult
    func makeWindow() -> MainWindowController {
        let controller = makeController()
        if let front = mainWindowController?.window, let window = controller.window {
            window.setFrame(front.frame, display: false)
            window.cascadeTopLeft(from: front.cascadeTopLeft(from: .zero))
        }
        track(controller)
        controller.showWindow(nil)
        return controller
    }

    /// Adds a window made elsewhere, as tests do, to the ones the app
    /// manages: it is asked before quitting, and its tools are stopped.
    func track(_ controller: MainWindowController) {
        guard !windowControllers.contains(controller) else { return }
        windowControllers.append(controller)
        controller.chooseWindow = { [weak self, weak controller] folder in
            self?.window(forFolder: folder, from: controller)
        }
        if let window = controller.window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        // Closing the last window quits the app, which should then reopen
        // that window's folder, so it is still counted when saving.
        let isLast = windowControllers.count == 1
        if !isLast { windowControllers.removeAll { $0.window === window } }
        if !isTerminating { saveOpenFolders() }
        if isLast { windowControllers.removeAll { $0.window === window } }
    }

    /// Where `folder`, chosen in `requester`, opens: the window already
    /// showing it, else `requester` if it is on the welcome screen, else a
    /// new window.
    func window(forFolder folder: URL, from requester: MainWindowController?) -> MainWindowController {
        if let showing = windowControllers.first(where: { $0.isShowingFolder(folder) }) {
            return showing
        }
        if let requester, requester.folder == nil, requester.editor.unsavedFiles.isEmpty {
            return requester
        }
        return makeWindow()
    }

    /// Opens a folder or file in the window it belongs in.
    private func open(_ url: URL) {
        let requester = mainWindowController
        let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            ? url : url.deletingLastPathComponent()
        window(forFolder: folder, from: requester).openItem(at: url)
    }

    /// File > New Window, and the Dock icon's menu.
    @objc func newWindow(_ sender: Any?) {
        makeWindow()
        NSApp.activate()
    }

    /// Recently opened folders and the open windows are added by AppKit,
    /// above this.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "")
        item.target = self
        return menu
    }

    /// Clicking the Dock icon with no window open brings up a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && windowControllers.isEmpty {
            makeWindow()
        }
        return true
    }

    /// A folder or file dropped on the Dock icon, opened from Finder, or
    /// passed to `open -a uMeil`. Each folder gets its own window.
    ///
    /// When this is what launches the app, it is called before any window
    /// exists, and the items are kept until launch finishes.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard hasFinishedLaunching else {
            launchItems += urls
            return
        }
        for url in urls {
            open(url)
        }
    }

    // MARK: - Quitting

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in windowControllers where !controller.editor.unsavedFiles.isEmpty {
            controller.window?.makeKeyAndOrderFront(nil)
            guard controller.confirmDiscardingChanges() else { return .terminateCancel }
        }
        saveOpenFolders()
        let debugging = windowControllers.filter(\.debugger.isActive)
        guard !debugging.isEmpty else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        let timeout = terminateTimeout
        Task { [weak self] in
            for controller in debugging {
                await controller.debugger.stop(timeout: timeout)
            }
            guard let self else { return }
            self.isTerminating = false
            self.replyToTerminate(true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in windowControllers {
            controller.terminal.terminate()
            controller.bottomPanel.serial.disconnect()
            if controller.debugger.isActive {
                controller.debugger.terminateImmediately()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.isTestHost
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Window > Toolchain Status
    @objc func showToolchainStatus(_ sender: Any?) {
        toolchainWindowController.showWindow(sender)
    }

    /// The Install button on the issues panel's missing-tool banner: shows
    /// the toolchain window and installs whatever its check finds missing.
    @objc func installMissingTools(_ sender: Any?) {
        showToolchainStatus(sender)
        toolchainWindowController.status.installMissingToolsAfterChecking()
    }

    // MARK: - Reopening

    /// Remembers the folder of each open window, oldest window first.
    private func saveOpenFolders() {
        guard !Self.isTestHost else { return }
        let paths = windowControllers.compactMap { $0.folder?.path(percentEncoded: false) }
        UserDefaults.standard.set(paths, forKey: Self.openFoldersDefaultsKey)
    }

    /// Reopens the folders from the previous session that still exist, one
    /// window each. Before there were several windows, only the last
    /// folder was remembered.
    private func reopenLastFolders() {
        let defaults = UserDefaults.standard
        let paths = defaults.stringArray(forKey: Self.openFoldersDefaultsKey)
            ?? defaults.string(forKey: MainWindowController.lastFolderDefaultsKey).map { [$0] }
            ?? []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            let folder = URL(filePath: path, directoryHint: .isDirectory)
            guard !windowControllers.contains(where: { $0.isShowingFolder(folder) }) else { continue }
            makeWindow().openFolder(folder)
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
