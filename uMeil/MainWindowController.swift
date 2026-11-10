import AppKit

/// The main IDE window. For now it only shows a placeholder; the editor,
/// file navigator, and debugger views arrive in later milestones.
final class MainWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.setFrameAutosaveName("MainWindow")
        window.center()
        window.contentView = Self.makePlaceholderView()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, not from a nib")
    }

    private static func makePlaceholderView() -> NSView {
        let label = NSTextField(labelWithString: "\(AppInfo.name) for the Tiva \(AppInfo.targetChip)")
        label.font = .preferredFont(forTextStyle: .title2)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
}
