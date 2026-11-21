import AppKit

/// A short message, such as "Flashed to board", that floats over the editor
/// for a moment and fades away, so a finished build or flash is noticed
/// without checking the Issues panel.
final class NoticeView: NSVisualEffectView {
    /// What a notice says.
    struct Message: Equatable {
        var text: String
        var symbol = "checkmark.circle.fill"
        var tint: NSColor = .systemGreen
    }

    /// How long a notice stays before it fades.
    static let displayDuration: TimeInterval = 2
    static let fadeDuration: TimeInterval = 0.25

    let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.masksToBounds = true
        alphaValue = 0
        isHidden = true
        setAccessibilityRole(.staticText)

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 13, bottom: 7, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NoticeView is created in code, not from a nib")
    }

    /// Places the notice near the top of `host`, centered, above everything else.
    func install(in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: host.centerXAnchor),
            topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
            widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -40)
        ])
    }

    /// Shows `message`, replacing any notice already showing, and hides it
    /// again after `displayDuration`.
    func show(_ message: Message) {
        label.stringValue = message.text
        icon.image = NSImage(systemSymbolName: message.symbol, accessibilityDescription: nil)
        icon.contentTintColor = message.tint
        setAccessibilityLabel(message.text)
        superview?.addSubview(self, positioned: .above, relativeTo: nil)
        isHidden = false

        if PanelAnimation.shouldAnimate(in: window) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: message.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.displayDuration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard PanelAnimation.shouldAnimate(in: window) else {
            alphaValue = 0
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A newer notice may have started showing meanwhile.
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        }
    }

    var isShowing: Bool { !isHidden && alphaValue > 0 }
}

/// The words of the notices shown when work finishes.
enum NoticeText {
    /// After an explicit Build. `nil` when the build failed: the Issues
    /// panel already opens to show why.
    static func build(_ result: BuildResult) -> NoticeView.Message? {
        guard result.succeeded else { return nil }
        let warnings = result.diagnostics.count { $0.severity == .warning }
        guard warnings > 0 else { return .init(text: "Build Succeeded") }
        let noun = warnings == 1 ? "warning" : "warnings"
        return .init(
            text: "Build Succeeded with \(warnings) \(noun)",
            symbol: "exclamationmark.triangle.fill",
            tint: .systemYellow
        )
    }

    /// After a flash. `nil` when it failed or was stopped.
    static func flash(_ result: FlashResult) -> NoticeView.Message? {
        result.succeeded ? .init(text: "Flashed to Board") : nil
    }
}
