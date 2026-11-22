import AppKit

extension MainWindowController {
    /// Connects the editor's tab strip to opening and closing files.
    func configureTabs() {
        editor.tabBar.onSelect = { [weak self] url in self?.openFile(url) }
        editor.tabBar.onClose = { [weak self] url in self?.closeTab(url) }
    }

    /// Closes the tab for `url`, asking first if it has unsaved changes, and
    /// shows the tab beside it. Returns false if the user cancelled.
    @discardableResult
    func closeTab(_ url: URL) -> Bool {
        if editor.hasUnsavedChanges(url) {
            switch askToSave([url]) {
            case .save:
                do {
                    try editor.saveTab(url)
                } catch {
                    presentError(error)
                    return false
                }
            case .discard:
                break
            case .cancel:
                return false
            }
        }
        if let next = editor.closeTab(url) {
            openFile(next)
        } else if editor.document == nil {
            navigator.select(nil)
            updateTitle()
        }
        return true
    }

    /// File > Close Tab (⌘W). Closes the window once no tabs are left.
    func closeShowingTabOrWindow() {
        guard let url = editor.document?.url else {
            window?.performClose(nil)
            return
        }
        closeTab(url)
    }

    /// View > Show Next Tab and Show Previous Tab.
    @objc func showNextTab(_ sender: Any?) { showTab(offset: 1) }
    @objc func showPreviousTab(_ sender: Any?) { showTab(offset: -1) }

    private func showTab(offset: Int) {
        let urls = editor.tabs.urls
        guard urls.count > 1, let current = editor.document?.url,
              let index = urls.firstIndex(where: { $0.standardizedFileURL == current.standardizedFileURL })
        else { return }
        openFile(urls[(index + offset + urls.count) % urls.count])
    }

    /// Saves every open file with unsaved changes. Returns false, after
    /// telling the user, if one could not be saved.
    func saveAllFiles() -> Bool {
        do {
            try editor.saveAll()
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    enum SaveChoice {
        case save, discard, cancel
    }

    /// Asks whether to save the changes to `files` before they are closed.
    func askToSave(_ files: [URL]) -> SaveChoice {
        if let answer = answerSavePrompt {
            return answer(files)
        }
        let alert = NSAlert()
        if files.count == 1, let name = files.first?.lastPathComponent {
            alert.messageText = "Do you want to save the changes you made to “\(name)”?"
        } else {
            alert.messageText = "Do you want to save the changes you made to \(files.count) files?"
            alert.informativeText = files.map(\.lastPathComponent).joined(separator: ", ")
        }
        let warning = "Your changes will be lost if you don’t save them."
        alert.informativeText = alert.informativeText.isEmpty ? warning : alert.informativeText + "\n\n" + warning
        alert.addButton(withTitle: files.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}

extension NSWindow {
    /// File > Close Tab (⌘W). In the main window this closes the showing
    /// tab; in any other window, such as the Serial Monitor, the window.
    @objc func closeTabOrWindow(_ sender: Any?) {
        if let controller = windowController as? MainWindowController {
            controller.closeShowingTabOrWindow()
        } else {
            performClose(sender)
        }
    }
}
