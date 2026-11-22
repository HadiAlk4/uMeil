import AppKit
import Testing
@testable import uMeil

/// Tests for the debugger's inspection panels (`Regs`, `Call Stack + Locals`,
/// `Disassembly`, `Memory 1`, `Watch 1`, `Command`), editor hover tooltips,
/// and the layout transition between editing and debugging (`FR-1.2`).
@MainActor
struct DebugPanelsTests {
    // MARK: - Formatting and Cortex-M status

    @Test func hexadecimalDisplayShowsSignedNegativesInTwosComplementAndTogglesToDecimal() {
        // FR-5.5: -99 in 32-bit two's complement hex is 0xFFFFFF9D.
        #expect(DebugValueFormatter.format("-99", type: "int", hexadecimal: true) == "0xFFFFFF9D")
        #expect(DebugValueFormatter.format("-99", type: "int", hexadecimal: false) == "-99")
        #expect(DebugValueFormatter.format("0xFFFFFF9D", type: "int", hexadecimal: false) == "-99")
        // Pointers stay hexadecimal in both modes.
        #expect(DebugValueFormatter.format("0x20000258", type: "int *", hexadecimal: false) == "0x20000258")
    }

    @Test func xpsrAndControlDecodeIntoFlagsAndProcessorState() {
        // 0x61000000 has Z=1, C=1, T=1, ISR=0 (Thread mode).
        let flags = DebugValueFormatter.xpsrBitfields(0x6100_0000)
        let byName = Dictionary(uniqueKeysWithValues: flags.map { ($0.name, $0.value) })
        #expect(byName["N"] == "0")
        #expect(byName["Z"] == "1")
        #expect(byName["C"] == "1")
        #expect(byName["V"] == "0")
        #expect(byName["T"] == "1")
        #expect(byName["ISR"] == "0")

        let state = DebugValueFormatter.executionState(xpsr: 0x6100_0000, control: 0)
        #expect(state == [
            DebugValueFormatter.Bitfield(name: "Mode", value: "Thread"),
            DebugValueFormatter.Bitfield(name: "Privilege", value: "Privileged"),
            DebugValueFormatter.Bitfield(name: "Stack", value: "MSP")
        ])
    }

    // MARK: - Registers panel (FR-7.1, FR-7.2, FR-5.3)

    @Test func registersPanelListsCoreSpecialAndInternalStateAndHighlightsChanges() {
        let panel = RegistersViewController()
        let firstStop = [
            RegisterValue(name: "r0", value: 0),
            RegisterValue(name: "sp", value: 0x2003_FFF0),
            RegisterValue(name: "pc", value: 0x0000_020A),
            RegisterValue(name: "xpsr", value: 0x6100_0000),
            RegisterValue(name: "control", value: 0)
        ]
        panel.update(with: firstStop)
        #expect(panel.nodes.map(\.name) == ["R0", "SP (R13)", "PC (R15)", "xPSR", "CONTROL", "Internal"])
        #expect(panel.changedNames.isEmpty)
        let xpsrNode = panel.nodes.first { $0.key == "xpsr" }
        #expect(xpsrNode?.children.count == 7)

        let secondStop = [
            RegisterValue(name: "r0", value: 5),
            RegisterValue(name: "sp", value: 0x2003_FFF0),
            RegisterValue(name: "pc", value: 0x0000_0222),
            RegisterValue(name: "xpsr", value: 0x6100_0000),
            RegisterValue(name: "control", value: 0)
        ]
        panel.update(with: secondStop)
        #expect(panel.changedNames == ["r0", "pc"])
        #expect(panel.nodes.first { $0.key == "r0" }?.value == "0x00000005")
        #expect(panel.nodes.first { $0.key == "r0" }?.isChanged == true)
    }

    // MARK: - Call Stack + Locals panel (FR-5.1 to FR-5.5)

    @Test func callStackAndLocalsShowFramesVariablesPointerExpansionAndHexToggle() async throws {
        let panel = CallStackLocalsViewController()
        let frameRecord = try MIParser.parse(
            #"^done,frame={level="0",addr="0x0000020a",func="main",fullname="/tmp/main.c",line="21"}"#
        )
        guard case .result(_, _, let frameVal) = frameRecord,
              let frame = frameVal["frame"].flatMap(StackFrame.init)
        else {
            Issue.record("Could not parse frame")
            return
        }
        let varsRecord = try MIParser.parse(
            #"^done,variables=[{name="a",arg="1",type="int",value="5"},"#
                + #"{name="result",type="int",value="-99"},{name="ptr",type="int *",value="0x20000258"}]"#
        )
        guard case .result(_, _, let varsVal) = varsRecord,
              let vars = varsVal["variables"]?.list?.compactMap(DebugVariable.init)
        else {
            Issue.record("Could not parse variables")
            return
        }

        panel.update(frames: [frame], variablesByFrame: [0: vars], dereferencedValues: ["*ptr": "-99"])
        #expect(panel.frameNodes.count == 1)
        let children = panel.frameNodes[0].children
        #expect(children.map(\.name) == ["a", "result", "ptr"])
        #expect(children.map(\.displayType) == ["param int", "auto int", "auto int *"])

        // Pointer node has a dereferenced child `*ptr` of type `int`.
        let ptrNode = try #require(children.last)
        #expect(ptrNode.children.first?.name == "*ptr")
        #expect(ptrNode.children.first?.displayType == "int")
        #expect(ptrNode.children.first?.rawValue == "-99")

        // Toggle between hex (default) and decimal.
        #expect(panel.useHexadecimal)
        panel.toggleHexadecimalDisplay(nil)
        #expect(!panel.useHexadecimal)
    }

    // MARK: - Disassembly, Memory, Watch, Command, and Hover

    @Test func disassemblyParsesCapturedInstructionsAndMarksTheProgramCounter() throws {
        let line = try BlinkySession.line(startingWith: "^done,asm_insns=")
        let record = try MIParser.parse(line)
        guard case .result(_, _, let values) = record,
              let list = values["asm_insns"]?.list
        else {
            Issue.record("Expected asm_insns")
            return
        }
        let instructions = DisassembledInstruction.parseList(list)
        #expect(instructions.count == 5)
        #expect(instructions.first?.address == 0x236)
        #expect(instructions.first?.opcodes == "00 22")
        #expect(instructions.first?.instruction == "movs r2, #0")

        let panel = DisassemblyViewController()
        panel.update(instructions: instructions, programCounter: 0x238)
        #expect(panel.rows.count == 5)
        #expect(panel.rows[1] == .instruction(instructions[1], isProgramCounter: true))
    }

    @Test func memoryPanelFormatsLittleEndianBytesAndWatchPanelTracksChanges() {
        let memory = MemoryViewController()
        // 0xFFFFFF9D (-99) stored in little-endian at 0x20000258 is 9D FF FF FF.
        memory.showMemory(at: 0x2000_0258, bytes: [0x9D, 0xFF, 0xFF, 0xFF])
        #expect(memory.rows.count == 1)
        #expect(memory.rows[0].addressText == "0x20000258")
        #expect(memory.rows[0].hexText == "9D FF FF FF")

        let watch = WatchViewController()
        watch.addExpression("result")
        watch.updateValues(["result": "0x00000000"])
        #expect(watch.entries.first?.isChanged == false)
        watch.updateValues(["result": "0xFFFFFF9D"])
        #expect(watch.entries.first?.value == "0xFFFFFF9D")
        #expect(watch.entries.first?.isChanged == true)

        let command = CommandViewController()
        var sent: String?
        command.onSendCommand = { sent = $0 }
        command.commandField.stringValue = "info registers"
        command.submitCommand()
        #expect(sent == "info registers")
        #expect(command.textView.string.contains("(gdb) info registers"))
    }

    @Test func commandConsoleCapsTextAtMaximumLength() {
        let command = CommandViewController()
        let chunk = String(repeating: "x", count: 1000) + "\n"
        command.appendOutput("oldest-line\n")
        for _ in 0..<550 {
            command.appendOutput(chunk)
        }
        command.appendOutput("newest-line\n")

        #expect((command.textView.string as NSString).length <= CommandViewController.maximumLength)
        #expect(!command.textView.string.contains("oldest-line"))
        #expect(command.textView.string.hasSuffix("newest-line\n"))
    }

    @Test func hoveringAnIdentifierInTheEditorShowsItsValueInTheTooltip() async {
        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        editor.textView.string = "int result = -99;\n"
        editor.onHoverIdentifier = { name in name == "result" ? "0xFFFFFF9D" : nil }

        let tip = await editor.showHoverValue(atCharacterIndex: 6)
        #expect(tip == "result = 0xFFFFFF9D")
        #expect(editor.textView.toolTip == "result = 0xFFFFFF9D")
    }

    @Test func findsTheWholeIdentifierUnderTheMouse() {
        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        editor.textView.string = "x = µ + count2 + 42;"

        #expect(editor.identifier(atCharacterIndex: 0) == "x")
        #expect(editor.identifier(atCharacterIndex: 10) == "count2")
        #expect(editor.identifier(atCharacterIndex: 13) == "count2")
        #expect(editor.identifier(atCharacterIndex: 18) == nil) // a number
        #expect(editor.identifier(atCharacterIndex: 4) == nil) // µ is not ASCII
        #expect(editor.identifier(atCharacterIndex: 99) == nil)
    }

    @Test func debugLayoutTransitionsInDuringASessionAndRestoresOnExit() {
        let controller = MainWindowController(boardMonitor: FakeBoardMonitor())
        let mainSplit = controller.window?.contentViewController as? NSSplitViewController
        #expect(!controller.debugPanels.isDebugLayoutVisible)
        #expect(mainSplit?.splitViewItems.count == 2)
        #expect(controller.editorSplit.splitViewItems.count == 2)

        if let mainSplit {
            controller.debugPanels.setLayoutVisible(true, mainSplit: mainSplit, editorSplit: controller.editorSplit)
        }
        #expect(controller.debugPanels.isDebugLayoutVisible)
        #expect(mainSplit?.splitViewItems.count == 3)
        #expect(controller.editorSplit.splitViewItems.count == 3)

        if let mainSplit {
            controller.debugPanels.setLayoutVisible(false, mainSplit: mainSplit, editorSplit: controller.editorSplit)
        }
        #expect(!controller.debugPanels.isDebugLayoutVisible)
        #expect(mainSplit?.splitViewItems.count == 2)
        #expect(controller.editorSplit.splitViewItems.count == 2)
    }
}
