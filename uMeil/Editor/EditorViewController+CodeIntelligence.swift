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

    let diagnosticBar = EditorDiagnosticBar()
    let completionPanel = CompletionPanelController()

    var buildMarkers: [Int: Diagnostic.Severity] = [:]
    var liveDiagnostics: [LSPDiagnostic] = []
    var diagnosticRanges: [NSRange] = []
    var completionAnchorOffset: Int?
    var completionRequestVersion = 0
    var completionTask: Task<Void, Never>?
    var lastEditWasSingleTypedCharacter = false
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
        editorTextView?.onRequestCompletion = { [weak self] in
            self?.triggerCompletion(nil)
        }
        editorTextView?.completionKeyHandler = { [weak self] event in
            self?.completionPanel.handleKeyDown(event) ?? false
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
    }

    // MARK: - Inline diagnostics

    /// Displays `diagnostics` from `clangd` as inline underlines, tooltips,
    /// gutter markers, and a compact diagnostic strip while typing.
    func applyLiveDiagnostics(_ diagnostics: [LSPDiagnostic]) {
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
    }

    func clearLiveDiagnostics() {
        clearInlineDiagnosticAttributes()
        if !intelligence.liveDiagnostics.isEmpty {
            intelligence.liveDiagnostics = []
            refreshRulerMarkers()
        }
        diagnosticBar.update(diagnostics: [], cursorLineZeroBased: 0)
    }

    func updateDiagnosticBar() {
        let cursorLine = lineIndex.lineNumber(atOffset: textView.selectedRange().location) - 1
        diagnosticBar.update(diagnostics: intelligence.liveDiagnostics, cursorLineZeroBased: cursorLine)
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

        guard intelligence.lastEditWasSingleTypedCharacter,
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
        guard let url = document?.url,
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

        let items = await onCompletionRequested(url, text, position)
        guard !Task.isCancelled,
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
        textView.insertText(item.insertionText, replacementRange: replaceRange)
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

    private static func isIdentifierCodeUnit(_ unit: UInt16) -> Bool {
        (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit) || (0x30...0x39).contains(unit) || unit == 0x5F
    }

    // MARK: - Go to definition

    func requestDefinition(atUTF16Offset offset: Int? = nil) {
        guard let url = document?.url,
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
        if menuItem.action == #selector(triggerCompletion(_:)) {
            return document.map { SourceLanguage(url: $0.url) == .c } ?? false
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
            return true
        }
        intelligence.lastEditWasSingleTypedCharacter = replacementString?.count == 1 && affectedCharRange.length <= 1
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        handleSelectionChangeForCodeIntelligence()
    }
}
