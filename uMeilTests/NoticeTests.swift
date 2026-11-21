import AppKit
import Testing
@testable import uMeil

@MainActor
struct NoticeTests {
    private func build(succeeded: Bool, warnings: Int = 0) -> BuildResult {
        BuildResult(
            succeeded: succeeded,
            diagnostics: (0..<warnings).map { _ in Diagnostic(severity: .warning, message: "w") }
                + [Diagnostic(severity: .note, message: "n")],
            compiledSources: [],
            didLink: true,
            log: ""
        )
    }

    @Test func saysWhenABuildWorked() {
        #expect(NoticeText.build(build(succeeded: true))?.text == "Build Succeeded")
        #expect(NoticeText.build(build(succeeded: true, warnings: 1))?.text == "Build Succeeded with 1 warning")
        #expect(NoticeText.build(build(succeeded: true, warnings: 3))?.text == "Build Succeeded with 3 warnings")
        #expect(NoticeText.build(build(succeeded: true, warnings: 3))?.tint == .systemYellow)
        #expect(NoticeText.build(build(succeeded: false)) == nil)
    }

    @Test func saysWhenAFlashWorked() {
        #expect(NoticeText.flash(FlashResult(failure: nil, log: ""))?.text == "Flashed to Board")
        #expect(NoticeText.flash(FlashResult(failure: .stopped, log: "")) == nil)
    }

    @Test func showsOverTheEditorAndThenGoesAway() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let notice = NoticeView()
        notice.install(in: host)

        notice.show(.init(text: "Flashed to Board"))
        #expect(notice.isShowing)
        #expect(notice.label.stringValue == "Flashed to Board")
        #expect(host.subviews.last === notice)

        notice.hide()
        #expect(!notice.isShowing)
    }

    @Test func theWindowShowsANoticeOverTheEditor() {
        let controller = MainWindowController(boardMonitor: FakeBoardMonitor())

        controller.showNotice(.init(text: "Build Succeeded"))

        #expect(controller.notice.superview === controller.editor.view)
        #expect(controller.notice.isShowing)
        controller.showNotice(nil)
        #expect(controller.notice.label.stringValue == "Build Succeeded")
    }
}
