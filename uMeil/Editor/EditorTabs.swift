import Foundation

/// The files open in the editor's tabs, in order, and which one is showing.
///
/// Only the showing file lives in the text view. A tab in the background
/// keeps its unsaved text here, so switching tabs never asks to save and
/// never loses an edit.
struct EditorTabs: Equatable {
    struct Tab: Equatable {
        var url: URL
        /// The text typed since the file was last saved, while the tab is in
        /// the background. `nil` when it matches the file on disk.
        var unsavedText: String?
        /// Where the cursor was, so it comes back when the tab does.
        var selection = NSRange(location: 0, length: 0)

        var isModified: Bool { unsavedText != nil }
    }

    private(set) var tabs: [Tab] = []
    private(set) var selectedURL: URL?

    var isEmpty: Bool { tabs.isEmpty }
    var urls: [URL] { tabs.map(\.url) }

    func tab(for url: URL) -> Tab? {
        index(of: url).map { tabs[$0] }
    }

    func contains(_ url: URL) -> Bool { index(of: url) != nil }

    /// Shows `url`, adding a tab for it just after the showing one if it has none.
    mutating func select(_ url: URL) {
        if index(of: url) == nil {
            let position = selectedURL.flatMap(index(of:)).map { $0 + 1 } ?? tabs.endIndex
            tabs.insert(Tab(url: url), at: position)
        }
        selectedURL = tabs[index(of: url) ?? 0].url
    }

    /// Keeps the state of a tab that is going into the background.
    mutating func stash(_ url: URL, unsavedText: String?, selection: NSRange) {
        guard let index = index(of: url) else { return }
        tabs[index].unsavedText = unsavedText
        tabs[index].selection = selection
    }

    /// Forgets a background tab's unsaved text once it has been written out.
    mutating func markSaved(_ url: URL) {
        guard let index = index(of: url) else { return }
        tabs[index].unsavedText = nil
    }

    /// Removes the tab for `url`. Returns the tab to show instead when it
    /// was the showing one: the next tab, or the one before if it was last.
    @discardableResult
    mutating func remove(_ url: URL) -> URL? {
        guard let index = index(of: url) else { return nil }
        let wasSelected = tabs[index].url == selectedURL
        tabs.remove(at: index)
        guard wasSelected else { return nil }
        selectedURL = nil
        guard !tabs.isEmpty else { return nil }
        return tabs[min(index, tabs.count - 1)].url
    }

    mutating func removeAll() {
        tabs = []
        selectedURL = nil
    }

    /// The label for each tab: the file name, with its folder added when two
    /// open files share a name, as in "main.c — src".
    func titles() -> [String] {
        let names = tabs.map(\.url.lastPathComponent)
        return tabs.map { tab in
            let name = tab.url.lastPathComponent
            guard names.filter({ $0 == name }).count > 1 else { return name }
            return "\(name) — \(tab.url.deletingLastPathComponent().lastPathComponent)"
        }
    }

    private func index(of url: URL) -> Int? {
        let wanted = url.standardizedFileURL
        return tabs.firstIndex { $0.url.standardizedFileURL == wanted }
    }
}
