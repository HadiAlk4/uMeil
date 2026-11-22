import AppKit

/// Coordinates the multi-pane debugging layout (`Regs`, `Call Stack + Locals`,
/// `Disassembly`, `Watch 1`, `Memory 1`, `Peripherals`) and refreshes them
/// when the program stops. `Command`, the debugger's console, lives in the
/// bottom panel's Debug tab.
@MainActor
final class DebugPanelsController {
    let registers = RegistersViewController()
    let callStackLocals = CallStackLocalsViewController()
    let disassembly = DisassemblyViewController()
    let watch = WatchViewController()
    let memory = MemoryViewController()
    let peripherals: PeripheralsViewController
    let command = CommandViewController()

    let auxiliaryTabs = NSTabViewController()
    let inspectorSplit = NSSplitViewController()
    let inspectorItem: NSSplitViewItem
    let disassemblyItem: NSSplitViewItem

    private(set) var isDebugLayoutVisible = false
    private var refreshTask: Task<Void, Never>?
    private var deviceTask: Task<Void, Never>?
    /// The SVD file the `Peripherals` panel describes. Replaceable for tests.
    var svdFile = SVDDevice.bundledFile()

    init(defaults: UserDefaults = .standard) {
        peripherals = PeripheralsViewController(defaults: defaults)
        for panel in [watch, memory, peripherals] as [NSViewController] {
            let tab = NSTabViewItem(viewController: panel)
            tab.label = panel.title ?? ""
            auxiliaryTabs.addTabViewItem(tab)
        }

        inspectorSplit.splitView.isVertical = false
        let regItem = NSSplitViewItem(viewController: registers)
        regItem.minimumThickness = 140
        let stackItem = NSSplitViewItem(viewController: callStackLocals)
        stackItem.minimumThickness = 140
        let tabsItem = NSSplitViewItem(viewController: auxiliaryTabs)
        tabsItem.minimumThickness = 140
        inspectorSplit.addSplitViewItem(regItem)
        inspectorSplit.addSplitViewItem(stackItem)
        inspectorSplit.addSplitViewItem(tabsItem)

        inspectorItem = NSSplitViewItem(viewController: inspectorSplit)
        inspectorItem.minimumThickness = 320

        disassemblyItem = NSSplitViewItem(viewController: disassembly)
        disassemblyItem.minimumThickness = 110

        // Collapsing is how they slide in and out when a session starts and ends.
        for item in [inspectorItem, disassemblyItem] {
            item.canCollapse = true
        }
    }

