import AppKit

/// The `Command` panel: logs debugger, OpenOCD, build, and flash output, and
/// lets the user enter text commands for GDB.
final class CommandViewController: NSViewController {
    /// The most text the command console keeps. Older lines are dropped first.
    static let maximumLength = 500_000

    let textView = NSTextView()
    let commandField = NSTextField()

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

        view = PanelLayout.view(bar: inputBar, content: scrollView, barAt: .bottom)
    }

    /// Appends `text` to the console log and scrolls to the bottom.
    func appendOutput(_ text: String) {
        loadViewIfNeeded()
        guard !text.isEmpty else { return }
        if let storage = textView.textStorage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: EditorTheme.font,
                .foregroundColor: NSColor.labelColor
            ]
            storage.append(NSAttributedString(string: text, attributes: attributes))

            let excess = storage.length - Self.maximumLength
            if excess > 0 {
                let line = (storage.string as NSString).lineRange(for: NSRange(location: excess - 1, length: 0))
                let end = NSMaxRange(line)
                storage.deleteCharacters(in: NSRange(location: 0, length: end < storage.length ? end : excess))
            }
            textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        } else {
            let end = NSRange(location: (textView.string as NSString).length, length: 0)
            textView.replaceCharacters(in: end, with: text)
            textView.font = EditorTheme.font
            textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        }
    }

    func clear() {
        loadViewIfNeeded()
        textView.string = ""
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
