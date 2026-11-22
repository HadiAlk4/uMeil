import AppKit

/// Edit > Format Selection (`⌃I`): tidies the selected lines, or the
/// cursor's line, with `clang-format`, as one undo step.
@MainActor
extension EditorViewController {
    @objc func formatSelection(_ sender: Any?) {
        Task { await performFormatSelection() }
    }

    /// Formats the lines the selection touches. Returns `false` when
    /// nothing could be formatted (the problem is shown instead).
    @discardableResult
    func performFormatSelection() async -> Bool {
        guard let url = document?.url,
              SourceLanguage(url: url) == .c,
              let onFormatRequested = intelligence.onFormatRequested
        else { return false }

        let text = textView.string
        let version = textVersion
        let selection = textView.selectedRange()
        let firstLine = lineIndex.lineNumber(atOffset: selection.location)
        // A selection ending at the start of a line does not include that line.
        let endOffset = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        let lastLine = max(firstLine, lineIndex.lineNumber(atOffset: endOffset))

        let formatted: String
        do {
            formatted = try await onFormatRequested(url, text, firstLine...lastLine)
        } catch {
            showFormatProblem(error.localizedDescription)
            return false
        }
        guard version == textVersion, document?.url == url else { return false }
        guard let change = ClangFormatter.replacement(from: text, to: formatted) else { return true }

        replaceText(in: change.range, with: change.text, actionName: "Format Selection")
        // Keep the same lines selected, now formatted.
        let newIndex = LineIndex(formatted)
        let start = newIndex.offset(ofLine: firstLine) ?? 0
        let lineDelta = newIndex.lineCount - lineIndex.lineCount
        let lastRange = newIndex.range(ofLine: min(lastLine + lineDelta, newIndex.lineCount))
        let end = lastRange.map { NSMaxRange($0) } ?? newIndex.length
        if selection.length > 0, end > start {
            textView.setSelectedRange(NSRange(location: start, length: end - start))
        }
        return true
    }

    /// Replaces `range` as one undoable edit named `actionName`.
    func replaceText(in range: NSRange, with replacement: String, actionName: String) {
        guard let storage = textView.textStorage,
              textView.shouldChangeText(in: range, replacementString: replacement)
        else { return }
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(actionName)
    }

    private func showFormatProblem(_ message: String) {
        if let handler = intelligence.formatProblemHandler {
            handler(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Couldn’t format"
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
