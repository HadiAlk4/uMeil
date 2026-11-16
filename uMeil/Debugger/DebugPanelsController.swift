import AppKit

/// Coordinates the multi-pane debugging layout (`Regs`, `Call Stack + Locals`,
/// `Disassembly`, `Watch 1`, `Memory 1`, `Command`) and refreshes them when
/// the program stops.
@MainActor
final class DebugPanelsController {
    let registers = RegistersViewController()
    let callStackLocals = CallStackLocalsViewController()
    let disassembly = DisassemblyViewController()
    let watch = WatchViewController()
    let memory = MemoryViewController()
    let command = CommandViewController()

    let auxiliaryTabs = NSTabViewController()
    let inspectorSplit = NSSplitViewController()
    let inspectorItem: NSSplitViewItem
    let disassemblyItem: NSSplitViewItem

    private(set) var isDebugLayoutVisible = false
    private var refreshTask: Task<Void, Never>?

    init() {
        for panel in [watch, memory, command] {
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
    }

    /// Transitions the window between the standard editing layout and the
    /// multi-pane debugging perspective (`FR-1.2`).
    func setLayoutVisible(
        _ visible: Bool,
        mainSplit: NSSplitViewController,
        editorSplit: NSSplitViewController
    ) {
        if visible, !isDebugLayoutVisible {
            if !editorSplit.splitViewItems.contains(disassemblyItem) {
                let index = min(1, editorSplit.splitViewItems.count)
                editorSplit.insertSplitViewItem(disassemblyItem, at: index)
            }
            if !mainSplit.splitViewItems.contains(inspectorItem) {
                mainSplit.addSplitViewItem(inspectorItem)
            }
            isDebugLayoutVisible = true
        } else if !visible, isDebugLayoutVisible {
            cancelRefresh()
            if editorSplit.splitViewItems.contains(disassemblyItem) {
                editorSplit.removeSplitViewItem(disassemblyItem)
            }
            if mainSplit.splitViewItems.contains(inspectorItem) {
                mainSplit.removeSplitViewItem(inspectorItem)
            }
            isDebugLayoutVisible = false
            clear()
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
        memory.clear()
    }

    /// Schedules a refresh of all inspection panels for the stopped program.
    func scheduleRefresh(
        using debugger: DebugController,
        at stopFrame: StackFrame?,
        sourceText: String?
    ) {
        cancelRefresh()
        refreshTask = Task { [weak self] in
            await self?.refresh(using: debugger, at: stopFrame, sourceText: sourceText)
        }
    }

    /// Queries GDB for the call stack, locals, registers, disassembly, watched
    /// expressions, and memory, then updates each panel.
    func refresh(
        using debugger: DebugController,
        at stopFrame: StackFrame?,
        sourceText: String?
    ) async {
        guard debugger.isStopped, !Task.isCancelled else { return }
        let listedFrames = await debugger.frames()
        guard debugger.isStopped, !Task.isCancelled else { return }

        if listedFrames.isEmpty {
            let fallback = stopFrame.map { [$0] } ?? []
            callStackLocals.update(frames: fallback, variablesByFrame: [:])
            return
        }

        var variablesByFrame: [Int: [DebugVariable]] = [:]
        for frame in listedFrames {
            guard debugger.isStopped, !Task.isCancelled else { return }
            variablesByFrame[frame.level] = await debugger.variables(inFrame: frame.level)
        }
        callStackLocals.update(frames: listedFrames, variablesByFrame: variablesByFrame)

        guard debugger.isStopped, !Task.isCancelled else { return }
        let regValues = await debugger.registers()
        guard debugger.isStopped, !Task.isCancelled else { return }
        registers.update(with: regValues)

        let pcValue = stopFrame?.address
            ?? listedFrames.first?.address
            ?? regValues.first { $0.name.lowercased() == "pc" }?.value
        if let pcValue, debugger.isStopped, !Task.isCancelled {
            let instructions = await debugger.disassemble(from: pcValue, count: 64)
            let linesMap = Self.sourceLinesMap(from: sourceText)
            disassembly.update(instructions: instructions, programCounter: pcValue, sourceLines: linesMap)
        }

        await refreshWatches(using: debugger)
        if let address = memory.currentAddress, debugger.isStopped, !Task.isCancelled {
            if let bytes = await debugger.readMemory(at: address, count: 64) {
                memory.showMemory(at: address, bytes: bytes)
            }
        }
    }

    /// Evaluates every expression in the `Watch 1` panel.
    func refreshWatches(using debugger: DebugController) async {
        guard debugger.isStopped, !watch.expressions.isEmpty else { return }
        var values: [String: String] = [:]
        for expr in watch.expressions {
            guard debugger.isStopped, !Task.isCancelled else { return }
            if let val = await debugger.evaluate(expr) {
                values[expr] = val
            }
        }
        watch.updateValues(values)
    }

    /// Resolves `query` as a hex address or C expression and loads 64 bytes into `Memory 1`.
    func inspectMemory(query: String, using debugger: DebugController) async {
        guard debugger.isStopped else { return }
        var address = DebugValueFormatter.parseAddress(query)
        if address == nil, let evaluated = await debugger.evaluate(query) {
            address = MIValue.address(evaluated) ?? DebugValueFormatter.parseAddress(evaluated)
        }
        guard let address, let bytes = await debugger.readMemory(at: address, count: 64) else { return }
        memory.showMemory(at: address, bytes: bytes)
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
