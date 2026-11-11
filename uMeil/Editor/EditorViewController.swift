import AppKit

/// The code editor: a plain AppKit text view with line numbers, undo, and
/// the system find-and-replace bar.
final class EditorViewController: NSViewController, NSTextViewDelegate {
    /// The file being edited, or `nil` when the editor is empty.
    private(set) var document: TextDocument?

    /// Whether the text has changed since it was opened or last saved.
    private(set) var isModified = false {
        didSet {
            if oldValue != isModified {
                onModifiedChanged?(isModified)
            }
        }
    }

    /// Called when `isModified` flips.
    var onModifiedChanged: ((Bool) -> Void)?

    let textView: NSTextView
    private let scrollView = NSScrollView()
    private var ruler: LineNumberRulerView?
    private let placeholderLabel = NSTextField(labelWithString: "")
    private lazy var openFolderButton = NSButton(
        title: "Open Folder…",
        target: nil,
        action: #selector(MainWindowController.chooseFolder(_:))
    )
    private lazy var placeholder = NSStackView(views: [placeholderLabel, openFolderButton])

    /// True while the editor itself is replacing the text, so that loading a
    /// file is not mistaken for the user editing it.
    private var isLoading = false

    /// `nil` if the C grammar failed to load; the editor then shows plain text.
    private let highlighter = try? CSyntaxHighlighter()
    private var highlights = HighlightMap.empty
    private var highlightTask: Task<Void, Never>?
    /// Counts edits, so that highlights computed for older text are dropped.
    private var textVersion = 0

    /// Line positions for the current text, shared with the gutter.
    private var lineIndex = LineIndex("") {
        didSet { ruler?.lineIndex = lineIndex }
    }

    init() {
        textView = Self.makeTextView()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorViewController is created in code, not from a nib")
    }

    // MARK: - Setup

    /// Builds a text view that does not wrap lines and scrolls sideways,
    /// with every "smart" text feature that would corrupt source code off.
    private static func makeTextView() -> NSTextView {
        let unlimited = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        // TextKit 1, built by hand: the line number gutter needs the layout manager.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: unlimited)
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
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

    override func loadView() {
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        self.ruler = ruler

        // Line numbers must follow the text as it scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        // Making the window bigger also brings new lines into view.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorDidScroll(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        placeholderLabel.font = .preferredFont(forTextStyle: .title3)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholder.orientation = .vertical
        placeholder.spacing = 12

        let container = NSView()
        for subview in [scrollView, placeholder] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        view = container

        showPlaceholder(hasFolder: false)
    }

    @objc private func editorDidScroll(_ notification: Notification) {
        ruler?.needsDisplay = true
        applyVisibleHighlights()
    }

    // MARK: - Opening and saving

    /// Shows `url` in the editor. Any unsaved changes to the previous file
    /// are discarded, so callers must ask the user first.
    func open(_ url: URL) throws {
        let loaded = try TextDocument.load(from: url)
        loadViewIfNeeded()

        isLoading = true
        textView.string = loaded.text
        textView.textStorage?.setAttributes(
            EditorTheme.textAttributes,
            range: NSRange(location: 0, length: (loaded.text as NSString).length)
        )
        textView.typingAttributes = EditorTheme.textAttributes
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        isLoading = false

        document = loaded
        isModified = false
        lineIndex = LineIndex(loaded.text)
        setMarkers([:])
        scrollView.isHidden = false
        placeholder.isHidden = true
        scheduleHighlighting(delay: .zero)
    }

    /// Writes the editor's text to the file it was opened from.
    func save() throws {
        guard var current = document else { return }
        current.text = textView.string
        try current.save()
        document = current
        isModified = false
    }

    /// Empties the editor and shows a hint in its place.
    func close(hasFolder: Bool) {
        loadViewIfNeeded()
        isLoading = true
        textView.string = ""
        textView.undoManager?.removeAllActions()
        isLoading = false

        document = nil
        isModified = false
        lineIndex = LineIndex("")
        setMarkers([:])
        showPlaceholder(hasFolder: hasFolder)
        scheduleHighlighting(delay: .zero)
    }

    private func showPlaceholder(hasFolder: Bool) {
        placeholderLabel.stringValue = hasFolder ? "Select a file to edit" : "Open a folder to get started"
        openFolderButton.isHidden = hasFolder
        scrollView.isHidden = true
        placeholder.isHidden = false
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        let lineCount = lineIndex.lineCount
        lineIndex = LineIndex(textView.string)
        if lineIndex.lineCount != lineCount {
            // Lines moved, so the markers from the last build no longer line up.
            setMarkers([:])
        }
        isModified = true
        // Wait for a short pause in typing before parsing again.
        scheduleHighlighting(delay: .milliseconds(40))
    }

    // MARK: - Build messages

    /// The lines currently flagged in the gutter.
    private(set) var markers: [Int: Diagnostic.Severity] = [:]

    /// Flags lines in the gutter with the errors and warnings from a build.
    func setMarkers(_ markers: [Int: Diagnostic.Severity]) {
        self.markers = markers
        ruler?.lineMarkers = markers
    }

    /// Moves the cursor to a line and column (both 1-based, as the compiler
    /// reports them) and scrolls it into view.
    func goTo(line: Int, column: Int?) {
        guard let offset = lineIndex.offset(line: line, column: column ?? 1) else { return }
        let range = NSRange(location: min(offset, lineIndex.length), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Syntax highlighting

    /// Starts highlighting the current text in the background, replacing any
    /// run that is still in progress.
    private func scheduleHighlighting(delay: Duration) {
        textVersion += 1
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.rehighlight()
        }
    }

    /// Parses the current text and colors it. The parsing happens off the
    /// main thread; if the text changes meanwhile, the result is dropped.
    func rehighlight() async {
        let version = textVersion
        var tokens: [HighlightToken] = []
        if let highlighter, let url = document?.url, SourceLanguage(url: url) == .c {
            tokens = await highlighter.tokens(in: textView.string)
        }
        guard version == textVersion else { return }

        highlights = HighlightMap(tokens: tokens)
        applyVisibleHighlights()
    }

    /// Colors the part of the text that is on screen. Colors are "temporary
    /// attributes": they change how text is drawn without touching the text
    /// itself, so they do not affect undo or cause the text to be laid out again.
    private func applyVisibleHighlights() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let length = textView.textStorage?.length
        else { return }

        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard visible.length > 0 else { return }

        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: visible)
        for token in highlights.tokens(intersecting: visible) {
            // Tokens can be briefly out of date after an edit; stay in bounds.
            let range = NSIntersectionRange(token.range, NSRange(location: 0, length: length))
            guard range.length > 0 else { continue }
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: EditorTheme.color(for: token.kind),
                forCharacterRange: range
            )
        }
    }
}
