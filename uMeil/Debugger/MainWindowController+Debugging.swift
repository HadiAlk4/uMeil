import AppKit

/// Tracks ad-hoc debug refresh tasks and deferred window-close state for `MainWindowController`.
@MainActor
struct DebugWindowTasks {
    var peripheralRefreshTask: Task<Void, Never>?
    var watchRefreshTask: Task<Void, Never>?
    var memoryTask: Task<Void, Never>?
    var executableLinesTask: Task<Void, Never>?
    var selectFrameTask: Task<Void, Never>?
    var isClosingAfterDebugStop = false
    var stopTimeout: Duration = .milliseconds(2500)

    mutating func cancelAll() {
        for task in [peripheralRefreshTask, watchRefreshTask, memoryTask, executableLinesTask, selectFrameTask] {
            task?.cancel()
        }
        (peripheralRefreshTask, watchRefreshTask, memoryTask) = (nil, nil, nil)
        (executableLinesTask, selectFrameTask) = (nil, nil)
    }
}

/// Turns the debugger's state into the one-line status under the issues list.
enum DebugSummary {
    /// For example "Stopped at main.c:21 in main" or "Running".
    static func statusText(for state: DebugController.State, reason: StopReason? = nil) -> String {
        switch state {
        case .idle:
            return "Debug session ended"
        case .starting:
            return "Starting debug session…"
        case .running:
            return "Running"
        case .stopped(let frame):
            let prefix = stopPrefix(for: reason)
            guard let frame else { return prefix }
            let function = frame.function.map { " in \($0)" } ?? ""
            if let file = frame.file, let line = frame.line {
                return "\(prefix) at \(file.lastPathComponent):\(line)\(function)"
            }
            let address = frame.address.map { " at 0x" + String($0, radix: 16) } ?? ""
            return "\(prefix)\(function)\(address), where there is no source code to show"
        }
    }

    private static func stopPrefix(for reason: StopReason?) -> String {
        switch reason {
        case .signal(let name, let meaning):
            // Pause (`-exec-interrupt`) always reports SIGINT, which is not a fault.
            if name == "SIGINT" { return "Stopped" }
            let label = !name.isEmpty ? name : (meaning ?? "signal")
            return "Stopped (\(label))"
        case .exited:
            return "Stopped (exited)"
        default:
            return "Stopped"
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
        debugPanels.callStackLocals.onSelectFrame = { [weak self] frame in self?.selectFrame(frame) }
        debugPanels.callStackLocals.onDereferenceInFrame = { [weak self] expr, level in
            await self?.debugger.evaluate(expr, inFrame: level)
        }
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
              self.folder == folder, !debugger.isActive, !isFlashing,
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
            debugPanels.command.clear()
            try await debugger.start(plan)
            return true
        } catch {
            editor.isReadOnly = false
            issues.show(debugFailure: error.localizedDescription, status: "Debug session failed to start")
            return false
        }
    }

    /// Stops GDB cleanly with a bounded timeout before closing `window` so
    /// closing the last window does not terminate the app with GDB still alive.
    func stopDebuggerAndClose(_ window: NSWindow) {
        guard !debugTasks.isClosingAfterDebugStop else { return }
        debugTasks.cancelAll()
        debugPanels.cancelRefresh()
        debugTasks.isClosingAfterDebugStop = true
        let timeout = debugTasks.stopTimeout
        Task { [weak self, weak window] in
            guard let self else { return }
            await debugger.stop(timeout: timeout)
            debugTasks.isClosingAfterDebugStop = false
            window?.close()
        }
    }

