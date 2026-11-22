import AppKit

extension MainWindowController {
    /// File > Open Quickly… (⌘⇧O)
    @objc func openQuickly(_ sender: Any?) {
        guard let folder else {
            NSSound.beep()
            return
        }
        quickOpen.onOpen = { [weak self] url in self?.openFile(url) }
        quickOpen.show(folder: folder, openFiles: editor.tabs.urls, over: window)
    }
}
