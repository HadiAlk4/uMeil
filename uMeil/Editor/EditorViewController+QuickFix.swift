import AppKit

/// Fetches LSP quick-fix code actions for live diagnostics and applies them in one click.
@MainActor
extension EditorViewController {
    /// Shows the diagnostic on the cursor's line, with its one-click fix if it has one.
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

    private static let maxQuickFixDiagnosticQueries = 12

    func clearQuickFixes() {
        intelligence.quickFixTask?.cancel()
        intelligence.quickFixTask = nil
        intelligence.quickFixesByDiagnostic.removeAll()
        (textView as? EditorTextView)?.inlineQuickFixes = []
        diagnosticBar.updateQuickFix(nil)
    }

    /// Queries `clangd` for quick-fix code actions on the active live diagnostics and updates
    /// both the diagnostic bar's Fix button and clickable inline error capsules.
    func refreshQuickFixes(for diagnostics: [LSPDiagnostic]) {
        clearQuickFixes()
        guard intelligence.isEnabled,
              let url = document?.url,
              SourceLanguage(url: url) == .c,
              let onCodeActionsRequested = intelligence.onCodeActionsRequested
        else { return }

        let candidates = quickFixQueryCandidates(from: diagnostics)
        guard !candidates.isEmpty else { return }

        let requestVersion = textVersion
        let text = textView.string
        let diagnosticsSnapshot = diagnostics

        intelligence.quickFixTask = Task { [weak self] in
            for diagnostic in candidates {
                let actions = await onCodeActionsRequested(url, text, diagnostic.range, [diagnostic])
                guard let self,
                      !Task.isCancelled,
                      self.intelligence.isEnabled,
                      self.textVersion == requestVersion,
                      self.document?.url == url,
                      self.intelligence.liveDiagnostics == diagnosticsSnapshot
                else { return }

                if let preferred = LSPCodeAction.preferredQuickFix(from: actions, targeting: url) {
                    self.intelligence.quickFixesByDiagnostic[diagnostic] = preferred
                    self.syncQuickFixUI()
                }
            }
        }
    }

    /// Refreshes the diagnostic bar Fix button and inline quick-fix capsules from cached actions.
    func syncQuickFixUI() {
        updateDiagnosticBar()
        guard let editorTextView = textView as? EditorTextView else { return }
        editorTextView.inlineQuickFixes = buildInlineQuickFixes()
    }

    /// Applies `action` to the open document as a single undoable edit if it passes security checks.
    @discardableResult
    func applyQuickFix(_ action: LSPCodeAction) -> Bool {
        guard intelligence.isEnabled, let url = document?.url else { return false }
        return DiagnosticQuickFix.apply(action, targeting: url, to: textView)
    }

    private func quickFixQueryCandidates(from diagnostics: [LSPDiagnostic]) -> [LSPDiagnostic] {
        let actionable = diagnostics.filter { $0.diagnosticSeverity != .note }
        guard !actionable.isEmpty else { return [] }

        var ordered: [LSPDiagnostic] = []
        var seenLines: Set<Int> = []
        let cursorLine = lineIndex.lineNumber(atOffset: textView.selectedRange().location) - 1
        if let active = EditorDiagnosticBar.selectedDiagnostic(from: actionable, cursorLineZeroBased: cursorLine) {
            ordered.append(active)
            seenLines.insert(active.range.start.line)
        }

        let sorted = actionable.sorted { lhs, rhs in
            if lhs.range.start.line != rhs.range.start.line {
                return lhs.range.start.line < rhs.range.start.line
            }
            return (lhs.severity ?? .error) < (rhs.severity ?? .error)
        }
        for diagnostic in sorted where ordered.count < Self.maxQuickFixDiagnosticQueries {
            if seenLines.insert(diagnostic.range.start.line).inserted {
                ordered.append(diagnostic)
            }
        }
        return ordered
    }

    private func buildInlineQuickFixes() -> [EditorTextView.InlineQuickFix] {
        let actionable = intelligence.liveDiagnostics.filter { $0.diagnosticSeverity != .note }
        var byLine: [Int: [LSPDiagnostic]] = [:]
        for diagnostic in actionable {
            byLine[diagnostic.range.start.line + 1, default: []].append(diagnostic)
        }

        var items: [EditorTextView.InlineQuickFix] = []
        for (line, lineDiagnostics) in byLine {
            let sorted = lineDiagnostics.sorted { ($0.severity ?? .error) < ($1.severity ?? .error) }
            guard let fixable = sorted.first(where: { intelligence.quickFixesByDiagnostic[$0] != nil }),
                  let action = intelligence.quickFixesByDiagnostic[fixable],
                  let lineStart = lineIndex.offset(line: line, column: 1)
            else { continue }

            items.append(EditorTextView.InlineQuickFix(
                lineStart: lineStart,
                severity: fixable.diagnosticSeverity,
                message: fixable.message,
                moreCount: max(0, lineDiagnostics.count - 1),
                action: action
            ))
        }
        return items.sorted { $0.lineStart < $1.lineStart }
    }
}
