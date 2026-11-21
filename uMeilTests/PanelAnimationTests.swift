import AppKit
import Testing
@testable import uMeil

@MainActor
struct PanelAnimationTests {
    @Test func doesNotAnimateAWindowThatIsNotOnScreen() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)

        #expect(!PanelAnimation.shouldAnimate(in: window))
        #expect(!PanelAnimation.shouldAnimate(in: nil))
    }

    @Test func offScreenPanesChangeAtOnceAndThenCallBack() {
        let item = NSSplitViewItem(viewController: NSViewController())
        item.canCollapse = true
        var calledBack = false

        PanelAnimation.setCollapsed(true, [item], in: nil) { calledBack = true }

        #expect(item.isCollapsed)
        #expect(calledBack)
    }

    @Test func aPaneAlreadyThereStillCallsBack() {
        let item = NSSplitViewItem(viewController: NSViewController())
        var calledBack = false

        PanelAnimation.setCollapsed(false, [item], in: nil) { calledBack = true }

        #expect(!item.isCollapsed)
        #expect(calledBack)
    }
}
