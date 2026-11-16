import AppKit

/// Turns the debugger's state into the one-line status under the issues list.
enum DebugSummary {
    /// For example "Stopped at main.c:21 in main" or "Running".
    static func statusText(for state: DebugController.State) -> String {
        switch state {
        case .idle:
            return "Debug session ended"
        case .starting:
            return "Starting debug session…"
        case .running:
            return "Running"
        case .stopped(let frame):
            guard let frame else { return "Stopped" }
            let function = frame.function.map { " in \($0)" } ?? ""
            if let file = frame.file, let line = frame.line {
                return "Stopped at \(file.lastPathComponent):\(line)\(function)"
            }
            let address = frame.address.map { " at 0x" + String($0, radix: 16) } ?? ""
            return "Stopped\(function)\(address), where there is no source code to show"
        }
    }
}

extension MainWindowController {
    // MARK: - Setup

    /// Connects the debugger to the editor's gutter and the status line.
    func setUpDebugging() {
        editor.onClickGutterLine = { [weak self] line in self?.toggleBreakpoint(atLine: line) }
        debugger.onStateChange = { [weak self] state in self?.debugStateChanged(state) }
        debugger.onBreakpointsChange = { [weak self] in self?.showBreakpoints() }
    }

    // MARK: - Session

    /// Debug > Start/Stop Debug Session, and the toolbar's Debug button.
    @objc func toggleDebugging(_ sender: Any?) {
        Task {
            if debugger.isActive {
                await debugger.stop()
            } else {
                await startDebugging()
            }
        }
    }

    /// Builds the project in the open folder and, if that worked, writes it
    /// to the board and runs it to `main` under the debugger.
    ///
    /// Returns false when no session was started. The reason is shown in the
    /// issues panel.
    @discardableResult
    func startDebugging() async -> Bool {
        guard !debugger.isActive, !isFlashing, let folder else { return false }
        guard let build = await build(), build.succeeded, let image = build.elf,
              let projectFile = BuildSummary.projectFile(in: folder)
        else { return false }

        do {
            let project = try ProjectFile.load(from: projectFile)
            let locator = makeToolLocator()
            guard let gdb = locator.locate(.debugger) else {
                throw DebugError.refused(
                    "The debugger (GDB) is not installed. Install it from Window > Toolchain Status."
                )
            }
            guard let openOCD = locator.locate(.openOCD) else {
                throw FlashFailure.openOCDNotFound
            }
            let plan = DebugPlan(gdb: gdb, openOCD: openOCD, image: image, chip: project.target.chip)
            // The code must match what is on the chip until the session ends.
            editor.isReadOnly = true
            try await debugger.start(plan)
            return true
        } catch {
            editor.isReadOnly = false
            issues.show(debugFailure: error.localizedDescription, status: "Debug session failed to start")
            return false
        }
    }

    private func debugStateChanged(_ state: DebugController.State) {
        // A failed start shows its own message; do not replace it.
        if state != .idle || editor.isReadOnly {
            issues.showDebugging(DebugSummary.statusText(for: state), isBusy: state == .starting)
        }
        switch state {
        case .idle:
            editor.isReadOnly = false
            editor.showExecutionLine(nil)
            editor.executableLines = []
        case .starting, .running:
            editor.showExecutionLine(nil)
        case .stopped(let frame):
            showStop(at: frame)
        }
        window?.toolbar?.validateVisibleItems()
    }

    /// Brings the line the program stopped on into view, opening its file
    /// if another one is showing.
    private func showStop(at frame: StackFrame?) {
        guard let file = frame?.file, let line = frame?.line,
              FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        else {
            editor.showExecutionLine(nil)
            return
        }
        if !isShowing(file) {
            openFile(file)
        }
        editor.showExecutionLine(line)
        showExecutableLines()
    }

    private func isShowing(_ file: URL) -> Bool {
        editor.document.map { SourceLine(file: $0.url, line: 0) } == SourceLine(file: file, line: 0)
    }

    // MARK: - Marks in the gutter

    /// Puts the debugger's marks back after the editor opened a file.
    func refreshDebugMarks() {
        showBreakpoints()
        if case .stopped(let frame) = debugger.state, let file = frame?.file, isShowing(file) {
            editor.showExecutionLine(frame?.line)
        }
        showExecutableLines()
    }

    private func showBreakpoints() {
        editor.breakpointLines = editor.document.map { debugger.breakpointLines(in: $0.url) } ?? []
    }

    /// Marks the lines of the open file that have code. Only known during a session.
    private func showExecutableLines() {
        guard debugger.isActive, let file = editor.document?.url else { return }
        Task {
            let lines = await debugger.executableLines(in: file)
            if editor.document?.url == file, debugger.isActive {
                editor.executableLines = lines
            }
        }
    }

    // MARK: - Breakpoints

    /// Debug > Insert/Remove Breakpoint
    @objc func toggleBreakpointAtCursor(_ sender: Any?) {
        toggleBreakpoint(atLine: editor.cursorLine)
    }

    private func toggleBreakpoint(atLine line: Int) {
        guard let file = editor.document?.url else { return }
        Task {
            if await !debugger.toggleBreakpoint(at: SourceLine(file: file, line: line)) {
                issues.showDebugging("Stop the program to change breakpoints")
                NSSound.beep()
            }
        }
    }

    // MARK: - Running

    /// Debug > Run
    @objc func debugContinue(_ sender: Any?) {
        perform { try await $0.resume() }
    }

    /// Debug > Stop
    @objc func debugPause(_ sender: Any?) {
        perform { try await $0.pause() }
    }

    /// Debug > Step
    @objc func debugStepInto(_ sender: Any?) {
        perform { try await $0.stepInto() }
    }

    /// Debug > Step Over
    @objc func debugStepOver(_ sender: Any?) {
        perform { try await $0.stepOver() }
    }

    /// Debug > Step Out
    @objc func debugStepOut(_ sender: Any?) {
        perform { try await $0.stepOut() }
    }

    /// Debug > Run to Cursor Line
    @objc func debugRunToCursor(_ sender: Any?) {
        guard let file = editor.document?.url else { return }
        let location = SourceLine(file: file, line: editor.cursorLine)
        perform { try await $0.run(to: location) }
    }

    /// Debug > Reset
    @objc func debugReset(_ sender: Any?) {
        perform { try await $0.reset() }
    }

    /// Runs a debugger action and shows the reason if GDB refuses it, such
    /// as stepping out of `main`.
    private func perform(_ action: @escaping @MainActor (DebugController) async throws -> Void) {
        Task {
            do {
                try await action(debugger)
            } catch {
                issues.showDebugging(error.localizedDescription)
            }
        }
    }

    /// Whether a Debug menu or toolbar command can run right now. True for
    /// commands that are not the debugger's.
    func isDebugActionEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(toggleDebugging(_:)):
            debugger.isActive || (folder != nil && !isBuilding && !isFlashing)
        case #selector(debugContinue(_:)), #selector(debugStepInto(_:)), #selector(debugStepOver(_:)),
             #selector(debugStepOut(_:)), #selector(debugReset(_:)):
            debugger.isStopped
        case #selector(debugRunToCursor(_:)):
            debugger.isStopped && editor.document != nil
        case #selector(debugPause(_:)):
            debugger.state == .running
        case #selector(toggleBreakpointAtCursor(_:)):
            editor.document != nil && (!debugger.isActive || debugger.isStopped)
        default:
            true
        }
    }
}
