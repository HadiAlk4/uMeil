import AppKit

/// Keeps the status line under the editor up to date.
extension EditorViewController {
    /// Puts the cursor's line and column in the status line. The column
    /// counts characters, so a tab or an emoji is one.
    func updateCursorPosition() {
        let text = textView.string as NSString
        guard document != nil else {
            statusBar.showPosition(line: nil, column: nil)
            return
        }
        // Mid-edit the selection can move before the line index catches
        // up; `textDidChange` calls this again once it has.
        guard lineIndex.length == text.length else { return }
        let location = min(textView.selectedRange().location, text.length)
        let line = lineIndex.lineNumber(atOffset: location)
        let start = min(lineIndex.offset(ofLine: line) ?? 0, location)
        let prefix = text.substring(with: NSRange(location: start, length: location - start))
        statusBar.showPosition(line: line, column: prefix.count + 1)
    }
}
