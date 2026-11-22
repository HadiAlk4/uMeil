import AppKit
import Foundation
import Testing
@testable import uMeil

struct EditorTabsTests {
    private let main = URL(filePath: "/p/src/main.c")
    private let uart = URL(filePath: "/p/src/uart.c")
    private let header = URL(filePath: "/p/inc/uart.h")

    @Test func opensNewTabsBesideTheShowingOne() {
        var tabs = EditorTabs()
        tabs.select(main)
        tabs.select(header)
        tabs.select(main)
        tabs.select(uart)

        #expect(tabs.urls == [main, uart, header])
        #expect(tabs.selectedURL == uart)
    }

    @Test func choosingAnOpenFileDoesNotAddASecondTab() {
        var tabs = EditorTabs()
        tabs.select(main)
        tabs.select(URL(filePath: "/p/src/../src/main.c"))

        #expect(tabs.urls.count == 1)
    }

    @Test func closingTheShowingTabMovesToItsNeighbour() {
        var tabs = EditorTabs()
        [main, uart, header].forEach { tabs.select($0) }
        tabs.select(uart)

        #expect(tabs.remove(uart) == header)
        tabs.select(header)
        #expect(tabs.remove(header) == main)
        tabs.select(main)
        #expect(tabs.remove(main) == nil)
        #expect(tabs.isEmpty)
    }

    @Test func closingABackgroundTabKeepsTheShowingOne() {
        var tabs = EditorTabs()
        [main, uart].forEach { tabs.select($0) }

        #expect(tabs.remove(main) == nil)
        #expect(tabs.selectedURL == uart)
    }

    @Test func keepsUnsavedTextUntilSaved() {
        var tabs = EditorTabs()
        tabs.select(main)
        tabs.stash(main, unsavedText: "int x;", selection: NSRange(location: 3, length: 0))

        #expect(tabs.tab(for: main)?.isModified == true)
        #expect(tabs.tab(for: main)?.selection.location == 3)
        tabs.markSaved(main)
        #expect(tabs.tab(for: main)?.isModified == false)
    }

    @Test func namesTabsAfterTheirFolderWhenNamesClash() {
        var tabs = EditorTabs()
        [main, URL(filePath: "/p/test/main.c"), uart].forEach { tabs.select($0) }

        #expect(tabs.titles() == ["main.c — src", "main.c — test", "uart.c"])
    }
}

@MainActor
struct EditorTabsInWindowTests {
    private struct Project {
        let temp: TemporaryDirectory
        var main: URL { temp.url.appending(path: "main.c") }
        var uart: URL { temp.url.appending(path: "uart.c") }
    }

    private func makeProject() throws -> Project {
        let project = Project(temp: try TemporaryDirectory())
        try Data("int main;\n".utf8).write(to: project.main)
        try Data("void uart;\n".utf8).write(to: project.uart)
        return project
    }

