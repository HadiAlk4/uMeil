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
        ruler?.lineIndex = LineIndex(loaded.text)
        scrollView.isHidden = false
        placeholder.isHidden = true
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
        ruler?.lineIndex = LineIndex("")
        showPlaceholder(hasFolder: hasFolder)
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
        ruler?.lineIndex = LineIndex(textView.string)
        isModified = true
    }
}
