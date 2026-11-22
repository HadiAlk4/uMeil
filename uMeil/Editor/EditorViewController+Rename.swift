import AppKit

/// Edit > Rename Symbol (`F2` or `⌃⌘E`): renames the function, variable,
/// or macro at the cursor everywhere `clangd` knows it is used, in one undo.
@MainActor
extension EditorViewController {
    @objc func renameSymbol(_ sender: Any?) {
        Task { await performRename() }
    }

    /// Asks for a new name for the symbol at the cursor and applies the
    /// edits. Problems, such as a name from TivaWare, are shown instead.
    func performRename() async {
        guard intelligence.isEnabled,
              let url = document?.url,
              SourceLanguage(url: url) == .c,
              let onPrepareRename = intelligence.onPrepareRename,
              let onRename = intelligence.onRename
        else { return }

        // The cursor is often just after the name, as after typing it.
        let cursor = textView.selectedRange().location
        let offset = identifierRange(atCharacterIndex: cursor) == nil ? max(cursor - 1, 0) : cursor
        guard let wordRange = identifierRange(atCharacterIndex: offset) else {
            NSSound.beep()
            return
        }
        let text = textView.string
        let version = textVersion
        let position = lineIndex.lspPosition(atUTF16Offset: offset)
        do {
            let nameRange = try await onPrepareRename(url, text, position).map { lineIndex.utf16Range(for: $0) }
            let oldName = (text as NSString).substring(with: nameRange ?? wordRange)
            guard let newName = await promptForNewName(replacing: oldName),
                  newName != oldName,
                  version == textVersion,
                  document?.url == url
            else { return }
            let edits = try await onRename(url, text, position, newName)
            guard version == textVersion, document?.url == url else { return }
            try applyRenameEdits(edits)
        } catch {
            await showRenameProblem(error.localizedDescription)
        }
    }

    /// Applies `edits` to each file: the showing one in the editor (undoable),
    /// a background tab's unsaved text, or a closed file on disk.
    func applyRenameEdits(_ edits: [URL: [LSPTextEdit]]) throws {
        for (file, fileEdits) in edits {
            let target = ClangdSession.normalize(file)
            if let document, ClangdSession.normalize(document.url) == target {
                applyEditsToTextView(fileEdits, actionName: "Rename")
            } else if let tabURL = tabs.urls.first(where: { ClangdSession.normalize($0) == target }),
                      let tab = tabs.tab(for: tabURL),
                      let unsaved = tab.unsavedText {
                tabs.stash(tabURL, unsavedText: Self.applying(fileEdits, to: unsaved), selection: tab.selection)
            } else {
                var onDisk = try TextDocument.load(from: file)
                onDisk.text = Self.applying(fileEdits, to: onDisk.text)
                try onDisk.save()
            }
        }
        refreshTabBar()
    }

    /// Replaces each edit's range in the editor, last first so earlier
    /// ranges stay valid, as a single undo step.
    func applyEditsToTextView(_ edits: [LSPTextEdit], actionName: String) {
        let replacements = edits
            .map { (range: lineIndex.utf16Range(for: $0.range), text: $0.newText) }
            .sorted { $0.range.location > $1.range.location }
        guard !replacements.isEmpty, let storage = textView.textStorage else { return }
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        var previousStart = Int.max
        for replacement in replacements where NSMaxRange(replacement.range) <= previousStart {
            guard textView.shouldChangeText(in: replacement.range, replacementString: replacement.text) else {
                continue
            }
            storage.replaceCharacters(in: replacement.range, with: replacement.text)
            textView.didChangeText()
            previousStart = replacement.range.location
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(actionName)
    }

    /// `text` with `edits` applied; overlapping edits after the first are skipped.
    static func applying(_ edits: [LSPTextEdit], to text: String) -> String {
        let index = LineIndex(text)
        let result = NSMutableString(string: text)
        var previousStart = Int.max
        let sorted = edits
            .map { (range: index.utf16Range(for: $0.range), text: $0.newText) }
            .sorted { $0.range.location > $1.range.location }
        for edit in sorted where NSMaxRange(edit.range) <= previousStart {
            result.replaceCharacters(in: edit.range, with: edit.text)
            previousStart = edit.range.location
        }
        return result as String
    }

    // MARK: - Asking and telling

    private func promptForNewName(replacing oldName: String) async -> String? {
        if let prompt = intelligence.renamePrompt {
            return await prompt(oldName)
        }
        let alert = NSAlert()
        alert.messageText = "Rename “\(oldName)”"
        alert.informativeText = "Every use in the project is renamed. You can undo it with ⌘Z."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: oldName)
        field.font = EditorTheme.font
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = await present(alert)
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return response == .alertFirstButtonReturn && !name.isEmpty ? name : nil
    }

    private func showRenameProblem(_ message: String) async {
        if let handler = intelligence.renameProblemHandler {
            handler(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Couldn’t rename"
        alert.informativeText = message
        _ = await present(alert)
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = view.window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
