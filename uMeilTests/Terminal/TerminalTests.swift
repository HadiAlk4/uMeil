import AppKit
import Foundation
import Testing
@testable import uMeil

private final class FocusableFakeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class FakeTerminalSessionView: TerminalSessionView {
    let hostView: NSView = FocusableFakeView()
    var isRunning = false
    var onProcessTerminated: ((Int32?) -> Void)?
    var onDirectoryChanged: ((String?) -> Void)?
    var onTitleChanged: ((String) -> Void)?

    private(set) var startedConfigs: [TerminalLaunchConfig] = []
    private(set) var clearCount = 0
    private(set) var terminateCount = 0

    func start(config: TerminalLaunchConfig) {
        startedConfigs.append(config)
        isRunning = true
    }

    func clear() {
        clearCount += 1
    }

    func terminateSession() {
        terminateCount += 1
        isRunning = false
    }

    func simulateExit(code: Int32? = 0) {
        isRunning = false
        onProcessTerminated?(code)
    }
}

struct TerminalLaunchConfigTests {
    @Test func resolvesLoginShellAndWorkingDirectory() throws {
        let project = try TemporaryDirectory()
        let home = URL(fileURLWithPath: "/Users/example")

        let config = TerminalLaunchConfig.make(
            folder: project.url,
            processEnvironment: [
                "SHELL": "/opt/homebrew/bin/fish",
                "PATH": "/usr/bin:/bin",
                "PWD": "/wrong/dir",
                "OLDPWD": "/other/dir",
                "SHLVL": "3"
            ],
            homeDirectory: home,
            isExecutable: { $0 == "/opt/homebrew/bin/fish" },
            isDirectory: { $0 == project.url.path(percentEncoded: false) },
            passwdShell: { "/bin/zsh" }
        )

        #expect(config.executable == "/opt/homebrew/bin/fish")
        #expect(config.execName == "-fish")
        #expect(config.arguments.isEmpty)
        #expect(config.workingDirectory == project.url.path(percentEncoded: false))
        #expect(config.environment.contains("TERM=xterm-256color"))
        #expect(config.environment.contains("COLORTERM=truecolor"))
        #expect(config.environment.contains("TERM_PROGRAM=uMeil"))
        #expect(config.environment.contains("LANG=en_US.UTF-8"))
        #expect(config.environment.contains("PATH=/usr/bin:/bin"))
        #expect(!config.environment.contains {
            $0.hasPrefix("PWD=") || $0.hasPrefix("OLDPWD=") || $0.hasPrefix("SHLVL=")
        })
    }

    @Test func fallsBackToPasswdShellAndHomeDirectory() {
        let home = URL(fileURLWithPath: "/Users/tester")

        let config = TerminalLaunchConfig.make(
            folder: URL(fileURLWithPath: "/missing/project"),
            processEnvironment: ["SHELL": "/missing/shell"],
            homeDirectory: home,
            isExecutable: { $0 == "/bin/bash" },
            isDirectory: { _ in false },
            passwdShell: { "/bin/bash" }
        )

        #expect(config.executable == "/bin/bash")
        #expect(config.execName == "-bash")
        #expect(config.workingDirectory == "/Users/tester")
    }

    @Test func fallsBackToZshWhenNoCandidateIsExecutable() {
        let config = TerminalLaunchConfig.make(
            folder: nil,
            processEnvironment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/tester"),
            isExecutable: { _ in false },
            isDirectory: { _ in false },
            passwdShell: { nil }
        )

        #expect(config.executable == "/bin/zsh")
        #expect(config.execName == "-zsh")
    }
}

