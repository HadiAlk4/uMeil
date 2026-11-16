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

    /// The outcome of the most recent build of the open folder.
    private(set) var lastBuild: BuildResult?
    private(set) var isBuilding = false
    /// True from the moment Build and Flash is chosen until it finishes,
    /// including the build that comes first.
    var isFlashing = false
    /// The Build and Flash in progress, kept so it can be stopped.
    var flashTask: Task<Void, Never>?
    let bottomPanelItem: NSSplitViewItem
    let editorSplit = NSSplitViewController()

    /// The folder open in the navigator, or `nil` before one is chosen.
    private(set) var folder: URL?

    /// Where the last opened folder is remembered between launches.
    static let lastFolderDefaultsKey = "LastOpenedFolder"
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        boardMonitor: any BoardMonitoring = USBBoardMonitor(),
        makeTerminalSession: @escaping @MainActor () -> any TerminalSessionView = { SwiftTermSessionView() }
    ) {
        self.defaults = defaults
        self.boardMonitor = boardMonitor
        self.terminal = TerminalViewController(session: makeTerminalSession())
        self.bottomPanel = BottomPanelViewController(issues: issues, terminal: terminal)

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
        editor.onModifiedChanged = { [weak self] _ in self?.updateTitle() }
        issues.onSelect = { [weak self] diagnostic in self?.show(diagnostic) }
        configureBottomPanelCallbacks()
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified
        startWatchingForBoard()
        setUpDebugging()
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, not from a nib")
    }

    // MARK: - Folders

    /// Shows `url` in the navigator and closes whatever file was open.
    func openFolder(_ url: URL) {
        // A session belongs to the project it was started from.
        Task { await debugger.stop() }
        folder = url
        lastBuild = nil
        navigator.showFolder(url)
        editor.close(hasFolder: true)
        terminal.updateFolder(url)
        defaults.set(url.path(percentEncoded: false), forKey: Self.lastFolderDefaultsKey)
        updateTitle()
    }

    /// File > Open Folder…
    @objc func chooseFolder(_ sender: Any?) {
        guard confirmDiscardingChanges() else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    /// Opens a folder or file handed to the app from outside: dropped on the
    /// Dock icon, opened from Finder, or passed to `open -a uMeil`.
    ///
    /// A folder is shown as it is. A project file opens its folder with the
    /// project's first source showing. Any other file opens its folder with
    /// that file showing.
    func openItem(at url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
              confirmDiscardingChanges()
        else { return }

        window?.makeKeyAndOrderFront(nil)
        if isDirectory.boolValue {
            openFolder(url)
            return
        }

        let parent = url.deletingLastPathComponent()
        openFolder(parent)
        if url.pathExtension == ProjectFile.fileExtension,
           let main = (try? ProjectFile.load(from: url))?.sources.first {
            openFile(parent.appending(path: main))
        } else {
            // Also a project file that cannot be read, so it can be fixed.
            openFile(url)
        }
    }

    // MARK: - Files

    /// Opens `url` in the editor and selects it in the navigator. Unsaved
    /// changes to the current file are discarded, so ask the user first.
    func openFile(_ url: URL) {
        do {
            try editor.open(url)
            navigator.select(url)
            refreshMarkers()
            refreshDebugMarks()
        } catch {
            navigator.select(editor.document?.url)
            presentError(error)
        }
        updateTitle()
    }

    private func userSelectedFile(_ url: URL) {
        guard url != editor.document?.url else { return }
        guard confirmDiscardingChanges() else {
            // Put the selection back on the file that is still open.
            navigator.select(editor.document?.url)
            return
        }
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
    private func isEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(saveDocument(_:)):
            editor.document != nil
        case #selector(buildProject(_:)), #selector(flashProject(_:)):
            folder != nil && !isBuilding && !isFlashing && !debugger.isActive
        case #selector(flashImage(_:)):
            !isBuilding && !isFlashing && !debugger.isActive
        case #selector(stopFlashing(_:)):
            isFlashing
        default:
            isDebugActionEnabled(action)
        }
    }

    // MARK: - New projects

    /// File > New Project…
    @objc func newProject(_ sender: Any?) {
        guard confirmDiscardingChanges() else { return }

        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.message = "Choose a name and location for a new Blinky project"
        panel.nameFieldLabel = "Project Name:"
        panel.nameFieldStringValue = "Blinky"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try createProject(named: url.lastPathComponent, in: url.deletingLastPathComponent())
        } catch {
            presentError(error)
        }
    }

    /// Creates a project from the Blinky template in `parent/name`, opens
    /// its folder, and shows its main source file.
    func createProject(named name: String, in parent: URL) throws {
        guard let template = try ProjectTemplate.all().first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let projectFile = try template.createProject(named: name, in: parent)
        let projectFolder = projectFile.deletingLastPathComponent()
        openFolder(projectFolder)

        let project = try ProjectFile.load(from: projectFile)
        if let main = project.sources.first {
            openFile(projectFolder.appending(path: main))
        }
    }

    // MARK: - Building

    /// Product > Build
    @objc func buildProject(_ sender: Any?) { Task { await build() } }

    /// Saves the open file, builds the project in the open folder, and shows
    /// the outcome in the issues panel and the editor's gutter.
    @discardableResult
    func build() async -> BuildResult? {
        guard !isBuilding, let folder else { return nil }
        if editor.isModified, !save() {
            return nil
        }
        showIssuesPanel()

        guard let projectFile = BuildSummary.projectFile(in: folder) else {
            issues.show(failure: "This folder has no uMeil project file (.umeil) to build.")
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
            return result
        } catch {
            lastBuild = nil
            issues.show(failure: error.localizedDescription)
            refreshMarkers()
            return nil
        }
    }

    /// Flags the lines of the open file that the last build complained about.
    private func refreshMarkers() {
        guard let file = editor.document?.url else { return }
        editor.setMarkers(BuildSummary.markers(for: file, in: lastBuild?.diagnostics ?? []))
    }

    /// Takes the editor to the place a build message points at.
    private func show(_ diagnostic: Diagnostic) {
        guard let file = diagnostic.file else { return }

        let isOpen = editor.document?.url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath()
        if !isOpen {
            guard confirmDiscardingChanges() else { return }
            openFile(file)
        }
        if let line = diagnostic.line {
            editor.goTo(line: line, column: diagnostic.column)
        }
    }

    // MARK: - Unsaved changes

    /// If the open file has unsaved changes, asks whether to save them.
    /// Returns false if the user cancels, or if saving fails.
    func confirmDiscardingChanges() -> Bool {
        guard editor.isModified, let name = editor.document?.url.lastPathComponent else { return true }

        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard confirmDiscardingChanges() else { return false }
        terminal.terminate()
        Task { await debugger.stop() }
        return true
    }

    // MARK: - Title

    private func updateTitle() {
        guard let window else { return }
        let file = editor.document?.url

        window.title = file?.lastPathComponent ?? AppInfo.name
        window.subtitle = folder?.lastPathComponent ?? ""
        window.representedURL = file
        window.isDocumentEdited = editor.isModified
    }
}
