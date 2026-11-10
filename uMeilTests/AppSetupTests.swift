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
        #expect(titles == ["uMeil", "Edit", "Window"])
    }

    @Test func appMenuCanQuit() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let appMenu = try #require(menu.items.first?.submenu)
        let quit = try #require(appMenu.items.first { $0.title == "Quit uMeil" })
        #expect(quit.keyEquivalent == "q")
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
    }

    @Test func mainWindowIsConfigured() throws {
        let controller = MainWindowController()
        let window = try #require(controller.window)
        #expect(window.title == "uMeil")
        #expect(window.styleMask.contains(.resizable))
    }
}
