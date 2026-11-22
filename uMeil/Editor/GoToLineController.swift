import AppKit

/// Edit > Go to Line… (⌘L): a compact floating input card that jumps the
/// editor to a line number or `line:column`.
@MainActor
final class GoToLineController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// A parsed, clamped jump destination (both 1-based).
    struct Target: Equatable, Sendable {
        let line: Int
        let column: Int?
    }

    /// Called when the user submits a valid line or `line:column`.
    var onJump: ((Target) -> Void)?
    /// Called when the panel closes without jumping, so focus can return to the editor.
    var onClose: (() -> Void)?

    let panel: NSPanel
    let inputField = NSTextField()
    let hintLabel = NSTextField(labelWithString: "")

    private(set) var maxLine = 1
    private var isClosing = false

    override init() {
        let floatingPanel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 78),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel = floatingPanel
        super.init()

        floatingPanel.onCancel = { [weak self] in self?.close() }
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = makeContent()
    }

    private func makeContent() -> NSView {
        let icon = NSImage(systemSymbolName: "number", accessibilityDescription: "Go to Line")
        let iconView = NSImageView(image: icon ?? NSImage())
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.font = .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
        inputField.textColor = .labelColor
        inputField.usesSingleLineMode = true
        inputField.cell?.isScrollable = true
        inputField.cell?.wraps = false
        inputField.placeholderString = "Go to line (1–1)"
        inputField.delegate = self
        inputField.setAccessibilityLabel("Go to Line")

        let inputRow = NSStackView(views: [iconView, inputField])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active

        for subview in [inputRow, separator, hintLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            inputRow.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            inputRow.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            inputRow.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            separator.topAnchor.constraint(equalTo: inputRow.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hintLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 7),
            hintLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            hintLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            hintLabel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -9)
        ])
        updateHint()
        return background
    }

    // MARK: - Showing and closing

    /// Shows the panel centered near the top of `window` for a document with `lineCount` lines.
    func show(lineCount: Int, over window: NSWindow?) {
        maxLine = max(lineCount, 1)
        inputField.stringValue = ""
        inputField.placeholderString = "Go to line (1–\(maxLine))"
        updateHint()
        panel.appearance = window?.appearance

        if let frame = window?.frame {
            let size = panel.frame.size
            let originX = frame.midX - size.width / 2
            let originY = max(frame.minY + 20, frame.maxY - size.height - 90)
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(inputField)
    }

    /// Closes the panel. When `restoreFocus` is true and the panel was visible, notifies `onClose`.
    func close(restoreFocus: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if restoreFocus, wasVisible {
            onClose?()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close(restoreFocus: true)
    }

    // MARK: - Input handling

    func controlTextDidChange(_ obj: Notification) {
        updateHint()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    /// Parses the current input, closing and calling `onJump` if valid.
    @objc func submit() {
        guard let target = Self.parse(inputField.stringValue, maxLine: maxLine) else {
            showInvalidFeedback()
            return
        }
        close(restoreFocus: false)
        onJump?(target)
    }

    private func updateHint() {
        let raw = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hintLabel.textColor = .secondaryLabelColor
        guard !raw.isEmpty else {
            hintLabel.stringValue = "Enter a line or line:column (e.g. 42 or 42:10)"
            return
        }
        if let target = Self.parse(raw, maxLine: maxLine) {
            if let column = target.column {
                hintLabel.stringValue = "Jump to line \(target.line), column \(column)"
            } else {
                hintLabel.stringValue = "Jump to line \(target.line)"
            }
        } else {
            hintLabel.stringValue = "Enter a line number, such as 42 or 42:10"
        }
    }

    private func showInvalidFeedback() {
        hintLabel.textColor = .systemRed
        hintLabel.stringValue = "Enter a line number (1–\(maxLine)), such as 42 or 42:10"
        NSSound.beep()
    }

    // MARK: - Parsing

    /// Parses user input such as `"42"`, `"42:10"`, `":42"`, or `"line 42"`.
    /// Clamps line numbers into `1...max(maxLine, 1)` and columns to `>= 1`.
    /// Returns `nil` for empty or non-numeric input.
    nonisolated static func parse(_ input: String, maxLine: Int) -> Target? {
        guard let normalized = stripPrefix(from: input) else { return nil }
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }

        guard let rawLine = parseInteger(parts[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let line = min(max(rawLine, 1), max(maxLine, 1))
        if parts.count == 1 {
            return Target(line: line, column: nil)
        }
        guard let rawColumn = parseInteger(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return Target(line: line, column: max(rawColumn, 1))
    }

    private nonisolated static func stripPrefix(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.lowercased().hasPrefix("line") {
            let remainder = text.dropFirst(4)
            guard let first = remainder.first, first.isWhitespace || first == ":" else {
                return nil
            }
            text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix(":") {
                text = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if text.hasPrefix(":") {
            text = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private nonisolated static func parseInteger(_ token: String) -> Int? {
        guard !token.isEmpty else { return nil }
        var digits = Substring(token)
        var isNegative = false
        if digits.first == "-" {
            isNegative = true
            digits = digits.dropFirst()
        } else if digits.first == "+" {
            digits = digits.dropFirst()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        if let value = Int(token) {
            return value
        }
        return isNegative ? .min : .max
    }
}

private final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
