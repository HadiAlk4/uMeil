import AppKit

/// A separate window for the serial monitor.
final class SerialMonitorWindowController: NSWindowController {
    let monitor: SerialMonitorViewController

    init(monitor: SerialMonitorViewController = SerialMonitorViewController()) {
        self.monitor = monitor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Serial Monitor"
        window.contentViewController = monitor
        window.contentMinSize = NSSize(width: 520, height: 220)
        window.setContentSize(NSSize(width: 720, height: 420))
        window.setFrameAutosaveName("SerialMonitorWindow")
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SerialMonitorWindowController is created in code, not from a nib")
    }
}
