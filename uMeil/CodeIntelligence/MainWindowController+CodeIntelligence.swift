import AppKit

/// Connects `MainWindowController` to `clangd` code intelligence without
/// cluttering window management or conflicting with other milestone extensions.
@MainActor
extension MainWindowController {
    func configureCodeIntelligence() {
        let controller = CodeIntelligenceController(
            makeToolLocator: { [weak self] in
                self?.makeToolLocator() ?? .standard()
            },
            editor: editor,
            onNavigateToLocation: { [weak self] location in
                self?.navigate(to: location)
            }
        )
        codeIntelligence = controller

        editor.intelligence.onDocumentOpened = { [weak controller] url, text in
            controller?.fileOpened(url, text: text)
        }
        editor.intelligence.onDocumentChanged = { [weak controller] url, text in
            controller?.textChanged(in: url, text: text)
        }
        editor.intelligence.onDocumentSaved = { [weak controller] url, text in
            controller?.fileSaved(url, text: text)
        }
        editor.intelligence.onDocumentClosed = { [weak controller] url in
            controller?.fileClosed(url)
        }
        editor.intelligence.onCompletionRequested = { [weak controller] url, text, position in
            await controller?.completion(in: url, text: text, position: position) ?? []
        }
        editor.intelligence.onDefinitionRequested = { [weak controller] url, text, position in
            await controller?.jumpToDefinition(in: url, text: text, position: position)
        }
    }

    /// Edit > Jump to Definition (`⌃⌘J`) or context menu.
    @objc func jumpToDefinitionMenuAction(_ sender: Any?) {
        editor.requestDefinition()
    }

    /// Moves the editor to a definition returned by `clangd`, opening the
    /// target file (for example a `driverlib` header) if needed.
    func navigate(to location: LSPLocation) {
        guard let file = location.url else { return }
        navigate(to: file, line: location.range.start.line + 1, column: location.range.start.character + 1)
    }

    /// Opens `file` if it is not already open and moves the caret to `line`/`column`.
    func navigate(to file: URL, line: Int?, column: Int?) {
        let isOpen = editor.document.map {
            ClangdSession.normalize($0.url) == ClangdSession.normalize(file)
        } ?? false
        if !isOpen {
            guard confirmDiscardingChanges() else { return }
            openFile(file)
        }
        if let line {
            editor.goTo(line: line, column: column)
        }
    }

    func windowWillClose(_ notification: Notification) {
        codeIntelligence?.stop()
    }
}
