import AppKit

/// The `Command` panel: logs debugger, OpenOCD, build, and flash output, and
/// lets the user enter text commands for GDB.
final class CommandViewController: NSViewController {
    /// The most text the command console keeps by default. Older lines are dropped first.
    static let maximumLength = 500_000

    let textView = NSTextView()
    let commandField = NSTextField()
    /// Shown over the log until the first line of output arrives.
    let emptyState = EmptyStateView()

    /// Maximum retained console log length in UTF-16 code units.
    var maxLength = CommandViewController.maximumLength

    /// Called when the user submits a command in the bottom text field.
    var onSendCommand: ((String) -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Command"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CommandViewController is created in code, not from a nib")
    }

    override func loadView() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = EditorTheme.font
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let prompt = NSTextField(labelWithString: "(gdb)")
        prompt.font = EditorTheme.font
        prompt.textColor = .secondaryLabelColor

        commandField.placeholderString = "Enter GDB command…"
        commandField.font = EditorTheme.font
        commandField.target = self
        commandField.action = #selector(submitCommand(_:))

        let inputBar = NSStackView(views: [prompt, commandField])
        inputBar.orientation = .horizontal
        inputBar.spacing = 6
        inputBar.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let container = PanelLayout.view(bar: inputBar, content: scrollView, barAt: .bottom)
        emptyState.show(
            symbol: "ladybug",
            title: "No debug session",
            detail: "Start a debug session (⌃F5) to see GDB and OpenOCD output here."
        )
        emptyState.pin(over: scrollView, in: container)
        view = container
        updateEmptyState()
    }

    /// The hint shows only while the log is empty.
    private func updateEmptyState() {
        emptyState.isHidden = !textView.string.isEmpty
    }

    private static var outputAttributes: [NSAttributedString.Key: Any] {
        [
            .font: EditorTheme.font,
            .foregroundColor: NSColor.labelColor
        ]
    }

    /// Appends `text` to the console log, trims the oldest lines or characters
    /// past `maxLength`, and scrolls to the bottom.
    func appendOutput(_ text: String) {
        loadViewIfNeeded()
        guard !text.isEmpty, let storage = textView.textStorage else { return }
        let attributed = NSAttributedString(string: text, attributes: Self.outputAttributes)
        storage.beginEditing()
        storage.append(attributed)
        let excess = storage.length - maxLength
        if excess > 0 {
            let cutLength: Int
            if excess >= storage.length {
                cutLength = storage.length
            } else {
                let raw = storage.string as NSString
                let lineEnd = NSMaxRange(raw.lineRange(for: NSRange(location: excess - 1, length: 0)))
                if lineEnd < storage.length {
                    cutLength = lineEnd
                } else {
                    let sequence = raw.rangeOfComposedCharacterSequence(at: excess)
                    cutLength = sequence.location == excess ? excess : NSMaxRange(sequence)
                }
            }
            storage.deleteCharacters(in: NSRange(location: 0, length: cutLength))
        }
        storage.endEditing()
        updateEmptyState()
        textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    func clear() {
        loadViewIfNeeded()
        textView.string = ""
        updateEmptyState()
    }

    @objc func submitCommand(_ sender: Any? = nil) {
        loadViewIfNeeded()
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        commandField.stringValue = ""
        appendOutput("(gdb) \(command)\n")
        onSendCommand?(command)
    }
}