@MainActor
struct TerminalWindowTests {
    private func makeIsolatedController(session: FakeTerminalSessionView) throws -> MainWindowController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = MainWindowController(defaults: defaults, makeTerminalSession: { session })
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 650), display: false)
        return controller
    }

    @Test func viewMenuExposesCommandJShortcutAndUpdatesTitle() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let viewMenu = try #require(menu.items.first { $0.submenu?.title == "View" }?.submenu)
        let toggleItem = try #require(viewMenu.items.first {
            $0.action == #selector(MainWindowController.toggleTerminal(_:))
        })

        #expect(toggleItem.keyEquivalent == "j")
        #expect(toggleItem.keyEquivalentModifierMask == [.command])

        let session = FakeTerminalSessionView()
        let controller = try makeIsolatedController(session: session)
        #expect(controller.validateMenuItem(toggleItem))
        #expect(toggleItem.title == "Show Terminal")

        controller.toggleTerminal(nil)
        #expect(controller.validateMenuItem(toggleItem))
        #expect(toggleItem.title == "Hide Terminal")
    }

    @Test func terminalStartsLazilyOnToggleAndPreservesShellAcrossHides() throws {
        let project = try TemporaryDirectory()
        let file = project.url.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: file)

        let session = FakeTerminalSessionView()
        let controller = try makeIsolatedController(session: session)
        controller.openFolder(project.url)
        controller.openFile(file)

        #expect(session.startedConfigs.isEmpty)
        #expect(!controller.isTerminalVisible)
        #expect(!controller.isIssuesPanelVisible)

        // First toggle opens the panel, launches the shell in the project folder,
        // and moves keyboard focus into the terminal view.
        controller.toggleTerminal(nil)
        #expect(controller.isTerminalVisible)
        #expect(!controller.isIssuesPanelVisible)
        #expect(session.startedConfigs.count == 1)
        #expect(session.startedConfigs.first?.workingDirectory == project.url.path(percentEncoded: false))
        #expect(controller.window?.firstResponder === controller.terminal.focusableView)

        // Second toggle collapses the panel without terminating the shell, and
        // returns focus to the open code editor.
        controller.toggleTerminal(nil)
        #expect(!controller.isTerminalVisible)
        #expect(session.terminateCount == 0)
        #expect(session.isRunning)
        #expect(controller.window?.firstResponder === controller.editor.textView)

        // Re-opening is instant and reuses the existing shell session.
        controller.toggleTerminal(nil)
        #expect(controller.isTerminalVisible)
        #expect(session.startedConfigs.count == 1)
    }

    @Test func switchesBetweenIssuesAndTerminalBeforeCollapsing() throws {
        let session = FakeTerminalSessionView()
        let controller = try makeIsolatedController(session: session)

        controller.showIssuesPanel()
        #expect(controller.isIssuesPanelVisible)
        #expect(!controller.isTerminalVisible)

        // Pressing Cmd+J while Issues is showing switches to Terminal instead of collapsing.
        controller.toggleTerminal(nil)
        #expect(controller.isTerminalVisible)
        #expect(!controller.isIssuesPanelVisible)
        #expect(session.startedConfigs.count == 1)

        controller.toggleTerminal(nil)
        #expect(!controller.isTerminalVisible)
        #expect(!controller.isIssuesPanelVisible)
    }

    @Test func restartAndWindowCloseManageSessionLifecycle() throws {
        let projectA = try TemporaryDirectory()
        let projectB = try TemporaryDirectory()
        let session = FakeTerminalSessionView()
        let controller = try makeIsolatedController(session: session)
        controller.openFolder(projectA.url)
        controller.toggleTerminal(nil)
        #expect(session.startedConfigs.last?.workingDirectory == projectA.url.path(percentEncoded: false))

        controller.openFolder(projectB.url)
        controller.bottomPanel.onRestartTerminal?()
        #expect(session.terminateCount == 1)
        #expect(session.startedConfigs.count == 2)
        #expect(session.startedConfigs.last?.workingDirectory == projectB.url.path(percentEncoded: false))

        let window = try #require(controller.window)
        #expect(controller.windowShouldClose(window))
        #expect(session.terminateCount == 2)
        #expect(!session.isRunning)
    }

    @Test func statusReflectsExitCodeAndDirectoryUpdates() throws {
        let temp = try TemporaryDirectory()
        let project = try temp.directory("Blinky")
        let session = FakeTerminalSessionView()
        let controller = TerminalViewController(session: session)
        controller.loadViewIfNeeded()

        controller.startIfNeeded(folder: project)
        #expect(controller.statusText == "Blinky")

        session.onDirectoryChanged?("file:///Users/test/Project")
        #expect(controller.statusText == "Project")

        controller.clear()
        #expect(session.clearCount == 1)

        session.simulateExit(code: 2)
        #expect(controller.statusText == "Shell exited (2)")
    }

    @Test func reopeningTheTerminalAfterTheShellExitedStartsANewShell() throws {
        let temp = try TemporaryDirectory()
        let project = try temp.directory("Blinky")
        let session = FakeTerminalSessionView()
        let controller = TerminalViewController(session: session)
        controller.loadViewIfNeeded()

        controller.startIfNeeded(folder: project)
        controller.startIfNeeded(folder: project)
        #expect(session.startedConfigs.count == 1)

        session.simulateExit(code: 0)
        controller.startIfNeeded(folder: project)
        #expect(session.startedConfigs.count == 2)
        #expect(controller.isRunning)
    }
}

@MainActor
struct RealSwiftTermIntegrationTests {
    @Test func launchesRealPtyProcessInProjectWorkingDirectory() async throws {
        let folder = try TemporaryDirectory()
        let marker = folder.url.appending(path: "pwd.txt")
        let script = "pwd > \"\(marker.path(percentEncoded: false))\""

        let terminal = TerminalViewController(
            makeConfig: { targetFolder in
                TerminalLaunchConfig(
                    executable: "/bin/sh",
                    arguments: ["-c", script],
                    execName: "sh",
                    environment: ["TERM=xterm-256color", "PATH=/bin:/usr/bin"],
                    workingDirectory: (targetFolder ?? folder.url).path(percentEncoded: false)
                )
            }
        )
        terminal.loadViewIfNeeded()
        terminal.startIfNeeded(folder: folder.url)

        let finished = await eventually {
            !terminal.isRunning
                && terminal.lastExitCode != nil
                && FileManager.default.fileExists(atPath: marker.path(percentEncoded: false))
        }
        #expect(finished)
        let recorded = try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRecorded = URL(fileURLWithPath: recorded).resolvingSymlinksInPath().path(percentEncoded: false)
        let resolvedExpected = folder.url.resolvingSymlinksInPath().path(percentEncoded: false)
        #expect(resolvedRecorded == resolvedExpected)
        #expect(terminal.lastExitCode == 0)
    }
}
