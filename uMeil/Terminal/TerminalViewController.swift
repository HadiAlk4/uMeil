import AppKit
import SwiftTerm

/// Abstraction over the terminal emulator view so window tests can verify
/// toggling, focus, and lifecycle without spawning a login shell.
@MainActor
protocol TerminalSessionView: AnyObject {
    var hostView: NSView { get }
    var isRunning: Bool { get }
    var onProcessTerminated: ((Int32?) -> Void)? { get set }
    var onDirectoryChanged: ((String?) -> Void)? { get set }
    var onTitleChanged: ((String) -> Void)? { get set }

    func start(config: TerminalLaunchConfig)
    func clear()
    func terminateSession()
}

/// Real `SwiftTerm` view hosting a local PTY shell, styled to match the editor
/// and adapting automatically to Light and Dark Mode.
final class SwiftTermSessionView: LocalProcessTerminalView, TerminalSessionView {
    var hostView: NSView { self }
    var isRunning: Bool { process.running }
    var onProcessTerminated: ((Int32?) -> Void)?
    var onDirectoryChanged: ((String?) -> Void)?
    var onTitleChanged: ((String) -> Void)?

    // Separate proxy avoids colliding with `LocalProcessTerminalView`'s own
    // non-open `TerminalViewDelegate` methods on `self`.
    private let delegateProxy = ProcessDelegateProxy()
    private var exitMonitor: (any DispatchSourceProcess)?
    private var didReportExit = false

    init() {
        super.init(frame: .zero)
        font = EditorTheme.font
        delegateProxy.owner = self
        processDelegate = delegateProxy
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SwiftTermSessionView is created in code, not from a nib")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            configureNativeColors()
        }
    }

    func start(config: TerminalLaunchConfig) {
        stopExitMonitor()
        didReportExit = false
        startProcess(
            executable: config.executable,
            args: config.arguments,
            environment: config.environment,
            execName: config.execName,
            currentDirectory: config.workingDirectory
        )
        monitorExit(pid: process.shellPid)
    }

    func clear() {
        if process.running {
            // CSI 3 J clears scrollback; Ctrl+L repaints the prompt at the top.
            feed(text: "\u{1B}[3J")
            process.send(data: [0x0C])
        } else {
            terminal.resetToInitialState()
        }
    }

    func terminateSession() {
        stopExitMonitor()
        didReportExit = true
        terminate()
    }

    fileprivate func handleProcessTerminated(rawStatus: Int32?) {
        guard !didReportExit else { return }
        didReportExit = true
        stopExitMonitor()
        onProcessTerminated?(rawStatus.map(Self.exitCode(from:)))
    }

    /// SwiftTerm 1.11.2 cancels its own exit monitor if PTY EOF arrives before
    /// `NOTE_EXIT`. Watching the child PID directly guarantees we still reap
    /// the status and notify the UI when a shell exits quickly.
    private func monitorExit(pid: pid_t) {
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, !self.didReportExit else { return }
            self.didReportExit = true
            self.stopExitMonitor()
            var status: Int32 = 0
            let reaped = waitpid(pid, &status, WNOHANG)
            let code = reaped == pid ? Self.exitCode(from: status) : nil
            self.onProcessTerminated?(code)
        }
        exitMonitor = source
        source.activate()
    }

    private func stopExitMonitor() {
        exitMonitor?.cancel()
        exitMonitor = nil
    }

    private static func exitCode(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7F
        if signal == 0 {
            return (waitStatus >> 8) & 0xFF
        }
        return 128 + signal
    }
}

@MainActor
private final class ProcessDelegateProxy: @preconcurrency LocalProcessTerminalViewDelegate {
    weak var owner: SwiftTermSessionView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        owner?.onTitleChanged?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        owner?.onDirectoryChanged?(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner?.handleProcessTerminated(rawStatus: exitCode)
    }
}

/// Hosts an interactive shell session inside the IDE's bottom panel.
/// The shell is launched lazily on first display rather than at window init.
final class TerminalViewController: NSViewController {
    private let session: any TerminalSessionView
    private let makeConfig: (URL?) -> TerminalLaunchConfig

    private(set) var hasStarted = false
    private(set) var currentFolder: URL?
    private(set) var currentDirectoryPath: String?
    private(set) var lastExitCode: Int32?

    var isRunning: Bool { session.isRunning }
    /// The responder that should receive keyboard input when the terminal opens.
    var focusableView: NSView { session.hostView }
    var onStatusChange: (() -> Void)?

    var statusText: String {
        if let code = lastExitCode, !session.isRunning {
            return "Shell exited (\(code))"
        }
        if let dir = currentDirectoryPath {
            let name = URL(fileURLWithPath: dir).lastPathComponent
            return name.isEmpty ? dir : name
        }
        return currentFolder?.lastPathComponent ?? "Terminal"
    }

    init(
        session: (any TerminalSessionView)? = nil,
        makeConfig: @escaping (URL?) -> TerminalLaunchConfig = { TerminalLaunchConfig.make(folder: $0) }
    ) {
        self.session = session ?? SwiftTermSessionView()
        self.makeConfig = makeConfig
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalViewController is created in code, not from a nib")
    }

    override func loadView() {
        let container = NSView()
        let hostView = session.hostView
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        view = container

        session.onDirectoryChanged = { [weak self] directory in
            guard let self else { return }
            currentDirectoryPath = Self.normalizedDirectory(from: directory)
            onStatusChange?()
        }
        session.onProcessTerminated = { [weak self] exitCode in
            guard let self else { return }
            lastExitCode = exitCode
            onStatusChange?()
        }
    }

    /// Remembers the open project folder so a not-yet-started shell opens there.
    func updateFolder(_ folder: URL?) {
        currentFolder = folder
        if !hasStarted {
            currentDirectoryPath = folder?.path(percentEncoded: false)
            onStatusChange?()
        }
    }

    /// Starts the shell on the first open (or when requested with no live shell).
    func startIfNeeded(folder: URL?) {
        currentFolder = folder
        // A shell that has exited (the user typed `exit`) is replaced too.
        guard !hasStarted || !session.isRunning else { return }
        launch(in: folder)
    }

    /// Terminates any running shell and launches a fresh one in `folder`.
    func restart(folder: URL?) {
        currentFolder = folder
        if session.isRunning {
            session.terminateSession()
        }
        launch(in: folder)
    }

    func clear() {
        session.clear()
    }

    func terminate() {
        if session.isRunning {
            session.terminateSession()
        }
    }

    private func launch(in folder: URL?) {
        loadViewIfNeeded()
        if view.window != nil {
            view.layoutSubtreeIfNeeded()
        }
        let config = makeConfig(folder)
        hasStarted = true
        lastExitCode = nil
        currentDirectoryPath = config.workingDirectory
        session.start(config: config)
        onStatusChange?()
    }

    private static func normalizedDirectory(from rawValue: String?) -> String? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        if let url = URL(string: rawValue), url.isFileURL {
            return url.path(percentEncoded: false)
        }
        return rawValue
    }
}
