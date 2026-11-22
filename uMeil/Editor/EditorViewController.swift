import AppKit

/// The code editor: a plain AppKit text view with line numbers, undo, and
/// the system find-and-replace bar. Code intelligence wiring lives in
/// `EditorViewController+CodeIntelligence.swift`.
final class EditorViewController: NSViewController, NSTextViewDelegate, NSMenuItemValidation {
    /// The file being edited, or `nil` when the editor is empty.
    private(set) var document: TextDocument?

    /// Whether the text has changed since it was opened or last saved.
    private(set) var isModified = false {
        didSet {
            if oldValue != isModified {
                onModifiedChanged?(isModified)
                refreshTabBar()
            }
        }
    }

    /// The files open in tabs. The showing one is `document`.
    var tabs = EditorTabs()
    let tabBar = EditorTabBar()
    /// How full flash and RAM are after the last successful build.
    let memoryUsageBar = MemoryUsageBar()

    /// Called when `isModified` flips.
    var onModifiedChanged: ((Bool) -> Void)?
    /// Evaluates a C identifier hovered in the editor while debugging.
    var onHoverIdentifier: ((String) async -> String?)?
    /// Waits for the mouse to rest before asking the debugger for a value.
    var hoverTask: Task<Void, Never>?

    let textView: NSTextView
    let intelligence = EditorCodeIntelligenceState()
    private let scrollView = NSScrollView()
    private let editorStack = NSStackView()
    private(set) var ruler: LineNumberRulerView?
    private let placeholderLabel = NSTextField(labelWithString: "Select a file to edit")
    /// Shown instead of the editor while no folder is open.
    let welcomeView = WelcomeView()

    /// True while the editor itself is replacing the text, so that loading a
    /// file is not mistaken for the user editing it.
    var isLoading = false

    /// `nil` if the C grammar failed to load; the editor then shows plain text.
    private let highlighter = try? CSyntaxHighlighter()
    private var highlights = HighlightMap.empty
    private var highlightTask: Task<Void, Never>?
    /// Counts edits, so that highlights computed for older text are dropped.
    private(set) var textVersion = 0

    /// Line positions for the current text, shared with the gutter.
    private(set) var lineIndex = LineIndex("") {
        didSet {
            ruler?.lineIndex = lineIndex
            // Line starts move as the text changes; keep the messages on their lines.
            showBuildMessages()
        }
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

        editorStack.orientation = .vertical
        editorStack.spacing = 0
        editorStack.addArrangedSubview(tabBar)
        editorStack.addArrangedSubview(scrollView)
        editorStack.addArrangedSubview(diagnosticBar)
        editorStack.addArrangedSubview(memoryUsageBar)
        // A vertical stack centers what it holds; these strips span the editor.
        for strip in [tabBar, memoryUsageBar] {
            strip.widthAnchor.constraint(equalTo: editorStack.widthAnchor).isActive = true
        }

        view = makeContainer()

        configureCodeIntelligence()
        showPlaceholder(hasFolder: false)
    }

