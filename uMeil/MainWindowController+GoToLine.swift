import AppKit

extension MainWindowController {
    /// Edit > Go to Line… (⌘L)
    @objc func showGoToLine(_ sender: Any?) {
        guard editor.document != nil else {
            NSSound.beep()
            return
        }
        goToLine.onJump = { [weak self] target in
            guard let self, self.editor.document != nil else { return }
            self.window?.makeKey()
            self.editor.goTo(line: target.line, column: target.column)
        }
        goToLine.onClose = { [weak self] in
            guard let self, let window = self.window else { return }
            let anotherWindowIsKey = NSApp.keyWindow != nil && NSApp.keyWindow !== window
            guard !anotherWindowIsKey else { return }
            window.makeKey()
            window.makeFirstResponder(self.editor.textView)
        }
        goToLine.show(lineCount: editor.lineIndex.lineCount, over: window)
    }
}