    /// Transitions the window between the standard editing layout and the
    /// multi-pane debugging perspective (`FR-1.2`). On screen, the panes
    /// slide in and out rather than appearing at once.
    func setLayoutVisible(
        _ visible: Bool,
        mainSplit: NSSplitViewController,
        editorSplit: NSSplitViewController
    ) {
        let window = mainSplit.view.window
        let items = [disassemblyItem, inspectorItem]
        if visible, !isDebugLayoutVisible {
            loadDeviceIfNeeded()
            let animated = PanelAnimation.shouldAnimate(in: window)
            if !editorSplit.splitViewItems.contains(disassemblyItem) {
                disassemblyItem.isCollapsed = animated
                let index = min(1, editorSplit.splitViewItems.count)
                editorSplit.insertSplitViewItem(disassemblyItem, at: index)
            }
            if !mainSplit.splitViewItems.contains(inspectorItem) {
                inspectorItem.isCollapsed = animated
                mainSplit.addSplitViewItem(inspectorItem)
            }
            isDebugLayoutVisible = true
            PanelAnimation.setCollapsed(false, items, in: window)
        } else if !visible, isDebugLayoutVisible {
            cancelRefresh()
            isDebugLayoutVisible = false
            clear()
            PanelAnimation.setCollapsed(true, items, in: window) { [weak self] in
                // A new session may have started while the panes slid away.
                guard let self, !isDebugLayoutVisible else { return }
                if editorSplit.splitViewItems.contains(disassemblyItem) {
                    editorSplit.removeSplitViewItem(disassemblyItem)
                }
                if mainSplit.splitViewItems.contains(inspectorItem) {
                    mainSplit.removeSplitViewItem(inspectorItem)
                }
                // Removed panes come back expanded next time.
                items.forEach { $0.isCollapsed = false }
            }
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func clear() {
        registers.clear()
        callStackLocals.clear()
        disassembly.clear()
        watch.clearValues()
        memory.clear()
        peripherals.clear()
    }

    /// Whether the user may type new values into memory and peripheral
    /// registers: only while the program is stopped.
    func setEditable(_ editable: Bool) {
        memory.isEditable = editable
        peripherals.isEditable = editable
    }

    /// Reads the SVD file in the background the first time the panels show.
    /// It takes a moment: the TM4C1294's describes some 2,000 registers.
    @discardableResult
    func loadDeviceIfNeeded() -> Task<Void, Never>? {
        guard peripherals.device == nil, deviceTask == nil else { return deviceTask }
        let file = svdFile
        deviceTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try SVDParser.parse(contentsOf: file) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let device):
                deviceTask = nil
                peripherals.setDevice(device)
            case .failure(let error):
                deviceTask = nil
                peripherals.showMessage("Cannot read the peripheral descriptions: \(error.localizedDescription)")
            }
        }
        return deviceTask
    }

    /// Schedules a refresh of all inspection panels for the stopped program.
    func scheduleRefresh(
        using debugger: DebugController,
        at stopFrame: StackFrame?,
        sourceText: String?,
        sourceFile: URL? = nil
    ) {
        cancelRefresh()
        refreshTask = Task { [weak self] in
            await self?.refresh(using: debugger, at: stopFrame, sourceText: sourceText, sourceFile: sourceFile)
        }
    }

    /// Queries GDB for the call stack, locals, registers, disassembly, watched
    /// expressions, and memory, then updates each panel.
    func refresh(
        using debugger: DebugController,
        at stopFrame: StackFrame?,
        sourceText: String?,
        sourceFile: URL? = nil
    ) async {
        guard debugger.isStopped, !Task.isCancelled else { return }
        let listedFrames = await debugger.frames()
        guard debugger.isStopped, !Task.isCancelled else { return }

        if listedFrames.isEmpty {
            let fallback = stopFrame.map { [$0] } ?? []
            callStackLocals.update(frames: fallback, variablesByFrame: [:])
        } else {
            var variablesByFrame: [Int: [DebugVariable]] = [:]
            for frame in listedFrames {
                guard debugger.isStopped, !Task.isCancelled else { return }
                variablesByFrame[frame.level] = await debugger.variables(inFrame: frame.level)
            }
            guard debugger.isStopped, !Task.isCancelled else { return }
            callStackLocals.update(frames: listedFrames, variablesByFrame: variablesByFrame)
        }

        guard debugger.isStopped, !Task.isCancelled else { return }
        let regValues = await debugger.registers()
        guard debugger.isStopped, !Task.isCancelled else { return }
        registers.update(with: regValues)

        let pcValue = stopFrame?.address
            ?? listedFrames.first?.address
            ?? regValues.first { $0.name.lowercased() == "pc" }?.value
        if let pcValue, debugger.isStopped, !Task.isCancelled {
            let instructions = await debugger.disassemble(from: pcValue, count: 64)
            guard debugger.isStopped, !Task.isCancelled else { return }
            let linesMap = Self.sourceLinesMap(from: sourceText)
            disassembly.update(
                instructions: instructions,
                programCounter: pcValue,
                sourceLines: linesMap,
                sourceFile: sourceFile
            )
        }

        await refreshWatches(using: debugger)
        await refreshMemory(using: debugger)
        await refreshPeripheral(using: debugger)
    }

    private static func sourceLinesMap(from text: String?) -> [Int: String] {
        guard let text else { return [:] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Int: String] = [:]
        for (index, line) in lines.enumerated() {
            result[index + 1] = String(line)
        }
        return result
    }
}

extension DebugPanelsController {
    /// Reads `Memory 1` again at its address.
    func refreshMemory(using debugger: DebugController) async {
        guard let address = memory.currentAddress, debugger.isStopped, !Task.isCancelled else { return }
        if let bytes = await debugger.readMemory(at: address, count: memory.byteCount) {
            guard debugger.isStopped, !Task.isCancelled, memory.currentAddress == address else { return }
            memory.showMemory(at: address, bytes: bytes)
        }
    }

    /// Reads the registers of the peripheral selected in `Peripherals`.
    func refreshPeripheral(using memory: some TargetMemory, isStopped: Bool) async {
        await refreshPeripheral(using: memory, isStillStopped: { isStopped })
    }

    func refreshPeripheral(using debugger: DebugController) async {
        await refreshPeripheral(using: debugger, isStillStopped: { debugger.isStopped })
    }

