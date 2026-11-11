import AppKit

/// The main IDE window: a file navigator on the left and the code editor on
/// the right. Debugger views arrive in later milestones.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let navigator = FileNavigatorViewController()
    let editor = EditorViewController()

    /// The folder open in the navigator, or `nil` before one is chosen.
    private(set) var folder: URL?

    /// Where the last opened folder is remembered between launches.
    static let lastFolderDefaultsKey = "LastOpenedFolder"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: navigator)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 420
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: editor))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.setFrameAutosaveName("MainWindow")
        window.center()

        super.init(window: window)
        window.delegate = self

        navigator.onSelectFile = { [weak self] url in self?.userSelectedFile(url) }
        editor.onModifiedChanged = { [weak self] _ in self?.updateTitle() }
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, not from a nib")
    }

    // MARK: - Folders

    /// Shows `url` in the navigator and closes whatever file was open.
    func openFolder(_ url: URL) {
        folder = url
        navigator.showFolder(url)
        editor.close(hasFolder: true)
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

    // MARK: - Files

    /// Opens `url` in the editor and selects it in the navigator. Unsaved
    /// changes to the current file are discarded, so ask the user first.
    func openFile(_ url: URL) {
        do {
            try editor.open(url)
            navigator.select(url)
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
    @objc func saveDocument(_ sender: Any?) {
        save()
    }

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
        if menuItem.action == #selector(saveDocument(_:)) {
            return editor.document != nil
        }
        return true
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
        confirmDiscardingChanges()
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
