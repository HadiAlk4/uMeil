import AppKit
import Testing
@testable import uMeil

/// Makes the screenshot on the website: Blinky stopped on the LaunchPad,
/// with the debug panels and the `Peripherals` panel showing GPIO port N.
///
/// Only runs when asked for, with a board plugged in:
///
///     TEST_RUNNER_UMEIL_HIL=1 TEST_RUNNER_UMEIL_SCREENSHOT=$PWD/site/screenshot.png \
///         xcodebuild test -project uMeil.xcodeproj -scheme uMeil \
///         -destination 'platform=macOS,arch=arm64' \
///         -only-testing:uMeilTests/WebsiteScreenshotTests
@MainActor
@Suite(.serialized)
struct WebsiteScreenshotTests {
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    nonisolated private static let output = environment["UMEIL_SCREENSHOT"].map { URL(filePath: $0) }
    nonisolated private static let isEnabled = output != nil && environment["UMEIL_HIL"] == "1"

    /// Waits up to `seconds` for `condition`, which can take a while on a board.
    private func wait(_ what: String, seconds: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            guard Date.now < deadline else {
                Issue.record("Timed out waiting until \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(3)))
    func screenshotOfADebugSessionOnTheBoard() async throws {
        let output = try #require(Self.output)
        UserDefaults.standard.removeObject(forKey: PeripheralsViewController.selectionKey)
        let folder = try TemporaryFolder()
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let monitor = FakeBoardMonitor()
        let controller = MainWindowController(defaults: defaults, boardMonitor: monitor)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: .aqua)
        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        controller.showWindow(nil)
        monitor.setConnected(true)
        try controller.createProject(named: "Blinky", in: folder.url)

        controller.editor.onClickGutterLine?(28)
        try await wait("the breakpoint is set") { controller.editor.breakpointLines == [28] }
        #expect(await controller.startDebugging())
        try await wait("the program stops at main") { controller.debugger.isStopped }
        controller.debugContinue(nil)
        try await wait("the program reaches line 28") { controller.editor.executionLine == 28 }

        let panels = controller.debugPanels
        panels.auxiliaryTabs.selectedTabViewItemIndex = 2
        try await wait("the panels fill in") {
            !panels.registers.nodes.isEmpty && !panels.disassembly.rows.isEmpty
                && panels.peripherals.readings["DIR"] != nil
        }
        // Show port N's DIR register opened up into its pins.
        let outline = panels.peripherals.outlineView
        if let direction = panels.peripherals.nodes.first(where: { $0.name == "DIR" }) {
            outline.expandItem(direction)
        }
        // An off-screen render draws the navigator's selection as a black bar.
        controller.navigator.outlineView.deselectAll(nil)
        try await Task.sleep(for: .milliseconds(500))
        window.displayIfNeeded()

        // The frame view holds the title bar and toolbar as well as the content.
        let frameView = try #require(window.contentView?.superview)
        let image = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: output)

        await controller.debugger.stop()
        try await wait("the session is over") { !controller.debugger.isActive }
        window.close()
    }
}
