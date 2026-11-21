import AppKit
import Testing
@testable import uMeil

@MainActor
struct WelcomeTests {
    func makeDefaults() throws -> UserDefaults {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeFolder(_ name: String, in temp: TemporaryDirectory) throws -> URL {
        let url = temp.url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Recent projects

    @Test func recentProjectsAreNewestFirstWithoutDuplicates() throws {
        let temp = try TemporaryDirectory()
        let first = try makeFolder("First", in: temp)
        let second = try makeFolder("Second", in: temp)
        let recent = RecentProjects(defaults: try makeDefaults())

        recent.add(first)
        recent.add(second)
        recent.add(first.appending(path: ""))

        #expect(recent.folders.map(\.lastPathComponent) == ["First", "Second"])
    }

    @Test func recentProjectsKeepOnlyTheLimit() throws {
        let temp = try TemporaryDirectory()
        let recent = RecentProjects(defaults: try makeDefaults())
        for index in 0...RecentProjects.limit {
            recent.add(try makeFolder("P\(index)", in: temp))
        }

        #expect(recent.folders.count == RecentProjects.limit)
        #expect(recent.folders.first?.lastPathComponent == "P\(RecentProjects.limit)")
        #expect(!recent.folders.map(\.lastPathComponent).contains("P0"))
    }

    @Test func recentProjectsSkipFoldersThatAreGone() throws {
        let temp = try TemporaryDirectory()
        let kept = try makeFolder("Kept", in: temp)
        let gone = try makeFolder("Gone", in: temp)
        let recent = RecentProjects(defaults: try makeDefaults())
        recent.add(kept)
        recent.add(gone)

        try FileManager.default.removeItem(at: gone)

        #expect(recent.folders.map(\.lastPathComponent) == ["Kept"])
    }

    // MARK: - Window

    @Test func theWelcomeScreenShowsUntilAFolderIsOpened() throws {
        let temp = try TemporaryDirectory()
        let controller = MainWindowController(defaults: try makeDefaults())
        #expect(!controller.editor.welcomeView.isHidden)

        controller.openFolder(temp.url)

        #expect(controller.editor.welcomeView.isHidden)
    }

    @Test func closingAFolderReturnsToTheWelcomeScreenListingIt() throws {
        let temp = try TemporaryDirectory()
        let project = try makeFolder("Blinky", in: temp)
        let defaults = try makeDefaults()
        let controller = MainWindowController(defaults: defaults)
        controller.openFolder(project)

        controller.closeFolder(nil)

        #expect(!controller.editor.welcomeView.isHidden)
        #expect(controller.editor.welcomeView.recentFolders.map(\.lastPathComponent) == ["Blinky"])
        #expect(controller.navigator.root == nil)
        #expect(controller.window?.subtitle == "")
        #expect(defaults.string(forKey: MainWindowController.lastFolderDefaultsKey) == nil)
    }

    @Test func choosingARecentProjectOpensIt() throws {
        let temp = try TemporaryDirectory()
        let project = try makeFolder("Blinky", in: temp)
        let controller = MainWindowController(defaults: try makeDefaults())

        controller.openRecentProject(project)

        #expect(controller.window?.subtitle == "Blinky")
    }

    @Test func choosingAMissingRecentProjectDropsIt() throws {
        let temp = try TemporaryDirectory()
        let project = try makeFolder("Blinky", in: temp)
        let defaults = try makeDefaults()
        let controller = MainWindowController(defaults: defaults)
        controller.recentProjects.add(project)
        try FileManager.default.removeItem(at: project)

        controller.openRecentProject(project)

        #expect(defaults.stringArray(forKey: RecentProjects.defaultsKey) == [])
        #expect(controller.window?.subtitle == "")
    }
}

extension WelcomeTests {
    private func isSidebarCollapsed(_ controller: MainWindowController) -> Bool? {
        let split = controller.window?.contentViewController as? NSSplitViewController
        return split?.splitViewItem(for: controller.navigator)?.isCollapsed
    }

    @Test func theSidebarIsHiddenOnlyOnTheWelcomeScreen() throws {
        let temp = try TemporaryDirectory()
        let controller = MainWindowController(defaults: try makeDefaults())
        #expect(isSidebarCollapsed(controller) == true)

        controller.openFolder(temp.url)
        #expect(isSidebarCollapsed(controller) == false)

        controller.closeFolder(nil)
        #expect(isSidebarCollapsed(controller) == true)
    }
}
