import AppKit

/// The main IDE window: a file navigator on the left, the code editor on the
/// right, and a collapsible bottom panel for build issues and the terminal.
/// Flashing lives in `MainWindowController+Flashing.swift`.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    NSToolbarItemValidation {
    let navigator = FileNavigatorViewController()
    let editor = EditorViewController()
    let issues = IssuesViewController()
    let terminal: TerminalViewController
    let bottomPanel: BottomPanelViewController

    /// Runs builds. Replaceable so tests can build without a real compiler.
    var buildEngine = BuildEngine()
    /// Finds the compiler. Looked up for each build, since a toolchain may
    /// have been installed since the last one.
    var makeToolLocator: () -> ToolLocator = { .standard() }

    /// Writes firmware to the board. Replaceable so tests can flash without one.
    var flasher = Flasher()
    /// Watches for the board on USB, for the toolbar's status.
    let boardMonitor: any BoardMonitoring
    let toolbar = MainToolbar()
    /// Runs debug sessions and keeps the breakpoints.
    let debugger = DebugController()
    let debugPanels = DebugPanelsController()
    let debugBar = DebugBarView() // Run and step buttons over the editor during a session.
    /// Floats "Build Succeeded" and "Flashed to Board" over the editor.
    let notice = NoticeView()
    /// File > Open Quickly: finds a project file by a few letters of its name.
    let quickOpen = QuickOpenController()
    /// Edit > Go to Line: jumps the editor to a line or line:column.
    let goToLine = GoToLineController()

    /// The outcome of the most recent build of the open folder.
    private(set) var lastBuild: BuildResult? { didSet { refreshStatusBar() } }
    private(set) var isBuilding = false { didSet { window?.toolbar?.validateVisibleItems() } }
    /// True from the moment Build and Flash is chosen until it finishes,
    /// including the build that comes first.
    var isFlashing = false { didSet { window?.toolbar?.validateVisibleItems() } }
    /// The Build and Flash in progress, kept so it can be stopped.
    var flashTask: Task<Void, Never>?
    /// Ad-hoc debug refresh tasks and close-deferral state.
    var debugTasks = DebugWindowTasks()
    var codeIntelligence: CodeIntelligenceController?
    let bottomPanelItem: NSSplitViewItem
    let editorSplit = NSSplitViewController()

    /// Tells the user what to know after a Keil project is imported: files
    /// left out or replaced. Replaceable so tests do not show an alert.
    var showImportNotes: (_ notes: [String], _ projectName: String) -> Void = { notes, name in
        MainWindowController.alertImportNotes(notes, for: name)
    }

    /// Answers "Save changes?" in place of the alert. For tests.
    var answerSavePrompt: ((_ files: [URL]) -> SaveChoice)?

    /// The folder open in the navigator, or `nil` before one is chosen.
    private(set) var folder: URL? {
        didSet {
            folderDidChange()
            window?.toolbar?.validateVisibleItems()
        }
    }

    /// Where the last opened folder is remembered between launches.
    static let lastFolderDefaultsKey = "LastOpenedFolder"
    let defaults: UserDefaults
    /// The folders listed on the welcome screen.
    var recentProjects: RecentProjects { RecentProjects(defaults: defaults) }
    /// Picks the window a project folder chosen in this one opens in: one
    /// already showing it, this one if it is empty, or a new one. Set by the
    /// app delegate; without it, everything opens here.
    var chooseWindow: ((_ folder: URL) -> MainWindowController?)?

    init(
        defaults: UserDefaults = .standard,
        boardMonitor: any BoardMonitoring = USBBoardMonitor(),
        makeTerminalSession: @escaping @MainActor () -> any TerminalSessionView = { SwiftTermSessionView() }
    ) {
        self.defaults = defaults
        self.boardMonitor = boardMonitor
        self.terminal = TerminalViewController(session: makeTerminalSession())
        self.bottomPanel = BottomPanelViewController(
            issues: issues, terminal: terminal, debugConsole: debugPanels.command,
            serial: SerialMonitorViewController(defaults: defaults)
        )

        let bottomPanelItem = NSSplitViewItem(viewController: bottomPanel)
        bottomPanelItem.canCollapse = true
        bottomPanelItem.minimumThickness = 150
        bottomPanelItem.isCollapsed = true
        self.bottomPanelItem = bottomPanelItem

        let window = Self.makeMainWindow(
            navigator: navigator,
            editor: editor,
            editorSplit: editorSplit,
            bottomPanelItem: bottomPanelItem
        )

        super.init(window: window)
        window.delegate = self

        navigator.onSelectFile = { [weak self] url in self?.userSelectedFile(url) }
        editor.welcomeView.onOpenRecent = { [weak self] url in self?.openRecentProject(url) }
        editor.loadViewIfNeeded()
        editor.welcomeView.showRecent(recentProjects.folders)
        showSidebar(false)
        editor.onModifiedChanged = { [weak self] _ in self?.updateTitle() }
        issues.onSelect = { [weak self] diagnostic in self?.show(diagnostic) }
        issues.onActivity = { [weak self] activity in self?.toolbar.activity.show(activity) }
        toolbar.isActionEnabled = { [weak self] action in self?.isEnabled(action) ?? false }
        configureCodeIntelligence()
        configureBottomPanelCallbacks()
        configureTabs()
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified
        window.toolbar?.validateVisibleItems()
        startWatchingForBoard()
        setUpDebugging()
        setUpBreakpointsAndAppearance()
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, not from a nib")
    }

    // MARK: - Folders

    /// Shows `url` in the navigator and closes whatever file was open.
    func openFolder(_ url: URL) {
        // A session and its breakpoints belong to the project they came from.
        if debugger.isActive { Task { await debugger.stop() } }
        debugger.clearBreakpoints()
        folder = url
        lastBuild = nil
        codeIntelligence?.folderOpened(url)
        navigator.showFolder(url)
        editor.close(hasFolder: true)
        terminal.updateFolder(url)
        defaults.set(url.path(percentEncoded: false), forKey: Self.lastFolderDefaultsKey)
        recentProjects.add(url)
        if !AppDelegate.isTestHost {
            // Lists the folder at the top of the Dock icon's menu.
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        showSidebar(true)
        updateTitle()
    }

    /// The file navigator is hidden on the welcome screen, which has nothing to list.
    private func showSidebar(_ isShown: Bool) {
        let split = window?.contentViewController as? NSSplitViewController
        split?.splitViewItem(for: navigator)?.isCollapsed = !isShown
    }

    /// File > Close Folder: back to the welcome screen.
    @objc func closeFolder(_ sender: Any?) {
        guard folder != nil, confirmDiscardingChanges() else { return }
        if debugger.isActive { Task { await debugger.stop() } }
        debugger.clearBreakpoints()
        folder = nil
        lastBuild = nil
        codeIntelligence?.folderClosed()
        navigator.showFolder(nil)
        editor.close(hasFolder: false)
        editor.welcomeView.showRecent(recentProjects.folders)
        terminal.updateFolder(nil)
        showSidebar(false)
        defaults.removeObject(forKey: Self.lastFolderDefaultsKey)
        updateTitle()
    }

    /// Opens a project picked on the welcome screen, or drops it from the
    /// list if it has been moved or deleted since.
    func openRecentProject(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            recentProjects.remove(url)
            editor.welcomeView.showRecent(recentProjects.folders)
            return
        }
        window(forOpening: url).openItem(at: url)
    }

    /// File > Open Folder…
    @objc func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        if panel.runModal() == .OK, let url = panel.url {
            window(forOpening: url).openItem(at: url)
        }
    }

    // MARK: - Files

    /// Opens `url` in the editor and selects it in the navigator. Unsaved
    /// changes to the current file are discarded, so ask the user first.
    /// Opens `url` in the editor. Returns false, after telling the user, if
    /// it could not be opened.
    @discardableResult
    func openFile(_ url: URL) -> Bool {
        defer {
            updateTitle()
            window?.toolbar?.validateVisibleItems()
        }
        do {
            try editor.open(url)
            navigator.select(url)
            refreshMarkers()
            refreshDebugMarks()
            return true
        } catch {
            navigator.select(editor.document?.url)
            presentError(error)
            return false
        }
    }

    /// The file that was showing keeps its unsaved changes in its tab.
    private func userSelectedFile(_ url: URL) {
        guard url != editor.document?.url else { return }
        openFile(url)
    }

    /// File > Save
    @objc func saveDocument(_ sender: Any?) { save() }

    /// Saves the open file. Returns false, after telling the user, if it fails.
    @discardableResult
    private func save() -> Bool {
        do {
            try editor.save()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        updateViewMenuItem(menuItem)
        return isEnabled(menuItem.action)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { isEnabled(item.action) }

    /// Whether the command a menu or toolbar item sends can run right now.
    func isEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(saveDocument(_:)), #selector(showGoToLine(_:)):
            editor.document != nil
        case #selector(jumpToDefinitionMenuAction(_:)), #selector(toggleCodeIntelligence(_:)):
            isCodeIntelligenceActionEnabled(action)
        case #selector(buildProject(_:)), #selector(flashProject(_:)):
            folder != nil && !isBuilding && !isFlashing && !debugger.isActive
        case #selector(flashImage(_:)):
            !isBuilding && !isFlashing && !debugger.isActive
        case #selector(stopFlashing(_:)):
            isFlashing
        case #selector(closeFolder(_:)), #selector(openQuickly(_:)):
            folder != nil
        default:
            isDebugActionEnabled(action)
        }
    }

    // MARK: - Building

    /// Product > Build
    @objc func buildProject(_ sender: Any?) { Task { await buildShowingNotice() } }

    /// Saves the open file, builds the project in the open folder, and shows
    /// the outcome in the issues panel and the editor's gutter.
    @discardableResult
    func build() async -> BuildResult? {
        guard !isBuilding, let folder else { return nil }
        if !saveAllFiles() {
            return nil
        }
        showIssuesPanel()

        let projectFile: URL
        do {
            guard let found = try projectFileImportingKeil(in: folder) else {
                issues.show(failure: "This folder has no uMeil project file (.umeil) or Keil project (.uvprojx) "
                    + "to build.")
                return nil
            }
            projectFile = found
        } catch {
            issues.show(failure: error.localizedDescription)
            return nil
        }

        isBuilding = true
        defer { isBuilding = false }
        issues.showBuilding()

        do {
            let plan = try BuildEngine.plan(forProjectFile: projectFile, locator: makeToolLocator())
            let result = try await buildEngine.build(plan)
            lastBuild = result
            issues.show(result)
            refreshMarkers()
            showMemoryUsage(of: result, projectFile: projectFile)
            codeIntelligence?.buildFinished(in: folder)
            return result
        } catch {
            lastBuild = nil
            issues.show(failure: error)
            refreshMarkers()
            return nil
        }
    }

    /// Flags the lines of the open file that the last build complained about.
    private func refreshMarkers() {
        guard let file = editor.document?.url else { return }
        editor.setMarkers(BuildSummary.markers(for: file, in: lastBuild?.diagnostics ?? []))
        editor.setBuildMessages(BuildSummary.lineMessages(for: file, in: lastBuild?.diagnostics ?? []))
    }

    /// Takes the editor to the place a build message points at.
    private func show(_ diagnostic: Diagnostic) {
        guard let file = diagnostic.file else { return }
        // GCC counts columns in bytes (`-fdiagnostics-column-unit=byte`).
        navigate(to: file, line: diagnostic.line, column: diagnostic.column, columnUnit: .utf8)
    }
}

