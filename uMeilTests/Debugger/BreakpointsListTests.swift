import AppKit
import Testing
@testable import uMeil

@MainActor
struct BreakpointsListTests {
    private let main = URL(filePath: "/tmp/project/main.c")
    private let uart = URL(filePath: "/tmp/project/uart.c")

    // MARK: - The list

    @Test func entriesAreSortedByFileThenLineWithOffOnesAmongThem() {
        var list = BreakpointList()
        list.markDisabled(SourceLine(file: main, line: 20))
        let enabled: Set = [SourceLine(file: uart, line: 3), SourceLine(file: main, line: 7)]

        let entries = list.entries(enabled: enabled)

        #expect(entries.map(\.title) == ["main.c:7", "main.c:20", "uart.c:3"])
        #expect(entries.map(\.isEnabled) == [true, false, true])
        #expect(list.disabledLines(in: main) == [20])
        #expect(list.disabledLines(in: uart).isEmpty)
    }

    @Test func aBreakpointTurnedBackOnIsNoLongerOff() {
        var list = BreakpointList()
        let location = SourceLine(file: main, line: 20)
        list.markDisabled(location)

        list.forget([location])

        #expect(list.entries(enabled: [location]).map(\.isEnabled) == [true])
        #expect(list.disabled.isEmpty)
    }

    // MARK: - The panel

    private func loadedPanel() -> BreakpointsViewController {
        let panel = BreakpointsViewController()
        panel.loadViewIfNeeded()
        panel.view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        return panel
    }

    @Test func anEmptyListSaysHowToAddOne() {
        let panel = loadedPanel()
        #expect(!panel.emptyState.isHidden)
        #expect(panel.emptyState.titleLabel.stringValue == "No breakpoints")
        #expect(!panel.removeAllButton.isEnabled)

        panel.show(enabled: [SourceLine(file: main, line: 7)])

        #expect(panel.emptyState.isHidden)
        #expect(panel.removeAllButton.isEnabled)
    }

    @Test func deleteRemovesTheSelectionAndRemoveAllRemovesEverything() throws {
        let panel = loadedPanel()
        panel.show(enabled: [SourceLine(file: main, line: 7), SourceLine(file: main, line: 9)])
        var removed: [[String]] = []
        panel.onRemove = { removed.append($0.map(\.title)) }

        panel.tableView.selectRowIndexes([1], byExtendingSelection: false)
        let delete = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51
        ))
        panel.tableView.keyDown(with: delete)
        panel.removeAll(nil)

        #expect(removed == [["main.c:9"], ["main.c:7", "main.c:9"]])
    }

    @Test func theCheckboxAsksToTurnTheBreakpointOff() throws {
        let panel = loadedPanel()
        let location = SourceLine(file: main, line: 7)
        panel.show(enabled: [location])
        var requests: [(SourceLine, Bool)] = []
        panel.onSetEnabled = { requests.append(($0, $1)) }

        let column = panel.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("enabled"))
        let checkbox = try #require(panel.tableView.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSButton)
        #expect(checkbox.state == .on)
        checkbox.state = .off
        panel.toggleClicked(checkbox)

        #expect(requests.map(\.0) == [location])
        #expect(requests.map(\.1) == [false])
    }

    // MARK: - In the window

    private func makeWindow(in folder: TemporaryFolder) throws -> MainWindowController {
        let defaults = TestDefaults()
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        try controller.createProject(named: "Blinky", in: folder.url)
        return controller
    }

    @Test func turningABreakpointOffKeepsItListedAndHollowInTheGutter() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeWindow(in: folder)
        let file = try #require(controller.editor.document?.url)
        let location = SourceLine(file: file, line: 3)
        await controller.debugger.toggleBreakpoint(at: location)

        let panel = controller.breakpointsPanel
        #expect(panel.entries.map(\.isEnabled) == [true])
        #expect(controller.bottomPanel.title(for: .breakpoints) == "Breakpoints 1")
        #expect(panel.lineText?(location)?.isEmpty == false)

        await controller.setBreakpoint(location, enabled: false)
        #expect(!controller.debugger.breakpoints.contains(location))
        #expect(panel.entries.map(\.isEnabled) == [false])
        #expect(controller.editor.disabledBreakpointLines == [3])
        #expect(controller.editor.breakpointLines.isEmpty)

        await controller.setBreakpoint(location, enabled: true)
        #expect(controller.debugger.breakpoints.contains(location))
        #expect(panel.entries.map(\.isEnabled) == [true])
        #expect(controller.editor.disabledBreakpointLines.isEmpty)
    }

    @Test func removingDeletesOnAndOffBreakpoints() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeWindow(in: folder)
        let file = try #require(controller.editor.document?.url)
        let turnedOn = SourceLine(file: file, line: 3)
        let off = SourceLine(file: file, line: 5)
        await controller.debugger.toggleBreakpoint(at: turnedOn)
        await controller.debugger.toggleBreakpoint(at: off)
        await controller.setBreakpoint(off, enabled: false)

        await controller.removeBreakpoints(controller.breakpointsPanel.entries)

        #expect(controller.debugger.breakpoints.isEmpty)
        #expect(controller.breakpointsPanel.entries.isEmpty)
        #expect(controller.bottomPanel.title(for: .breakpoints) == "Breakpoints")
    }

    @Test func breakpointsThatAreOffBelongToTheFolder() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeWindow(in: folder)
        let file = try #require(controller.editor.document?.url)
        let location = SourceLine(file: file, line: 3)
        await controller.debugger.toggleBreakpoint(at: location)
        await controller.setBreakpoint(location, enabled: false)

        controller.closeFolder(nil)

        #expect(controller.breakpointsPanel.entries.isEmpty)
    }
}
