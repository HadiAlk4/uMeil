import AppKit

extension EditorViewController {
    /// Builds a text view that does not wrap lines and scrolls sideways,
    /// with every "smart" text feature that would corrupt source code off.
    static func makeTextView() -> NSTextView {
        let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // TextKit 1, built by hand: the line number gutter needs the layout manager.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: unlimited)
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = unlimited
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.textContainerInset = NSSize(width: 4, height: 4)

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.font = EditorTheme.font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.defaultParagraphStyle = EditorTheme.paragraphStyle
        textView.typingAttributes = EditorTheme.textAttributes
        return textView
    }
}
