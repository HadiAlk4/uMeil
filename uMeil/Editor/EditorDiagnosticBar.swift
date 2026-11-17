import AppKit

/// Compact strip at the bottom of the editor showing the live diagnostic on
/// the current cursor line (or the first diagnostic in the file). Hidden when clean.
final class EditorDiagnosticBar: NSView {
    var onClick: ((LSPDiagnostic) -> Void)?

    private var currentDiagnostic: LSPDiagnostic?
    private let iconView = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
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

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [iconView, messageLabel, NSView(), countLabel])
        stack.orientation = .horizontal
        stack.spacing = 6
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
        addGestureRecognizer(click)
    }

    func update(diagnostics: [LSPDiagnostic], cursorLineZeroBased: Int) {
        let actionable = diagnostics.filter { $0.diagnosticSeverity != .note }
        guard !actionable.isEmpty else {
            currentDiagnostic = nil
            isHidden = true
            return
        }

        let onLine = actionable
            .filter { $0.range.start.line <= cursorLineZeroBased && cursorLineZeroBased <= $0.range.end.line }
            .min { ($0.severity ?? .error) < ($1.severity ?? .error) }
        let selected = onLine ?? actionable.min { ($0.severity ?? .error) < ($1.severity ?? .error) }!
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
        isHidden = false
    }

    @objc private func barClicked(_ sender: Any?) {
        if let currentDiagnostic {
            onClick?(currentDiagnostic)
        }
    }

    private static func summaryText(errors: Int, warnings: Int) -> String {
        var parts: [String] = []
        if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
        return parts.joined(separator: ", ")
    }
}
