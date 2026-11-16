import AppKit

extension MainWindowController {
    /// Whether the issues panel under the editor is showing.
    var isIssuesPanelVisible: Bool { !bottomPanelItem.isCollapsed && bottomPanel.selectedTab == .issues }
    /// Whether the integrated terminal under the editor is showing.
    var isTerminalVisible: Bool { !bottomPanelItem.isCollapsed && bottomPanel.selectedTab == .terminal }

    static func makeMainWindow(
        navigator: FileNavigatorViewController,
        editor: EditorViewController,
        bottomPanelItem: NSSplitViewItem
    ) -> NSWindow {
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: navigator)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 420
        split.addSplitViewItem(sidebar)

        let editorSplit = NSSplitViewController()
        editorSplit.splitView.isVertical = false
        editorSplit.addSplitViewItem(NSSplitViewItem(viewController: editor))
        editorSplit.addSplitViewItem(bottomPanelItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: editorSplit))

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
        return window
    }

    func updateViewMenuItem(_ menuItem: NSMenuItem) {
        switch menuItem.action {
        case #selector(toggleTerminal(_:)):
            menuItem.title = isTerminalVisible ? "Hide Terminal" : "Show Terminal"
        case #selector(toggleIssues(_:)):
            menuItem.title = isIssuesPanelVisible ? "Hide Issues" : "Show Issues"
        default:
            break
        }
    }

    /// Expands the bottom panel and brings the build/flash issues list forward.
    func showIssuesPanel() {
        bottomPanel.select(.issues)
        bottomPanelItem.isCollapsed = false
    }

    /// Expands the bottom panel, switches to the terminal, and starts the shell
    /// lazily if it has not been started yet.
    func showTerminalPanel() {
        bottomPanel.select(.terminal)
        bottomPanelItem.isCollapsed = false
        terminal.startIfNeeded(folder: folder)
        window?.makeFirstResponder(terminal.focusableView)
    }

    /// View > Show/Hide Terminal (⌘J)
    @objc func toggleTerminal(_ sender: Any?) {
        if isTerminalVisible {
            collapseBottomPanel()
        } else {
            showTerminalPanel()
        }
    }

    /// View > Show/Hide Issues
    @objc func toggleIssues(_ sender: Any?) {
        if isIssuesPanelVisible {
            collapseBottomPanel()
        } else {
            showIssuesPanel()
        }
    }

    func collapseBottomPanel() {
        // NSSplitViewController moves firstResponder to the window when a pane
        // collapses, so check ownership before collapsing.
        let wasInBottomPanel = isFirstResponderInBottomPanel
        bottomPanelItem.isCollapsed = true
        if wasInBottomPanel {
            restoreEditorFocus()
        }
    }

    func configureBottomPanelCallbacks() {
        bottomPanel.onSelectTab = { [weak self] tab in
            guard let self else { return }
            if tab == .terminal {
                terminal.startIfNeeded(folder: folder)
                window?.makeFirstResponder(terminal.focusableView)
            }
        }
        bottomPanel.onRestartTerminal = { [weak self] in
            guard let self else { return }
            terminal.restart(folder: folder)
            window?.makeFirstResponder(terminal.focusableView)
        }
        bottomPanel.onClose = { [weak self] in
            self?.collapseBottomPanel()
        }
    }

    private var isFirstResponderInBottomPanel: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: bottomPanel.view)
    }

    private func restoreEditorFocus() {
        guard let window else { return }
        if editor.document != nil {
            window.makeFirstResponder(editor.textView)
        } else {
            window.makeFirstResponder(nil)
        }
    }
}
