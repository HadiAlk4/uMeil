import AppKit

extension EditorViewController {
    /// Writes the last build's messages at the end of the lines they are
    /// about, as Xcode does, so they can be read without the Issues panel.
    func setBuildMessages(_ messages: [Int: BuildSummary.LineMessage]) {
        intelligence.buildMessages = messages
        showBuildMessages()
    }

    /// Hands the messages to the text view at the current start of each line.
    func showBuildMessages() {
        guard let textView = textView as? EditorTextView else { return }
        textView.inlineMessages = intelligence.buildMessages.compactMap { line, message in
            lineIndex.offset(line: line, column: 1).map {
                EditorTextView.InlineMessage(lineStart: $0, message: message)
            }
        }
    }
}