    private func refreshPeripheral(
        using memory: some TargetMemory,
        isStillStopped: () -> Bool,
        preservingChanged: Set<String> = []
    ) async {
        guard isStillStopped(), !Task.isCancelled else { return }
        if peripherals.device == nil {
            await loadDeviceIfNeeded()?.value
        }
        guard isStillStopped(), !Task.isCancelled, let peripheral = peripherals.selectedPeripheral else { return }
        let readings = await PeripheralAccess.read(peripheral, from: memory)
        guard isStillStopped(), !Task.isCancelled, peripherals.selectedPeripheral?.name == peripheral.name else {
            return
        }
        peripherals.update(readings: readings, for: peripheral, preservingChanged: preservingChanged)
        if let device = peripherals.device, let gate = PeripheralClock.gate(for: peripheral),
           await PeripheralClock.isOn(peripheral, in: device, memory: memory) == false {
            guard isStillStopped(), !Task.isCancelled, peripherals.selectedPeripheral?.name == peripheral.name else {
                return
            }
            peripherals.showMessage(PeripheralClock.offMessage(for: peripheral, gate: gate))
        }
    }

    /// Writes a value typed into `Peripherals`, then reads the peripheral
    /// again: a write can change other registers too, as setting a clock
    /// gate makes the peripheral readable. Returns the reason it failed.
    @discardableResult
    func writePeripheral(
        _ peripheral: SVDPeripheral,
        register: SVDRegister,
        field: SVDField?,
        text: String,
        using memory: some TargetMemory,
        isStopped: Bool = true
    ) async -> String? {
        let stillStopped = { isStopped && ((memory as? DebugController)?.isStopped ?? true) }
        guard stillStopped() else {
            peripherals.revertEdits()
            let message = "Stop the program to change peripheral registers."
            peripherals.showMessage(message)
            return message
        }
        do {
            let value = try await PeripheralAccess.apply(
                text, to: register, field: field, of: peripheral,
                known: peripherals.readings[register.name], in: memory
            )
            var preservedChanged: Set<String> = []
            if register.readHasSideEffects || !register.access.isReadable {
                peripherals.update(reading: .value(value), for: register, of: peripheral)
                if peripherals.changedRegisters.contains(register.name) {
                    preservedChanged.insert(register.name)
                }
            }
            // Reading again also replaces any earlier failure message.
            await refreshPeripheral(
                using: memory,
                isStillStopped: stillStopped,
                preservingChanged: preservedChanged
            )
            return nil
        } catch {
            peripherals.revertEdits()
            peripherals.showMessage(error.localizedDescription)
            return error.localizedDescription
        }
    }

    /// Reads a register whose read has side effects, because the user asked.
    func readPeripheralRegister(
        _ register: SVDRegister,
        of peripheral: SVDPeripheral,
        using memory: some TargetMemory
    ) async {
        let reading = await PeripheralAccess.read(register, of: peripheral, from: memory)
        peripherals.update(reading: reading, for: register, of: peripheral)
    }

    /// Writes bytes typed into `Memory 1`, then reads the view again.
    func writeMemory(at address: UInt64, bytes: [UInt8], using debugger: DebugController) async -> String? {
        do {
            try await debugger.writeMemory(at: address, bytes: bytes)
        } catch {
            memory.revertEdits()
            return error.localizedDescription
        }
        await refreshMemory(using: debugger)
        return nil
    }

    /// Evaluates every expression in the `Watch 1` panel.
    func refreshWatches(using debugger: DebugController) async {
        let snapshot = watch.expressions
        guard debugger.isStopped, !Task.isCancelled, !snapshot.isEmpty else { return }
        var values: [String: String] = [:]
        for expr in snapshot {
            guard debugger.isStopped, !Task.isCancelled else { return }
            if let val = await debugger.evaluate(expr) {
                values[expr] = val
            }
        }
        guard debugger.isStopped, !Task.isCancelled else { return }
        watch.updateValues(values, evaluated: Set(snapshot))
    }

    /// Resolves `query` as a hex address or C expression and loads `Memory 1` from there.
    func inspectMemory(query: String, using debugger: DebugController) async {
        guard debugger.isStopped, !Task.isCancelled else { return }
        var address = DebugValueFormatter.parseAddress(query)
        if address == nil {
            if let evaluated = await debugger.evaluate(query) {
                guard debugger.isStopped, !Task.isCancelled else { return }
                address = MIValue.address(evaluated) ?? DebugValueFormatter.parseEvaluatedAddress(evaluated)
            } else {
                guard debugger.isStopped, !Task.isCancelled else { return }
            }
        }
        guard let address else {
            NSSound.beep()
            memory.showError("Cannot resolve address “\(query)”.")
            return
        }
        guard let bytes = await debugger.readMemory(at: address, count: memory.byteCount), !bytes.isEmpty else {
            guard debugger.isStopped, !Task.isCancelled else { return }
            NSSound.beep()
            memory.showError("Cannot read memory at \(DebugValueFormatter.hex32(address)).")
            return
        }
        guard debugger.isStopped, !Task.isCancelled else { return }
        memory.showMemory(at: address, bytes: bytes)
    }
}
