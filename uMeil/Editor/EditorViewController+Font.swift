import AppKit

extension EditorViewController {
    /// Redraws the code and the line numbers in the font picked in
    /// Settings, keeping the text, the cursor, and the undo history.
    func applyFontSettings() {
        loadViewIfNeeded()
        let font = EditorTheme.font
        let paragraphStyle = EditorTheme.paragraphStyle
        textView.font = font
        textView.defaultParagraphStyle = paragraphStyle
        if let storage = textView.textStorage, storage.length > 0 {
            let everything = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttributes([.font: font, .paragraphStyle: paragraphStyle], range: everything)
            storage.endEditing()
        }
        textView.typingAttributes = EditorTheme.textAttributes
        ruler?.fontDidChange()
        editorHighlightsDidChangeFont()
    }
}
