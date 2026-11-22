import AppKit
import Testing
@testable import uMeil

/// Several projects open at once, one window each, in a single app.
@MainActor
struct MultipleWindowsTests {
    private func makeDelegate() throws -> AppDelegate {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let delegate = AppDelegate()
        delegate.makeController = { MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor()) }
        return delegate
    }

    private func makeProject(_ name: String, in folder: TemporaryFolder) throws -> URL {
        let template = try #require(try ProjectTemplate.all().first)
        return try template.createProject(named: name, in: folder.url).deletingLastPathComponent()
    }

    private func close(_ delegate: AppDelegate) {
        for controller in delegate.windowControllers {
            controller.window?.close()
        }
    }

    @Test func aProjectChosenInAnEmptyWindowOpensThere() throws {
        let folder = try TemporaryFolder()
        let project = try makeProject("Blinky", in: folder)
        let delegate = try makeDelegate()
        defer { close(delegate) }
        let empty = delegate.makeWindow()

        empty.window(forOpening: project).openItem(at: project)

        #expect(delegate.windowControllers.count == 1)
        #expect(empty.folder == project)
    }

    @Test func aSecondProjectOpensInItsOwnWindow() throws {
        let folder = try TemporaryFolder()
        let first = try makeProject("First", in: folder)
        let second = try makeProject("Second", in: folder)
        let delegate = try makeDelegate()
        defer { close(delegate) }
        let window = delegate.makeWindow()
        window.openItem(at: first)

        window.window(forOpening: second).openItem(at: second)

        #expect(delegate.windowControllers.count == 2)
        #expect(window.folder == first)
        #expect(delegate.windowControllers.last?.folder == second)
    }

    @Test func aProjectThatIsAlreadyOpenIsBroughtForwardNotOpenedAgain() throws {
        let folder = try TemporaryFolder()
        let first = try makeProject("First", in: folder)
        let second = try makeProject("Second", in: folder)
        let delegate = try makeDelegate()
        defer { close(delegate) }
        let firstWindow = delegate.makeWindow()
        firstWindow.openItem(at: first)
        let secondWindow = firstWindow.window(forOpening: second)
        secondWindow.openItem(at: second)

        let target = secondWindow.window(forOpening: first.appending(path: "main.c"))

        #expect(target === firstWindow)
        #expect(delegate.windowControllers.count == 2)
    }

    @Test func reopeningTheOpenFolderKeepsItsTabs() throws {
        let folder = try TemporaryFolder()
        let project = try makeProject("Blinky", in: folder)
        let delegate = try makeDelegate()
        defer { close(delegate) }
        let window = delegate.makeWindow()
        window.openItem(at: project.appending(path: "Blinky.umeil"))
        let shown = window.editor.document?.url

        window.openItem(at: project)

        #expect(shown != nil)
        #expect(window.editor.document?.url == shown)
    }

    @Test func aClosedWindowIsForgotten() throws {
        let delegate = try makeDelegate()
        let first = delegate.makeWindow()
        let second = delegate.makeWindow()

        second.window?.close()

        #expect(delegate.windowControllers.map(ObjectIdentifier.init) == [ObjectIdentifier(first)])
        close(delegate)
    }

    @Test func theDockMenuOffersANewWindow() throws {
        let delegate = try makeDelegate()

        let menu = try #require(delegate.applicationDockMenu(NSApp))

        #expect(menu.items.map(\.title) == ["New Window"])
        #expect(menu.items.first?.action == #selector(AppDelegate.newWindow(_:)))
    }
}
