import AppKit
import Testing
@testable import uMeil

/// Smoke tests for the M0 skeleton. They mostly prove that the test target
/// builds, links against the app, and runs in CI.
@MainActor
struct AppSetupTests {
    @Test func appInfoDescribesTheApp() {
        #expect(AppInfo.name == "uMeil")
        #expect(AppInfo.targetChip == "TM4C129")
        #expect(!AppInfo.version.isEmpty)
    }

    @Test func mainMenuHasTheStandardMenus() {
        let menu = MainMenu.make(appName: "uMeil")
        let titles = menu.items.compactMap { $0.submenu?.title }
        #expect(titles == ["uMeil", "File", "Edit", "View", "Product", "Debug", "Window"])
    }

    @Test func appMenuCanQuit() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let appMenu = try #require(menu.items.first?.submenu)
        let quit = try #require(appMenu.items.first { $0.title == "Quit uMeil" })
        #expect(quit.keyEquivalent == "q")
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
    }

    @Test func mainWindowHasANavigatorAndAnEditor() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        let split = try #require(window.contentViewController as? NSSplitViewController)

        #expect(window.title == "uMeil")
        #expect(window.styleMask.contains(.resizable))
        // The navigator beside a second split that stacks the editor over the bottom panel.
        #expect(split.splitViewItems.first?.viewController == controller.navigator)
        let editorSplit = try #require(split.splitViewItems.last?.viewController as? NSSplitViewController)
        #expect(editorSplit.splitViewItems.map(\.viewController) == [controller.editor, controller.bottomPanel])
        #expect(editorSplit.splitViewItems.last?.isCollapsed == true)
    }

    @Test func findMenuDrivesTheFindBar() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let edit = try #require(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let find = try #require(edit.items.first { $0.title == "Find" }?.submenu)

        #expect(find.items.map(\.tag) == [
            NSTextFinder.Action.showFindInterface.rawValue,
            NSTextFinder.Action.showReplaceInterface.rawValue,
            NSTextFinder.Action.nextMatch.rawValue,
            NSTextFinder.Action.previousMatch.rawValue,
            NSTextFinder.Action.setSearchString.rawValue
        ])
        #expect(find.items.allSatisfy { $0.action == #selector(NSResponder.performTextFinderAction(_:)) })
    }
}
