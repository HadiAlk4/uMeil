import AppKit

/// Per-editor state and callbacks for `clangd` code intelligence, kept in one
/// container so `EditorViewController` stays concise and conflict-free.
@MainActor
final class EditorCodeIntelligenceState {
    var onDocumentOpened: ((URL, String) -> Void)?
    var onDocumentChanged: ((URL, String) -> Void)?
    var onDocumentSaved: ((URL, String) -> Void)?
    var onDocumentClosed: ((URL) -> Void)?
    var onCompletionRequested: ((URL, String, LSPPosition) async -> [LSPCompletionItem])?
    var onDefinitionRequested: ((URL, String, LSPPosition) async -> Void)?
    var onSignatureHelpRequested: ((URL, String, LSPPosition) async -> LSPSignatureHelp?)?
    var onHoverRequested: ((URL, String, LSPPosition) async -> LSPHover?)?
    var onPrepareRename: ((URL, String, LSPPosition) async throws -> LSPRange?)?
    var onRename: ((URL, String, LSPPosition, String) async throws -> [URL: [LSPTextEdit]])?
    /// Replace the new-name and problem alerts, for tests.
    var renamePrompt: ((String) async -> String?)?
    var renameProblemHandler: ((String) -> Void)?
    /// Formats the given 1-based lines of a file's text with clang-format.
    var onFormatRequested: ((URL, String, ClosedRange<Int>) async throws -> String)?
    var formatProblemHandler: ((String) -> Void)?
    var onCodeActionsRequested: ((URL, String, LSPRange, [LSPDiagnostic]) async -> [LSPCodeAction])?

    let diagnosticBar = EditorDiagnosticBar()
    let completionPanel = CompletionPanelController()
    let signaturePanel = CodeInfoPanel()
    let hoverPanel = CodeInfoPanel()

    var buildMarkers: [Int: Diagnostic.Severity] = [:]
    /// The last build's message for each line, written beside the code.
    var buildMessages: [Int: BuildSummary.LineMessage] = [:]
    var liveDiagnostics: [LSPDiagnostic] = []
    var quickFixesByDiagnostic: [LSPDiagnostic: LSPCodeAction] = [:]
    var quickFixTask: Task<Void, Never>?
    var diagnosticRanges: [NSRange] = []
    var completionAnchorOffset: Int?
    var completionRequestVersion = 0
    var completionTask: Task<Void, Never>?
    var lastEditWasSingleTypedCharacter = false
    /// The arguments left to fill in after accepting a snippet completion.
    var placeholders: SnippetPlaceholders?
    /// The parameter hint showing, and the request refreshing it.
    var signatureHelp: LSPSignatureHelp?
    var signatureTask: Task<Void, Never>?
    /// The name under the mouse whose hover is showing or on its way.
    var hoverRange: NSRange?
    /// When false the editor shows no live diagnostics, never asks for
    /// completions, and ignores go-to-definition requests.
    var isEnabled = true
}

/// Connects `EditorViewController` to live `clangd` diagnostics, autocomplete,
/// and go-to-definition without modifying the gutter ruler view.
@MainActor
extension EditorViewController {
    private var editorTextView: EditorTextView? { textView as? EditorTextView }
    var completionPanel: CompletionPanelController { intelligence.completionPanel }
    var diagnosticBar: EditorDiagnosticBar { intelligence.diagnosticBar }
    var liveDiagnostics: [LSPDiagnostic] { intelligence.liveDiagnostics }

