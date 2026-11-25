import AppKit
import Testing
@testable import uMeil

@MainActor
struct StatusBarTests {
    // MARK: - In the window

    private func makeWindow(in folder: TemporaryFolder) throws -> (MainWindowController, FakeBoardMonitor) {
        let defaults = TestDefaults()
        let board = FakeBoardMonitor()
        let controller = MainWindowController(defaults: defaults, boardMonitor: board)
        try controller.createProject(named: "Blinky", in: folder.url)
        return (controller, board)
    }

    @Test func theStatusLineShowsTheCursorChipAndBoard() throws {
        let folder = try TemporaryFolder()
        let (controller, board) = try makeWindow(in: folder)
        let bar = controller.editor.statusBar

        #expect(!bar.isHidden)
        #expect(bar.chipLabel.stringValue == "TM4C1294NCPDT")
        #expect(bar.boardLabel.stringValue == "No board")
        board.setConnected(true)
        #expect(bar.boardLabel.stringValue == "Board connected")

        let textView = controller.editor.textView
        textView.string = "int a;\n\tint b;\n"
        controller.editor.textDidChange(Notification(name: NSText.didChangeNotification))
        textView.setSelectedRange(NSRange(location: 12, length: 0))
        #expect(bar.positionLabel.stringValue == "Ln 2, Col 6")
    }

    @Test func theFlashAndRAMMetersSitInTheStatusLine() throws {
        let folder = try TemporaryFolder()
        let (controller, _) = try makeWindow(in: folder)
        let meters = controller.editor.memoryUsageBar

        #expect(meters.isDescendant(of: controller.editor.statusBar))
        #expect(meters.isHidden)
        meters.show(MemoryUsage(size: ProgramSize(text: 1396, data: 8, bss: 16), chip: .tm4c1294ncpdt))
        #expect(!meters.isHidden)
        #expect(!controller.editor.statusBar.isHidden)
    }

    @Test func theStatusLineHidesOnTheWelcomeScreen() throws {
        let folder = try TemporaryFolder()
        let (controller, _) = try makeWindow(in: folder)

        controller.closeFolder(nil)

        #expect(controller.editor.statusBar.isHidden)
    }

    @Test func theBoardNoLongerCrowdsTheToolbar() {
        let toolbar = MainToolbar()
        #expect(!toolbar.toolbarDefaultItemIdentifiers(toolbar.toolbar).contains(.init("Board")))
    }
}
