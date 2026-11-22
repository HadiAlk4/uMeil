import AppKit

/// A small floating, non-activating box of text beside the code: the
/// parameter hint above a call being typed, or the details of a hovered name.
@MainActor
final class CodeInfoPanel {
    enum Placement {
        /// Above the line, so it never covers the completion list below it.
        case above
        /// Below the hovered word, like a tooltip.
        case below
    }

    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private static let maxWidth: CGFloat = 620
    private static let padding = NSSize(width: 9, height: 6)

    var isVisible: Bool { panel.isVisible }
    /// The text showing, for tests and to skip redundant updates.
    private(set) var text: NSAttributedString?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = true
        panel.ignoresMouseEvents = true

        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = Self.maxWidth - 2 * Self.padding.width

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.padding.height),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Self.padding.height),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.padding.width),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Self.padding.width)
        ])
        panel.contentView = background
    }

    /// Shows `text` next to `screenRect` (in screen coordinates).
    func show(_ text: NSAttributedString, near screenRect: NSRect, placement: Placement, parentWindow: NSWindow?) {
        self.text = text
        label.attributedStringValue = text
        let fitting = label.sizeThatFits(NSSize(width: label.preferredMaxLayoutWidth, height: .greatestFiniteMagnitude))
        let size = NSSize(
            width: min(ceil(fitting.width) + 2 * Self.padding.width + 2, Self.maxWidth),
            height: ceil(fitting.height) + 2 * Self.padding.height
        )
        let visible = parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = max(min(screenRect.minX, visible.maxX - size.width - 8), visible.minX + 8)
        let aboveY = screenRect.maxY + 2
        let belowY = screenRect.minY - size.height - 2
        var originY = placement == .above ? aboveY : belowY
        if originY + size.height > visible.maxY - 4 { originY = belowY }
        if originY < visible.minY + 4 { originY = aboveY }
        panel.setFrame(NSRect(origin: NSPoint(x: originX, y: originY), size: size), display: true)
        if let parentWindow, panel.parent !== parentWindow {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func dismiss() {
        text = nil
        guard panel.isVisible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}