// Kept out of the class body to keep it short. Same file, so the private
// members above are still in reach.
extension MainWindowController {
    // MARK: - Unsaved changes

    /// If any open tab has unsaved changes, asks whether to save them.
    /// Returns false if the user cancels, or if saving fails.
    func confirmDiscardingChanges() -> Bool {
        let unsaved = editor.unsavedFiles
        guard !unsaved.isEmpty else { return true }
        switch askToSave(unsaved) {
        case .save: return saveAllFiles()
        case .discard: return true
        case .cancel: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmDiscardingChanges() else { return false }
        terminal.terminate()
        if debugger.isActive {
            stopDebuggerAndClose(sender)
            return false
        }
        return true
    }

    // MARK: - Title

    func updateTitle() {
        guard let window else { return }
        let file = editor.document?.url

        window.title = file?.lastPathComponent ?? AppInfo.name
        window.subtitle = folder?.lastPathComponent ?? ""
        window.representedURL = file
        window.isDocumentEdited = editor.isModified
        // The Window menu and the Dock icon's menu list windows by title
        // alone, so there they also name the folder, to tell projects apart.
        if let folder, !AppDelegate.isTestHost {
            NSApp.changeWindowsItem(window, title: "\(window.title) — \(folder.lastPathComponent)", filename: false)
        }
    }
}