    func configureCodeIntelligence() {
        editorTextView?.onCommandClick = { [weak self] offset in
            self?.requestDefinition(atUTF16Offset: offset)
        }
        editorTextView?.onHoverCharacter = { [weak self] offset in
            self?.hoverMoved(toCharacterIndex: offset)
        }
        editorTextView?.onRequestCompletion = { [weak self] in
            self?.triggerCompletion(nil)
        }
        editorTextView?.onRequestRename = { [weak self] in
            self?.renameSymbol(nil)
        }
        editorTextView?.completionKeyHandler = { [weak self] event in
            guard let self else { return false }
            if completionPanel.handleKeyDown(event) { return true }
            if event.keyCode == 53, signaturePanel.isVisible {
                dismissSignatureHelp()
                endPlaceholders()
                return true
            }
            return handlePlaceholderKey(event)
        }
        completionPanel.onAccept = { [weak self] item in
            self?.acceptCompletion(item)
        }
        diagnosticBar.onClick = { [weak self] diagnostic in
            self?.goTo(
                line: diagnostic.range.start.line + 1,
                column: diagnostic.range.start.character + 1
            )
        }
        diagnosticBar.onQuickFix = { [weak self] action in
            self?.applyQuickFix(action)
        }
        editorTextView?.onQuickFixClick = { [weak self] action in
            self?.applyQuickFix(action)
        }
    }

    /// Turns live diagnostics, autocomplete, and go-to-definition on or off.
    /// Turning them off clears what is showing right away.
    func setCodeIntelligenceEnabled(_ enabled: Bool) {
        intelligence.isEnabled = enabled
        guard !enabled else { return }
        dismissCodeIntelligencePopups()
        clearLiveDiagnostics()
    }

    /// Closes the completion list, parameter hint, and hover, and forgets
    /// any placeholders, as when another file opens.
    func dismissCodeIntelligencePopups() {
        intelligence.completionTask?.cancel()
        intelligence.completionTask = nil
        intelligence.completionAnchorOffset = nil
        completionPanel.dismiss()
        endPlaceholders()
        dismissSignatureHelp()
        dismissCodeHover()
    }

    // MARK: - Inline diagnostics

    /// Displays `diagnostics` from `clangd` as inline underlines, tooltips,
    /// gutter markers, and a compact diagnostic strip while typing.
    func applyLiveDiagnostics(_ diagnostics: [LSPDiagnostic]) {
        guard intelligence.isEnabled else { return }
        clearInlineDiagnosticAttributes()
        intelligence.liveDiagnostics = diagnostics
        refreshRulerMarkers()

        if let layoutManager = textView.layoutManager {
            let textLength = textView.textStorage?.length ?? 0
            for diagnostic in diagnostics where diagnostic.diagnosticSeverity != .note {
                let rawRange = lineIndex.utf16Range(for: diagnostic.range)
                guard let range = Self.visibleUnderlineRange(for: rawRange, textLength: textLength) else {
                    continue
                }
                let color = diagnostic.diagnosticSeverity == .error
                    ? EditorTheme.inlineErrorColor
                    : EditorTheme.inlineWarningColor
                let style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                layoutManager.addTemporaryAttribute(.underlineStyle, value: style, forCharacterRange: range)
                layoutManager.addTemporaryAttribute(.underlineColor, value: color, forCharacterRange: range)
                layoutManager.addTemporaryAttribute(.toolTip, value: diagnostic.message, forCharacterRange: range)
                intelligence.diagnosticRanges.append(range)
            }
        }
        updateDiagnosticBar()
        refreshQuickFixes(for: diagnostics)
    }

    func clearLiveDiagnostics() {
        clearInlineDiagnosticAttributes()
        clearQuickFixes()
        if !intelligence.liveDiagnostics.isEmpty {
            intelligence.liveDiagnostics = []
            refreshRulerMarkers()
        }
        diagnosticBar.update(diagnostics: [], cursorLineZeroBased: 0)
    }

    func updateDiagnosticBar() {
        let cursorLine = lineIndex.lineNumber(atOffset: textView.selectedRange().location) - 1
        let selected = EditorDiagnosticBar.selectedDiagnostic(
            from: intelligence.liveDiagnostics,
            cursorLineZeroBased: cursorLine
        )
        let quickFix = selected.flatMap { intelligence.quickFixesByDiagnostic[$0] }
        diagnosticBar.update(
            diagnostics: intelligence.liveDiagnostics,
            cursorLineZeroBased: cursorLine,
            quickFix: quickFix
        )
    }

