import AppKit

/// The main IDE window. For now it shows the toolchain status; the editor,
/// file navigator, and debugger views arrive in later milestones.
final class MainWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppInfo.name) for the Tiva \(AppInfo.targetChip)"
        window.contentViewController = ToolchainStatusViewController()
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.setContentSize(NSSize(width: 960, height: 640))
        window.setFrameAutosaveName("MainWindow")
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is created in code, not from a nib")
    }
}
