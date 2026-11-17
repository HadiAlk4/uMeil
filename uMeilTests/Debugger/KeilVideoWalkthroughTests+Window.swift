import AppKit
import Foundation
import Testing
@testable import uMeil

/// Reading the editor window the way the video's viewer does, and logging it.
extension KeilVideoWalkthroughTests {
    /// Where each stop is written, as `xcodebuild` keeps no test output.
    nonisolated static let logFile = FileManager.default.temporaryDirectory.appending(path: "umeil-keil-video.log")

    func log(_ text: String) {
        print("VIDEO| \(text)")
        if let handle = try? FileHandle(forWritingTo: Self.logFile) {
            handle.seekToEndOfFile()
            handle.write(Data("\(text)\n".utf8))
            try? handle.close()
        }
    }

    /// Waits longer than the shared helper: each step goes through the
    /// board's ICDI probe.
    func wait(
        _ what: String,
        seconds: Double = 15,
        sourceLocation: Testing.SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Timed out waiting until \(what)", sourceLocation: sourceLocation)
    }

    /// The text of the cell in `column` of `row`, as drawn.
    private func cellText(_ outline: NSOutlineView, column: Int, row: Int) -> String {
        (outline.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?
            .textField?.stringValue ?? "?"
    }

    /// The `Call Stack + Locals` panel as it reads on screen: one
    /// `name = value [type]` line per row, indented by depth.
    func localsText(_ panel: CallStackLocalsViewController) -> [String] {
        let outline = panel.outlineView
        return (0..<outline.numberOfRows).map { row in
            let indent = String(repeating: "  ", count: outline.level(forRow: row))
            let variable = outline.item(atRow: row) as? CallStackLocalsViewController.VariableNode
            let changed = variable?.isChanged == true ? " (changed)" : ""
            return indent + cellText(outline, column: 0, row: row) + " = " + cellText(outline, column: 1, row: row)
                + " [\(cellText(outline, column: 2, row: row))]" + changed
        }
    }

    /// The value cell of the first row called `name`, as shown.
    func shownValue(_ name: String, in panel: CallStackLocalsViewController) -> String? {
        let outline = panel.outlineView
        let row = (0..<outline.numberOfRows).first { cellText(outline, column: 0, row: $0) == name }
        return row.map { cellText(outline, column: 1, row: $0) }
    }

    func register(_ name: String, in panel: RegistersViewController) -> String? {
        panel.nodes.first { $0.key == name }?.value
    }

    /// Waits for the stop at `line` and for every panel to catch up, then logs them.
    func expectStop(
        _ controller: MainWindowController,
        line: Int,
        function: String,
        _ step: String,
        sourceLocation: Testing.SourceLocation = #_sourceLocation
    ) async {
        let panels = controller.debugPanels
        await wait("stopped at \(function):\(line)", sourceLocation: sourceLocation) {
            guard controller.debugger.isStopped, controller.editor.executionLine == line,
                  let top = panels.callStackLocals.frameNodes.first,
                  top.frame.line == line, top.name == function,
                  let address = top.frame.address
            else { return false }
            // Registers and disassembly refresh after the locals.
            return register("pc", in: panels.registers) == DebugValueFormatter.hex32(address)
                && highlightedInstruction(panels.disassembly)?.address == address
        }
        log("")
        log("== \(step)")
        log("status: \(controller.issues.statusLabel.stringValue)")
        let registers = ["pc", "sp", "lr"].map { "\($0.uppercased()) \(register($0, in: panels.registers) ?? "?")" }
        log(registers.joined(separator: "  "))
        if let instruction = highlightedInstruction(panels.disassembly) {
            log("disassembly: \(DebugValueFormatter.hex32(instruction.address))  \(instruction.instruction)")
        }
        for text in localsText(panels.callStackLocals) {
            log("  \(text)")
        }
    }

    private func highlightedInstruction(_ panel: DisassemblyViewController) -> DisassembledInstruction? {
        for row in panel.rows {
            if case .instruction(let instruction, true) = row { return instruction }
        }
        return nil
    }

    /// Debug > Reset, which stops in the startup code.
    func reset(_ controller: MainWindowController) async {
        controller.debugReset(nil)
        await wait("stopped after reset") {
            controller.debugger.isStopped
                && controller.debugPanels.callStackLocals.frameNodes.first?.name == "Reset_Handler"
        }
        log("")
        log("== Reset: \(controller.issues.statusLabel.stringValue)")
    }

    func putCursor(onLine line: Int, of controller: MainWindowController) {
        let text = controller.editor.textView.string as NSString
        var offset = 0
        for _ in 1..<line {
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
        }
        controller.editor.textView.setSelectedRange(NSRange(location: offset + 4, length: 0))
        #expect(controller.editor.cursorLine == line)
    }

    /// Expands `name` the way a click on its disclosure triangle does, and
    /// returns the value shown for what it points at.
    func expandPointer(_ name: String, in panel: CallStackLocalsViewController) async -> String? {
        guard let pointer = panel.frameNodes.first?.children.first(where: { $0.name == name }) else { return nil }
        panel.outlineView.collapseItem(pointer)
        pointer.children.first?.rawValue = nil
        panel.outlineView.expandItem(pointer)
        await wait("*\(name) is read") { pointer.children.first?.rawValue != nil }
        let value = shownValue("*\(name)", in: panel)
        log("*\(name) = \(value ?? "nothing")")
        return value
    }
}
