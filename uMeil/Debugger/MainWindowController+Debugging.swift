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

    /// Connects the debugger to the editor's gutter, status line, and debug panels.
    func setUpDebugging() {
        editor.onClickGutterLine = { [weak self] line in self?.toggleBreakpoint(atLine: line) }
        editor.onHoverIdentifier = { [weak self] name in await self?.debugger.evaluate(name) }
        debugger.onStateChange = { [weak self] state in self?.debugStateChanged(state) }
        debugger.onBreakpointsChange = { [weak self] in self?.showBreakpoints() }
        debugger.onOutput = { [weak self] text in self?.debugPanels.command.appendOutput(text) }
        debugPanels.callStackLocals.onSelectFrame = { [weak self] frame in self?.showStop(at: frame) }
        debugPanels.callStackLocals.onDereference = { [weak self] expr in await self?.debugger.evaluate(expr) }
        debugPanels.watch.onExpressionsChanged = { [weak self] _ in self?.refreshWatchedExpressions() }
        debugPanels.memory.onRequestAddress = { [weak self] query in self?.inspectMemory(query) }
        debugPanels.memory.onLengthChange = { [weak self] in self?.refreshMemoryView() }
        debugPanels.memory.onWriteBytes = { [weak self] address, bytes in self?.writeMemory(bytes, at: address) }
        debugPanels.peripherals.onSelectPeripheral = { [weak self] _ in self?.refreshPeripheralView() }
        debugPanels.peripherals.onWrite = { [weak self] peripheral, register, field, text in
            self?.writePeripheral(peripheral, register: register, field: field, text: text)
        }
        debugPanels.peripherals.onReadNow = { [weak self] peripheral, register in
            self?.readPeripheralRegister(register, of: peripheral)
        }
        debugPanels.command.onSendCommand = { [weak self] cmd in self?.sendConsoleCommand(cmd) }
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
        if let mainSplit = window?.contentViewController as? NSSplitViewController {
            debugPanels.setLayoutVisible(state != .idle, mainSplit: mainSplit, editorSplit: editorSplit)
        }
        // A failed start shows its own message; do not replace it.
        if state != .idle || editor.isReadOnly {
            issues.showDebugging(DebugSummary.statusText(for: state), isBusy: state == .starting)
        }
        debugPanels.setEditable(debugger.isStopped)
        switch state {
        case .idle:
            editor.isReadOnly = false
            editor.showExecutionLine(nil)
            editor.executableLines = []
        case .starting, .running:
            debugPanels.cancelRefresh()
            editor.showExecutionLine(nil)
        case .stopped(let frame):
            showStop(at: frame)
            debugPanels.scheduleRefresh(using: debugger, at: frame, sourceText: editor.textView.string)
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
        debugPanels.cancelRefresh()
        Task {
            do {
                try await action(debugger)
            } catch {
                issues.showDebugging(error.localizedDescription)
            }
        }
    }

    private func refreshWatchedExpressions() {
        Task { await debugPanels.refreshWatches(using: debugger) }
    }

    private func inspectMemory(_ query: String) {
        Task { await debugPanels.inspectMemory(query: query, using: debugger) }
    }

    private func refreshMemoryView() {
        Task { await debugPanels.refreshMemory(using: debugger) }
    }

    private func writeMemory(_ bytes: [UInt8], at address: UInt64) {
        Task {
            if let failure = await debugPanels.writeMemory(at: address, bytes: bytes, using: debugger) {
                issues.showDebugging(failure)
            }
        }
    }

    private func refreshPeripheralView() {
        Task { await debugPanels.refreshPeripheral(using: debugger) }
    }

    private func writePeripheral(_ peripheral: SVDPeripheral, register: SVDRegister, field: SVDField?, text: String) {
        guard debugger.isStopped else { return }
        Task {
            await debugPanels.writePeripheral(peripheral, register: register, field: field, text: text, using: debugger)
        }
    }

    private func readPeripheralRegister(_ register: SVDRegister, of peripheral: SVDPeripheral) {
        guard debugger.isStopped else { return }
        Task { await debugPanels.readPeripheralRegister(register, of: peripheral, using: debugger) }
    }

    private func sendConsoleCommand(_ command: String) {
        Task {
            do {
                try await debugger.sendConsoleCommand(command)
            } catch {
                debugPanels.command.appendOutput("Error: \(error.localizedDescription)\n")
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