    private func clearInlineDiagnosticAttributes() {
        guard let layoutManager = textView.layoutManager else {
            intelligence.diagnosticRanges.removeAll()
            return
        }
        let textLength = textView.textStorage?.length ?? 0
        for stored in intelligence.diagnosticRanges {
            let clamped = NSIntersectionRange(stored, NSRange(location: 0, length: textLength))
            guard clamped.length > 0 else { continue }
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: clamped)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: clamped)
            layoutManager.removeTemporaryAttribute(.toolTip, forCharacterRange: clamped)
        }
        intelligence.diagnosticRanges.removeAll()
    }

    /// Expands zero-width diagnostic points (e.g. missing semicolon at end of line)
    /// to at least one character so the underline remains visible.
    static func visibleUnderlineRange(for range: NSRange, textLength: Int) -> NSRange? {
        guard textLength > 0 else { return nil }
        let start = min(max(range.location, 0), textLength - 1)
        let length = range.length > 0 ? min(range.length, textLength - start) : 1
        return length > 0 ? NSRange(location: start, length: length) : nil
    }

    // MARK: - Autocomplete

    /// Edit > Complete (`Ctrl+Space` / `Opt+Esc`)
    @objc func triggerCompletion(_ sender: Any?) {
        guard intelligence.isEnabled else { return }
        intelligence.completionTask?.cancel()
        intelligence.completionTask = Task { [weak self] in
            await self?.performCompletionRequest()
        }
    }

    func handleTypingCompletionTrigger() {
        let cursor = textView.selectedRange().location
        if completionPanel.isVisible {
            guard let anchor = intelligence.completionAnchorOffset,
                  let prefix = currentIdentifierSlice(from: anchor, to: cursor)
            else {
                completionPanel.dismiss()
                intelligence.completionAnchorOffset = nil
                return
            }
            completionPanel.updateFilter(prefix)
            return
        }

        guard intelligence.isEnabled,
              intelligence.lastEditWasSingleTypedCharacter,
              let url = document?.url,
              SourceLanguage(url: url) == .c,
              shouldAutoTriggerCompletion(in: textView.string, atUTF16Offset: cursor)
        else { return }

        intelligence.completionTask?.cancel()
        intelligence.completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.performCompletionRequest()
        }
    }

    func handleSelectionChangeForCodeIntelligence() {
        updateDiagnosticBar()
        handleSelectionChangeForSignatureHelp()
        guard completionPanel.isVisible else { return }
        let cursor = textView.selectedRange().location
        guard let anchor = intelligence.completionAnchorOffset,
              currentIdentifierSlice(from: anchor, to: cursor) != nil
        else {
            completionPanel.dismiss()
            intelligence.completionAnchorOffset = nil
            return
        }
    }

    func performCompletionRequest() async {
        guard intelligence.isEnabled,
              let url = document?.url,
              SourceLanguage(url: url) == .c,
              let onCompletionRequested = intelligence.onCompletionRequested
        else { return }

        let cursor = textView.selectedRange().location
        let text = textView.string
        let prefixRange = Self.identifierPrefixRange(in: text, atUTF16Offset: cursor)
        let anchorOffset = prefixRange.location
        let requestVersion = textVersion
        intelligence.completionRequestVersion = requestVersion
        let position = lineIndex.lspPosition(atUTF16Offset: cursor)

        // Ask which argument the cursor is in at the same time, so macros
        // that fit it (GPIO_PIN_* for ui8Pins) can be listed first.
        let onSignatureHelpRequested = intelligence.onSignatureHelpRequested
        let signature = Task { await onSignatureHelpRequested?(url, text, position) }
        let items = await onCompletionRequested(url, text, position)
        let hint = await signature.value.flatMap(ArgumentHint.init(signatureHelp:))
        guard !Task.isCancelled,
              intelligence.isEnabled,
              requestVersion == intelligence.completionRequestVersion,
              document?.url == url
        else { return }

        let latestCursor = textView.selectedRange().location
        guard let liveFilter = currentIdentifierSlice(from: anchorOffset, to: latestCursor) else {
            return
        }

        intelligence.completionAnchorOffset = anchorOffset
        let anchorRange = NSRange(location: min(anchorOffset, lineIndex.length), length: 0)
        let screenRect = textView.firstRect(forCharacterRange: anchorRange, actualRange: nil)
        completionPanel.show(
            items: items,
            filter: liveFilter,
            hint: hint,
            anchoredAt: screenRect,
            parentWindow: view.window
        )
    }

    func acceptCompletion(_ item: LSPCompletionItem) {
        let cursor = textView.selectedRange().location
        let anchor = intelligence.completionAnchorOffset
            ?? Self.identifierPrefixRange(in: textView.string, atUTF16Offset: cursor).location
        intelligence.completionAnchorOffset = nil
        guard cursor >= anchor, cursor <= (textView.textStorage?.length ?? 0) else { return }

        let replaceRange = NSRange(location: anchor, length: cursor - anchor)
        let snippet = item.snippet
        insertSnippet(snippet, replacing: replaceRange)
        if !snippet.placeholders.isEmpty {
            // The first argument is selected: show what goes there.
            requestSignatureHelp(delay: .zero)
        }
    }

    func shouldAutoTriggerCompletion(in text: String, atUTF16Offset offset: Int) -> Bool {
        let prefixRange = Self.identifierPrefixRange(in: text, atUTF16Offset: offset)
        if prefixRange.length >= 2 { return true }
        let nsText = text as NSString
        guard offset >= 1, offset <= nsText.length else { return false }
        let previous = nsText.character(at: offset - 1)
        if previous == UInt16(UInt8(ascii: ".")) { return true }
        if previous == UInt16(UInt8(ascii: ">")),
           offset >= 2,
           nsText.character(at: offset - 2) == UInt16(UInt8(ascii: "-")) {
            return true
        }
        return false
    }

    static func identifierPrefixRange(in text: String, atUTF16Offset offset: Int) -> NSRange {
        let nsText = text as NSString
        let end = min(max(offset, 0), nsText.length)
        var start = end
        while start > 0, isIdentifierCodeUnit(nsText.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    private func currentIdentifierSlice(from anchor: Int, to cursor: Int) -> String? {
        let nsText = textView.string as NSString
        guard anchor >= 0, cursor >= anchor, cursor <= nsText.length else { return nil }
        let slice = nsText.substring(with: NSRange(location: anchor, length: cursor - anchor))
        guard slice.utf16.allSatisfy(Self.isIdentifierCodeUnit) else { return nil }
        return slice
    }

    static func isIdentifierCodeUnit(_ unit: UInt16) -> Bool {
        (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit) || (0x30...0x39).contains(unit) || unit == 0x5F
    }

    // MARK: - Go to definition

    func requestDefinition(atUTF16Offset offset: Int? = nil) {
        guard intelligence.isEnabled,
              let url = document?.url,
              SourceLanguage(url: url) == .c,
              let onDefinitionRequested = intelligence.onDefinitionRequested
        else { return }

        let targetOffset = offset ?? textView.selectedRange().location
        let text = textView.string
        let position = lineIndex.lspPosition(atUTF16Offset: targetOffset)
        Task {
            await onDefinitionRequested(url, text, position)
        }
    }

    // MARK: - Delegate and menu hooks

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(formatSelection(_:)) {
            return document.map { SourceLanguage(url: $0.url) == .c } ?? false
        }
        if menuItem.action == #selector(triggerCompletion(_:)) || menuItem.action == #selector(renameSymbol(_:)) {
            return intelligence.isEnabled && (document.map { SourceLanguage(url: $0.url) == .c } ?? false)
        }
        return true
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard !isLoading else {
            intelligence.lastEditWasSingleTypedCharacter = false
            editorHighlightsCancelPendingTypedBracket()
            return true
        }
        intelligence.lastEditWasSingleTypedCharacter = replacementString?.count == 1 && affectedCharRange.length <= 1
        placeholdersWillChangeText(in: affectedCharRange, replacement: replacementString)
        editorHighlightsWillChangeText(in: affectedCharRange, replacementString: replacementString)
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        updateCursorPosition()
        placeholdersSelectionDidChange()
        editorHighlightsDidChangeSelection()
        handleSelectionChangeForCodeIntelligence()
    }
}
