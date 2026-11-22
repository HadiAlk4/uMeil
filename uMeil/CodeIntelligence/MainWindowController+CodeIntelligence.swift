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
        controller.isEnabled = isCodeIntelligenceEnabled
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
        editor.intelligence.onSignatureHelpRequested = { [weak controller] url, text, position in
            await controller?.signatureHelp(in: url, text: text, position: position)
        }
        editor.intelligence.onHoverRequested = { [weak controller] url, text, position in
            await controller?.hover(in: url, text: text, position: position)
        }
        editor.intelligence.onPrepareRename = { [weak controller] url, text, position in
            guard let controller else { throw RenameError.unavailable }
            return try await controller.prepareRename(in: url, text: text, position: position)
        }
        editor.intelligence.onRename = { [weak controller] url, text, position, newName in
            guard let controller else { throw RenameError.unavailable }
            return try await controller.rename(in: url, text: text, position: position, to: newName)
        }
        editor.intelligence.onDefinitionRequested = { [weak controller] url, text, position in
            await controller?.jumpToDefinition(in: url, text: text, position: position)
        }
        editor.intelligence.onCodeActionsRequested = { [weak controller] url, text, range, diagnostics in
            await controller?.codeActions(in: url, text: text, range: range, diagnostics: diagnostics) ?? []
        }
        configureFormatting()
    }

    /// Format Selection runs clang-format from the toolchain `clangd` came from.
    private func configureFormatting() {
        editor.intelligence.onFormatRequested = { [weak self] url, text, lines in
            let locator = self?.makeToolLocator() ?? .standard()
            guard let executable = ClangFormatter.locate(near: locator.locate(.clangd), locator: locator) else {
                throw ClangFormatter.Failure.notFound
            }
            return try await ClangFormatter(executable: executable).format(text, of: url, lines: lines)
        }
    }

    /// Where the Code Intelligence on/off choice is remembered.
    static let codeIntelligenceDefaultsKey = "CodeIntelligenceEnabled"

    /// Whether code intelligence is on, remembered between launches. On
    /// unless the user has turned it off.
    var isCodeIntelligenceEnabled: Bool {
        get { defaults.object(forKey: Self.codeIntelligenceDefaultsKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.codeIntelligenceDefaultsKey)
            codeIntelligence?.isEnabled = newValue
        }
    }

    /// Edit > Code Intelligence
    @objc func toggleCodeIntelligence(_ sender: Any?) {
        isCodeIntelligenceEnabled.toggle()
    }

    /// Whether Edit > Code Intelligence or Jump to Definition can run now.
    func isCodeIntelligenceActionEnabled(_ action: Selector?) -> Bool {
        guard action == #selector(jumpToDefinitionMenuAction(_:)) else { return true }
        return isCodeIntelligenceEnabled && (editor.document.map { SourceLanguage(url: $0.url) == .c } ?? false)
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
    func navigate(
        to file: URL,
        line: Int?,
        column: Int?,
        columnUnit: EditorViewController.ColumnUnit = .utf16
    ) {
        let isOpen = editor.document.map {
            ClangdSession.normalize($0.url) == ClangdSession.normalize(file)
        } ?? false
        if !isOpen {
            // The file that was showing keeps its unsaved changes in its tab.
            guard openFile(file) else { return }
        }
        if let line {
            editor.goTo(line: line, column: column, unit: columnUnit)
        }
    }

    func windowWillClose(_ notification: Notification) {
        codeIntelligence?.stop()
    }
}