    private func debugStateChanged(_ state: DebugController.State) {
        editor.cancelHover()
        if let mainSplit = window?.contentViewController as? NSSplitViewController {
            debugPanels.setLayoutVisible(state != .idle, mainSplit: mainSplit, editorSplit: editorSplit)
        }
        // A failed start shows its own message; do not replace it.
        if state != .idle || editor.isReadOnly {
            issues.showDebugging(
                DebugSummary.statusText(for: state, reason: debugger.lastStopReason),
                isBusy: state == .starting
            )
        }
        debugPanels.setEditable(debugger.isStopped)
        toolbar.showDebugControls(state != .idle)
        debugTasks.cancelAll()
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
            scheduleDebugRefresh(at: frame)
        }
        window?.toolbar?.validateVisibleItems()
    }

    private func scheduleDebugRefresh(at frame: StackFrame?) {
        debugPanels.scheduleRefresh(
            using: debugger, at: frame, sourceText: editor.textView.string, sourceFile: editor.document?.url
        )
    }

    private func selectFrame(_ frame: StackFrame) {
        editor.cancelHover()
        showStop(at: frame)
        guard debugger.isStopped else { return }
        replaceTask(\.selectFrameTask) {
            await $0.debugger.selectFrame(frame.level)
            guard !Task.isCancelled, $0.debugger.isStopped, let address = frame.address else { return }
            let instructions = await $0.debugger.disassemble(from: address, count: 64)
            guard !Task.isCancelled, $0.debugger.isStopped, !instructions.isEmpty else { return }
            $0.debugPanels.updateDisassembly(
                instructions: instructions, programCounter: address,
                sourceText: $0.editor.textView.string, sourceFile: $0.editor.document?.url
            )
        }
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
            guard openFile(file) else {
                // Do not mark a line of whichever file stayed open.
                editor.showExecutionLine(nil)
                return
            }
            // `openFile` already called `refreshDebugMarks()`, which ran
            // `showExecutableLines()` and marked the top frame's line if it
            // matched; only mark `line` when showing a caller frame.
            if editor.executionLine != line {
                editor.showExecutionLine(line)
            }
            return
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
        debugTasks.executableLinesTask?.cancel()
        debugTasks.executableLinesTask = nil
        guard debugger.isActive, let file = editor.document?.url else { return }
        replaceTask(\.executableLinesTask) {
            let lines = await $0.debugger.executableLines(in: file)
            if !Task.isCancelled, $0.editor.document?.url == file, $0.debugger.isActive {
                $0.editor.executableLines = lines
            }
        }
    }

    // MARK: - Breakpoints

    /// Debug > Insert/Remove Breakpoint
    @objc func toggleBreakpointAtCursor(_ sender: Any?) { toggleBreakpoint(atLine: editor.cursorLine) }

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

    @objc func debugContinue(_ sender: Any?) { perform { try await $0.resume() } }
    @objc func debugPause(_ sender: Any?) { perform { try await $0.pause() } }
    @objc func debugStepInto(_ sender: Any?) { perform { try await $0.stepInto() } }
    @objc func debugStepOver(_ sender: Any?) { perform { try await $0.stepOver() } }
    @objc func debugStepOut(_ sender: Any?) { perform { try await $0.stepOut() } }
    @objc func debugReset(_ sender: Any?) { perform { try await $0.reset() } }

    /// Debug > Run to Cursor Line
    @objc func debugRunToCursor(_ sender: Any?) {
        guard let file = editor.document?.url else { return }
        let location = SourceLine(file: file, line: editor.cursorLine)
        perform { try await $0.run(to: location) }
    }

    /// Runs a debugger action and shows the reason if GDB refuses it, such
    /// as stepping out of `main`.
    private func perform(_ action: @escaping @MainActor (DebugController) async throws -> Void) {
        debugTasks.cancelAll()
        debugPanels.cancelRefresh()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await action(debugger)
            } catch {
                issues.showDebugging(error.localizedDescription)
            }
        }
    }

    private func replaceTask(
        _ keyPath: WritableKeyPath<DebugWindowTasks, Task<Void, Never>?>,
        _ work: @escaping @MainActor (MainWindowController) async -> Void
    ) {
        debugTasks[keyPath: keyPath]?.cancel()
        debugTasks[keyPath: keyPath] = Task { [weak self] in
            guard let self else { return }
            await work(self)
        }
    }

    private func refreshWatchedExpressions() {
        replaceTask(\.watchRefreshTask) { await $0.debugPanels.refreshWatches(using: $0.debugger) }
    }
    private func inspectMemory(_ query: String) {
        replaceTask(\.memoryTask) { await $0.debugPanels.inspectMemory(query: query, using: $0.debugger) }
    }
    private func refreshMemoryView() {
        replaceTask(\.memoryTask) { await $0.debugPanels.refreshMemory(using: $0.debugger) }
    }
    private func refreshPeripheralView() {
        replaceTask(\.peripheralRefreshTask) { await $0.debugPanels.refreshPeripheral(using: $0.debugger) }
    }

    private func writeMemory(_ bytes: [UInt8], at address: UInt64) {
        replaceTask(\.memoryTask) {
            if let failure = await $0.debugPanels.writeMemory(at: address, bytes: bytes, using: $0.debugger) {
                $0.issues.showDebugging(failure)
            } else if !Task.isCancelled, case .stopped(let frame) = $0.debugger.state {
                $0.editor.cancelHover()
                $0.scheduleDebugRefresh(at: frame)
            }
        }
    }

    private func writePeripheral(_ peripheral: SVDPeripheral, register: SVDRegister, field: SVDField?, text: String) {
        guard debugger.isStopped else { return }
        replaceTask(\.peripheralRefreshTask) {
            await $0.debugPanels.writePeripheral(
                peripheral, register: register, field: field, text: text,
                using: $0.debugger, isStopped: $0.debugger.isStopped
            )
        }
    }

    private func readPeripheralRegister(_ register: SVDRegister, of peripheral: SVDPeripheral) {
        guard debugger.isStopped else { return }
        replaceTask(\.peripheralRefreshTask) {
            await $0.debugPanels.readPeripheralRegister(register, of: peripheral, using: $0.debugger)
        }
    }

    private func sendConsoleCommand(_ command: String) {
        Task { [weak self] in
            guard let self else { return }
            let wasStopped = debugger.isStopped
            do {
                try await debugger.sendConsoleCommand(command)
                if wasStopped, case .stopped(let frame) = debugger.state {
                    editor.cancelHover()
                    scheduleDebugRefresh(at: frame)
                }
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
