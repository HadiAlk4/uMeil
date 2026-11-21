import AppKit
import QuartzCore

/// Slides split view panes in and out instead of snapping them.
@MainActor
enum PanelAnimation {
    static let duration: TimeInterval = 0.22

    /// Whether panel changes in `window` should animate: only while it is on
    /// screen, and not when the user asked macOS to reduce motion.
    static func shouldAnimate(in window: NSWindow?) -> Bool {
        window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Collapses or expands `item`, animated when `shouldAnimate(in:)` says
    /// so. `completion` runs once the pane has its new size.
    static func setCollapsed(
        _ collapsed: Bool,
        _ items: [NSSplitViewItem],
        in window: NSWindow?,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let changing = items.filter { $0.isCollapsed != collapsed }
        guard !changing.isEmpty, shouldAnimate(in: window) else {
            changing.forEach { $0.isCollapsed = collapsed }
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            changing.forEach { $0.animator().isCollapsed = collapsed }
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }
}