    /// Holds the editor, the "Select a file" hint, and the welcome screen,
    /// one of which shows at a time.
    private func makeContainer() -> NSView {
        let container = NSView()
        for subview in [editorStack, placeholderLabel, welcomeView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            editorStack.topAnchor.constraint(equalTo: container.topAnchor),
            editorStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            editorStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            editorStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            welcomeView.topAnchor.constraint(equalTo: container.topAnchor),
            welcomeView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            welcomeView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            welcomeView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        return container
    }

    @objc private func editorDidScroll(_ notification: Notification) {
        ruler?.needsDisplay = true
        applyVisibleHighlights()
    }

    // MARK: - Opening and saving

    /// Shows `url` in the editor, in its tab, adding one if needed. The
    /// file that was showing keeps its unsaved changes in its own tab.
    func open(_ url: URL) throws {
        let loaded = try TextDocument.load(from: url)
        loadViewIfNeeded()
        stashShowingTab()
        let restored = tabs.tab(for: url)
        let text = restored?.unsavedText ?? loaded.text

        completionPanel.dismiss()
        intelligence.completionTask?.cancel()
        intelligence.completionAnchorOffset = nil

        isLoading = true
        textView.string = text
        let length = (text as NSString).length
        textView.textStorage?.setAttributes(EditorTheme.textAttributes, range: NSRange(location: 0, length: length))
        textView.typingAttributes = EditorTheme.textAttributes
        textView.undoManager?.removeAllActions()
        textView.scrollToBeginningOfDocument(nil)
        let selection = restored?.selection ?? NSRange(location: 0, length: 0)
        if NSMaxRange(selection) <= length {
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
        } else {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        isLoading = false

        document = loaded
        tabs.select(url)
        tabs.stash(url, unsavedText: nil, selection: selection)
        isModified = restored?.isModified ?? false
        refreshTabBar()
        lineIndex = LineIndex(text)
        clearLiveDiagnostics()
        setMarkers([:])
        clearDebugMarks()
        editorStack.isHidden = false
        placeholderLabel.isHidden = true
        welcomeView.isHidden = true
        scheduleHighlighting(delay: .zero)
        intelligence.onDocumentOpened?(loaded.url, text)
    }

    /// Writes the editor's text to the file it was opened from.
    func save() throws {
        guard var current = document else { return }
        current.text = textView.string
        try current.save()
        document = current
        isModified = false
        intelligence.onDocumentSaved?(current.url, current.text)
    }

    /// Empties the editor and shows a hint in its place. Every tab closes
    /// too, unless `keepingTabs` is set because only the showing one is.
    func close(hasFolder: Bool, keepingTabs: Bool = false) {
        loadViewIfNeeded()
        if !keepingTabs {
            // Another folder, or none: the last build's sizes are not about it.
            tabs.removeAll()
            memoryUsageBar.show(nil)
        }
        let closedURL = document?.url
        completionPanel.dismiss()
        intelligence.completionTask?.cancel()
        intelligence.completionAnchorOffset = nil

        isLoading = true
        textView.string = ""
        textView.undoManager?.removeAllActions()
        isLoading = false

        document = nil
        isModified = false
        lineIndex = LineIndex("")
        clearLiveDiagnostics()
        setMarkers([:])
        clearDebugMarks()
        showPlaceholder(hasFolder: hasFolder)
        refreshTabBar()
        scheduleHighlighting(delay: .zero)
        if let closedURL {
            intelligence.onDocumentClosed?(closedURL)
        }
    }

    private func showPlaceholder(hasFolder: Bool) {
        editorStack.isHidden = true
        placeholderLabel.isHidden = !hasFolder
        welcomeView.isHidden = hasFolder
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
        clearLiveDiagnostics()
        isModified = true
        // Wait for a short pause in typing before parsing again.
        scheduleHighlighting(delay: .milliseconds(40))
        if let url = document?.url {
            intelligence.onDocumentChanged?(url, textView.string)
        }
        handleTypingCompletionTrigger()
    }

    // MARK: - Build messages

    /// The lines currently flagged in the gutter, combining the last build and live diagnostics.
    var markers: [Int: Diagnostic.Severity] {
        var combined = intelligence.buildMarkers
        for diagnostic in intelligence.liveDiagnostics {
            let severity = diagnostic.diagnosticSeverity
            guard severity != .note else { continue }
            let line = diagnostic.range.start.line + 1
            if combined[line] != .error {
                combined[line] = severity
            }
        }
        return combined
    }

    /// Flags lines in the gutter with the errors and warnings from a build.
    func setMarkers(_ markers: [Int: Diagnostic.Severity]) {
        intelligence.buildMarkers = markers
        if markers.isEmpty {
            setBuildMessages([:])
        }
        refreshRulerMarkers()
    }

    func refreshRulerMarkers() {
        ruler?.lineMarkers = markers
    }

    /// Moves the cursor to a line and column (both 1-based, as the compiler
    /// reports them) and scrolls it into view.
    func goTo(line: Int, column: Int?, unit: ColumnUnit = .utf16) {
        var column = column ?? 1
        if unit == .utf8, let range = lineIndex.range(ofLine: line) {
            let lineText = (textView.string as NSString).substring(with: range)
            column = Self.utf16Column(fromUTF8Column: column, in: lineText)
        }
        guard let offset = lineIndex.offset(line: line, column: column) else { return }
        let range = NSRange(location: min(offset, lineIndex.length), length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }
}

// MARK: - Syntax highlighting

extension EditorViewController {
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
