import AppKit

extension EditorViewController {
    /// Keeps the showing file's unsaved text and cursor in its tab, before
    /// another file takes its place in the text view.
    func stashShowingTab() {
        guard let url = document?.url else { return }
        tabs.stash(url, unsavedText: isModified ? textView.string : nil, selection: textView.selectedRange())
    }

    /// Redraws the tab strip from `tabs`.
    func refreshTabBar() {
        let showing = document?.url.standardizedFileURL
        let titles = tabs.titles()
        let items = tabs.tabs.enumerated().map { index, tab in
            let isShowing = tab.url.standardizedFileURL == showing
            return EditorTabBar.Item(
                url: tab.url,
                title: titles[index],
                isModified: isShowing ? isModified : tab.isModified,
                isSelected: isShowing
            )
        }
        tabBar.show(items)
    }

    /// Whether `url` has changes that are not saved, showing or not.
    func hasUnsavedChanges(_ url: URL) -> Bool {
        if isShowing(url) {
            return isModified
        }
        return tabs.tab(for: url)?.isModified == true
    }

    /// Every open file with unsaved changes, the showing one first.
    var unsavedFiles: [URL] {
        let showing = document.flatMap { isModified ? $0.url : nil }
        let background = tabs.tabs.filter { $0.isModified && !isShowing($0.url) }.map(\.url)
        return (showing.map { [$0] } ?? []) + background
    }

    /// Writes every file with unsaved changes, in every tab, to disk.
    func saveAll() throws {
        if isModified {
            try save()
        }
        for tab in tabs.tabs where tab.isModified && !isShowing(tab.url) {
            try write(tab)
        }
        refreshTabBar()
    }

    /// Saves the tab for `url`, showing or not.
    func saveTab(_ url: URL) throws {
        if isShowing(url) {
            try save()
        } else if let tab = tabs.tab(for: url), tab.isModified {
            try write(tab)
            refreshTabBar()
        }
    }

    /// Closes the tab for `url`, dropping any unsaved changes in it, so ask
    /// the user first. Returns the file to show next when it was showing.
    @discardableResult
    func closeTab(_ url: URL) -> URL? {
        let wasShowing = isShowing(url)
        let next = tabs.remove(url)
        if wasShowing {
            close(hasFolder: true, keepingTabs: true)
        }
        refreshTabBar()
        return next
    }

    private func write(_ tab: EditorTabs.Tab) throws {
        guard let text = tab.unsavedText else { return }
        var file = try TextDocument.load(from: tab.url)
        file.text = text
        try file.save()
        tabs.markSaved(tab.url)
    }

    private func isShowing(_ url: URL) -> Bool {
        document?.url.standardizedFileURL == url.standardizedFileURL
    }
}