    private func makeController(folder: URL) throws -> MainWindowController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.answerSavePrompt = { _ in
            Issue.record("Nothing should ask to save")
            return .cancel
        }
        controller.openFolder(folder)
        return controller
    }

    private func type(_ text: String, in controller: MainWindowController) {
        controller.editor.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
    }

    @Test func openingFilesAddsTabs() throws {
        let project = try makeProject()
        let (temp, main, uart) = (project.temp, project.main, project.uart)
        let controller = try makeController(folder: temp.url)

        controller.openFile(main)
        controller.openFile(uart)

        #expect(controller.editor.tabBar.items.map(\.title) == ["main.c", "uart.c"])
        #expect(controller.editor.tabBar.items.map(\.isSelected) == [false, true])
    }

    @Test func switchingTabsKeepsUnsavedChangesWithoutAsking() throws {
        let project = try makeProject()
        let (temp, main, uart) = (project.temp, project.main, project.uart)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)
        type("// edited\n", in: controller)

        controller.navigator.select(nil)
        controller.openFile(uart)
        #expect(controller.editor.tabBar.items.first?.isModified == true)
        #expect(!controller.editor.isModified)

        controller.openFile(main)
        #expect(controller.editor.textView.string == "// edited\nint main;\n")
        #expect(controller.editor.isModified)
        #expect(try String(contentsOf: main, encoding: .utf8) == "int main;\n")
    }

    @Test func clickingATabShowsItsFile() throws {
        let project = try makeProject()
        let (temp, main, uart) = (project.temp, project.main, project.uart)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)
        controller.openFile(uart)

        controller.editor.tabBar.tabView(for: main)?.onSelect?()

        #expect(controller.editor.document?.url == main)
    }

    @Test func savingAllWritesTabsInTheBackground() throws {
        let project = try makeProject()
        let (temp, main, uart) = (project.temp, project.main, project.uart)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)
        type("// a\n", in: controller)
        controller.openFile(uart)
        type("// b\n", in: controller)

        #expect(controller.saveAllFiles())

        #expect(try String(contentsOf: main, encoding: .utf8) == "// a\nint main;\n")
        #expect(try String(contentsOf: uart, encoding: .utf8) == "// b\nvoid uart;\n")
        #expect(controller.editor.unsavedFiles.isEmpty)
    }

    @Test func closingAnUnsavedTabAsksAndCanSave() throws {
        let project = try makeProject()
        let (temp, main, uart) = (project.temp, project.main, project.uart)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)
        type("// a\n", in: controller)
        controller.openFile(uart)
        var asked: [[URL]] = []
        controller.answerSavePrompt = { files in
            asked.append(files)
            return .save
        }

        #expect(controller.closeTab(main))

        #expect(asked == [[main]])
        #expect(try String(contentsOf: main, encoding: .utf8) == "// a\nint main;\n")
        #expect(controller.editor.tabs.urls == [uart])
    }

    @Test func cancellingKeepsTheTab() throws {
        let project = try makeProject()
        let (temp, main) = (project.temp, project.main)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)
        type("// a\n", in: controller)
        controller.answerSavePrompt = { _ in .cancel }

        #expect(!controller.closeTab(main))
        #expect(controller.editor.document?.url == main)
        #expect(controller.editor.isModified)
    }

    @Test func closingTheShowingTabShowsTheNextAndTheLastLeavesTheHint() throws {
        let project = try makeProject()
        let (temp, main, uart) = (project.temp, project.main, project.uart)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)
        controller.openFile(uart)
        controller.openFile(main)

        controller.closeShowingTabOrWindow()
        #expect(controller.editor.document?.url == uart)

        controller.closeShowingTabOrWindow()
        #expect(controller.editor.document == nil)
        #expect(controller.editor.tabs.isEmpty)
        #expect(controller.window?.title == AppInfo.name)
    }

    @Test func closingTheFolderAsksAboutEveryUnsavedTab() throws {
        let project = try makeProject()
        let (temp, main, uart) = (project.temp, project.main, project.uart)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)
        type("// a\n", in: controller)
        controller.openFile(uart)
        type("// b\n", in: controller)
        var asked: [URL] = []
        controller.answerSavePrompt = { files in
            asked = files
            return .discard
        }

        #expect(controller.confirmDiscardingChanges())
        #expect(asked == [uart, main])
    }

    @Test func nextAndPreviousTabWrapAround() throws {
        let project = try makeProject()
        let (temp, main, uart) = (project.temp, project.main, project.uart)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)
        controller.openFile(uart)

        controller.showNextTab(nil)
        #expect(controller.editor.document?.url == main)
        controller.showPreviousTab(nil)
        #expect(controller.editor.document?.url == uart)
    }

    @Test func openingAnotherFolderClosesEveryTab() throws {
        let project = try makeProject()
        let (temp, main) = (project.temp, project.main)
        let controller = try makeController(folder: temp.url)
        controller.openFile(main)

        controller.openFolder(temp.url)

        #expect(controller.editor.tabs.isEmpty)
        #expect(controller.editor.tabBar.items.isEmpty)
    }

    @Test func commandWClosesATabAndCommandShiftWTheWindow() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        let closeTab = try #require(items.first { $0.title == "Close Tab" })
        let closeWindow = try #require(items.first { $0.title == "Close Window" })

        #expect(closeTab.keyEquivalent == "w" && closeTab.keyEquivalentModifierMask == [.command])
        #expect(closeWindow.keyEquivalent == "w" && closeWindow.keyEquivalentModifierMask == [.command, .shift])
    }
}
