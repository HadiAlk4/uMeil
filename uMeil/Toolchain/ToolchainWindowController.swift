import AppKit

/// A separate window for the toolchain status table.
final class ToolchainWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Toolchain Status"
        window.contentViewController = ToolchainStatusViewController()
        window.contentMinSize = NSSize(width: 520, height: 180)
        window.setContentSize(NSSize(width: 860, height: 260))
        window.setFrameAutosaveName("ToolchainWindow")
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolchainWindowController is created in code, not from a nib")
    }
}
