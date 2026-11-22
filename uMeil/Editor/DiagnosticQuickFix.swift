import AppKit

/// Pure quick-fix resolution, formatting, and undo-aware edit application for `NSTextView`.
enum DiagnosticQuickFix {
    struct ResolvedTextEdit: Equatable {
        var range: NSRange
        var newText: String
    }

    /// Validates `action` against `documentURL` and returns its UTF-16 text edits sorted in
    /// reverse document order. Returns `nil` if the action is not an enabled single-document
    /// quick-fix, targets any other URI, has no edits, or contains overlapping ranges.
    static func resolveEdits(
        from action: LSPCodeAction,
        targeting documentURL: URL,
        in text: String
    ) -> [ResolvedTextEdit]? {
        guard let lspEdits = action.quickFixEdits(targeting: documentURL) else { return nil }
        let lineIndex = LineIndex(text)
        let indexed = lspEdits.enumerated().map { index, edit in
            (index: index, edit: ResolvedTextEdit(range: lineIndex.utf16Range(for: edit.range), newText: edit.newText))
        }
        let sorted = indexed.sorted { lhs, rhs in
            if lhs.edit.range.location != rhs.edit.range.location {
                return lhs.edit.range.location > rhs.edit.range.location
            }
            if lhs.edit.range.length != rhs.edit.range.length {
                return lhs.edit.range.length > rhs.edit.range.length
            }
            return lhs.index > rhs.index
        }.map(\.edit)

        var earliestLocation = Int.max
        for edit in sorted {
            guard NSMaxRange(edit.range) <= earliestLocation else { return nil }
            earliestLocation = edit.range.location
        }
        return sorted
    }

    /// Applies `action`'s edits to `textView` in reverse document order as a single undoable step.
    @MainActor
    @discardableResult
    static func apply(_ action: LSPCodeAction, targeting documentURL: URL, to textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage,
              let resolved = resolveEdits(from: action, targeting: documentURL, in: textView.string)
        else { return false }

        let originalCursor = textView.selectedRange().location
        let undoManager = textView.undoManager
        textView.breakUndoCoalescing()
        if let undoManager, undoManager.groupsByEvent {
            while undoManager.groupingLevel > 0 {
                undoManager.endUndoGrouping()
            }
        }
        let previousGroupsByEvent = undoManager?.groupsByEvent ?? true
        undoManager?.groupsByEvent = false
        undoManager?.beginUndoGrouping()

        var appliedCount = 0
        for edit in resolved {
            guard textView.shouldChangeText(in: edit.range, replacementString: edit.newText) else {
                break
            }
            storage.replaceCharacters(in: edit.range, with: edit.newText)
            textView.didChangeText()
            appliedCount += 1
        }
        if appliedCount > 0 {
            undoManager?.setActionName(undoActionName(for: action))
        }
        undoManager?.endUndoGrouping()
        undoManager?.groupsByEvent = previousGroupsByEvent
        textView.breakUndoCoalescing()

        guard appliedCount == resolved.count else { return false }
        let updatedCursor = adjustedCursorOffset(
            from: originalCursor,
            applying: resolved,
            newLength: storage.length
        )
        textView.setSelectedRange(NSRange(location: updatedCursor, length: 0))
        return true
    }

    /// Computes where `original` cursor offset lands after `editsInReverseOrder` are applied.
    static func adjustedCursorOffset(
        from original: Int,
        applying editsInReverseOrder: [ResolvedTextEdit],
        newLength: Int
    ) -> Int {
        var offset = original
        for edit in editsInReverseOrder {
            let insertedLength = (edit.newText as NSString).length
            if NSMaxRange(edit.range) <= offset {
                offset += insertedLength - edit.range.length
            } else if edit.range.location < offset {
                offset = edit.range.location + insertedLength
            }
        }
        return min(max(offset, 0), newLength)
    }

    static func undoActionName(for action: LSPCodeAction) -> String {
        "Fix: \(action.title)"
    }

    static func tooltip(for action: LSPCodeAction) -> String {
        "Fix: \(action.title)"
    }

    /// Concise button label for the diagnostic bar, e.g. `"Fix: Include <stdio.h>"`.
    static func buttonTitle(for action: LSPCodeAction) -> String {
        var summary = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = summary.range(of: " for symbol ", options: .caseInsensitive) {
            summary = String(summary[..<range.lowerBound])
        }
        guard !summary.isEmpty else { return "Fix" }
        let maxLength = 34
        if summary.count > maxLength {
            summary = String(summary.prefix(maxLength - 1)) + "…"
        }
        return "Fix: \(summary)"
    }
}
