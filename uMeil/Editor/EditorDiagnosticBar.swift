import AppKit

/// Compact strip at the bottom of the editor showing the live diagnostic on
/// the current cursor line (or the first diagnostic in the file). Hidden when clean.
final class EditorDiagnosticBar: NSView, NSGestureRecognizerDelegate {
    var onClick: ((LSPDiagnostic) -> Void)?
    var onQuickFix: ((LSPCodeAction) -> Void)?

    private(set) var currentDiagnostic: LSPDiagnostic?
    private(set) var currentQuickFix: LSPCodeAction?
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    let fixButton = NSButton(title: "Fix", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorDiagnosticBar is created in code, not from a nib")
    }

    private func setupViews() {
        wantsLayer = true
        isHidden = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureFixButton()

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, messageLabel, NSView(), fixButton, countLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(barClicked(_:)))
        click.delegate = self
        addGestureRecognizer(click)
    }

    private func configureFixButton() {
        fixButton.bezelStyle = .accessoryBarAction
        fixButton.controlSize = .small
        fixButton.font = .systemFont(ofSize: 11, weight: .semibold)
        fixButton.contentTintColor = .controlAccentColor
        fixButton.image = NSImage(
            systemSymbolName: "wrench.and.screwdriver.fill",
            accessibilityDescription: "Quick Fix"
        )?.withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold))
        fixButton.imagePosition = .imageLeading
        fixButton.setContentHuggingPriority(.required, for: .horizontal)
        fixButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        fixButton.target = self
        fixButton.action = #selector(fixClicked(_:))
        fixButton.isHidden = true
    }

    /// Picks the diagnostic shown in the bar for `cursorLineZeroBased`, or `nil` when clean.
    static func selectedDiagnostic(from diagnostics: [LSPDiagnostic], cursorLineZeroBased: Int) -> LSPDiagnostic? {
        let actionable = diagnostics.filter { $0.diagnosticSeverity != .note }
        guard !actionable.isEmpty else { return nil }
        let onLine = actionable
            .filter { $0.range.start.line <= cursorLineZeroBased && cursorLineZeroBased <= $0.range.end.line }
            .min { ($0.severity ?? .error) < ($1.severity ?? .error) }
        return onLine ?? actionable.min { ($0.severity ?? .error) < ($1.severity ?? .error) }
    }

    func update(diagnostics: [LSPDiagnostic], cursorLineZeroBased: Int, quickFix: LSPCodeAction? = nil) {
        let actionable = diagnostics.filter { $0.diagnosticSeverity != .note }
        guard let selected = Self.selectedDiagnostic(from: actionable, cursorLineZeroBased: cursorLineZeroBased) else {
            currentDiagnostic = nil
            updateQuickFix(nil)
            isHidden = true
            return
        }
        currentDiagnostic = selected

        let severity = selected.diagnosticSeverity
        let symbolName = severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: severity.rawValue)
        iconView.contentTintColor = IssuesViewController.color(for: severity)

        let line = selected.range.start.line + 1
        messageLabel.stringValue = "Line \(line): \(selected.message)"
        toolTip = selected.message

        let errors = actionable.filter { $0.diagnosticSeverity == .error }.count
        let warnings = actionable.filter { $0.diagnosticSeverity == .warning }.count
        countLabel.stringValue = Self.summaryText(errors: errors, warnings: warnings)
        updateQuickFix(quickFix)
        isHidden = false
    }

    func updateQuickFix(_ action: LSPCodeAction?) {
        currentQuickFix = action
        guard let action else {
            fixButton.isHidden = true
            fixButton.toolTip = nil
            fixButton.setAccessibilityLabel(nil)
            return
        }
        let tip = DiagnosticQuickFix.tooltip(for: action)
        fixButton.title = DiagnosticQuickFix.buttonTitle(for: action)
        fixButton.toolTip = tip
        fixButton.setAccessibilityLabel(tip)
        fixButton.isHidden = false
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard !fixButton.isHidden else { return true }
        let pointInButton = fixButton.convert(event.locationInWindow, from: nil)
        return !fixButton.bounds.contains(pointInButton)
    }

    @objc private func barClicked(_ sender: NSClickGestureRecognizer) {
        if !fixButton.isHidden, fixButton.bounds.contains(sender.location(in: fixButton)) {
            return
        }
        if let currentDiagnostic {
            onClick?(currentDiagnostic)
        }
    }

    @objc private func fixClicked(_ sender: Any?) {
        if let currentQuickFix {
            onQuickFix?(currentQuickFix)
        }
    }

    private static func summaryText(errors: Int, warnings: Int) -> String {
        var parts: [String] = []
        if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        return parts.joined(separator: ", ")
    }
}
