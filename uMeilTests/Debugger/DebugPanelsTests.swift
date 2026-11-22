// swiftlint:disable file_length
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
        // 550,000 characters, past the cap, in few appends: each one is a
        // trip through the text view's layout.
        let chunk = String(repeating: String(repeating: "x", count: 1000) + "\n", count: 10)
        command.appendOutput("oldest-line\n")
        for _ in 0..<55 {
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

extension DebugPanelsTests {
    private func makeFrame(
        level: Int, address: UInt64, function: String, file: URL? = nil, line: Int? = nil
    ) throws -> StackFrame {
        var fields = [
            MIField(name: "level", value: .string("\(level)")),
            MIField(name: "addr", value: .string(String(format: "0x%llx", address))),
            MIField(name: "func", value: .string(function))
        ]
        if let file { fields.append(MIField(name: "fullname", value: .string(file.path(percentEncoded: false)))) }
        if let line { fields.append(MIField(name: "line", value: .string("\(line)"))) }
        return try #require(StackFrame(.tuple(fields)))
    }

    private func makeVariable(
        name: String, isArgument: Bool = false, type: String? = nil, value: String? = nil
    ) throws -> DebugVariable {
        var fields = [MIField(name: "name", value: .string(name))]
        if isArgument { fields.append(MIField(name: "arg", value: .string("1"))) }
        if let type { fields.append(MIField(name: "type", value: .string(type))) }
        if let value { fields.append(MIField(name: "value", value: .string(value))) }
        return try #require(DebugVariable(.tuple(fields)))
    }

    private func makeInstruction(
        address: UInt64, instruction: String, file: URL?, line: Int?
    ) throws -> DisassembledInstruction {
        let value = MIValue.tuple([
            MIField(name: "address", value: .string(String(format: "0x%llx", address))),
            MIField(name: "func-name", value: .string("main")),
            MIField(name: "offset", value: .string("0")),
            MIField(name: "opcodes", value: .string("00 20")),
            MIField(name: "inst", value: .string(instruction))
        ])
        return try #require(DisassembledInstruction(value, file: file, line: line))
    }

    // MARK: - Regression tests: DebugValueFormatter

    @Test func sixtyFourBitIntegersAndUnsignedTypesFormatWithoutTruncation() {
        // 64-bit types stay 64-bit in hex mode, including negative values.
        #expect(DebugValueFormatter.format("-99", type: "int64_t", hexadecimal: true) == "0xFFFFFFFFFFFFFF9D")
        #expect(DebugValueFormatter.format("-1", type: "long long", hexadecimal: true) == "0xFFFFFFFFFFFFFFFF")
        #expect(DebugValueFormatter.format("5", type: "int64_t", hexadecimal: true) == "0x0000000000000005")
        #expect(DebugValueFormatter.format("5", type: "uint64_t", hexadecimal: true) == "0x0000000000000005")

        // Values outside 32-bit range format as 64-bit even without an explicit 64-bit type.
        #expect(DebugValueFormatter.format("4294967296", type: nil, hexadecimal: true) == "0x0000000100000000")
        #expect(DebugValueFormatter.format("-2147483649", type: nil, hexadecimal: true) == "0xFFFFFFFF7FFFFFFF")
        #expect(
            DebugValueFormatter.format("18446744073709551615", type: "unsigned long long", hexadecimal: true)
                == "0xFFFFFFFFFFFFFFFF"
        )

        // 32-bit values keep 8-digit hex.
        #expect(DebugValueFormatter.format("-99", type: "int", hexadecimal: true) == "0xFFFFFF9D")
        #expect(DebugValueFormatter.format("4294967295", type: "uint32_t", hexadecimal: true) == "0xFFFFFFFF")

        // 64-bit hex and size_t / uintptr_t in decimal mode.
        #expect(DebugValueFormatter.format("0xFFFFFFFFFFFFFF9D", type: "int64_t", hexadecimal: false) == "-99")
        #expect(
            DebugValueFormatter.format("0xFFFFFFFFFFFFFF9D", type: "uint64_t", hexadecimal: false)
                == "18446744073709551517"
        )
        #expect(DebugValueFormatter.format("0x0000000100000000", type: nil, hexadecimal: false) == "4294967296")
        #expect(DebugValueFormatter.format("0xFFFFFFFF", type: "int64_t", hexadecimal: false) == "4294967295")
        #expect(DebugValueFormatter.format("0xFFFFFFFF", type: "size_t", hexadecimal: false) == "4294967295")
        #expect(DebugValueFormatter.format("0xFFFFFFFF", type: "uintptr_t", hexadecimal: false) == "4294967295")
        #expect(DebugValueFormatter.format("0xFFFFFFFF", type: "ssize_t", hexadecimal: false) == "-1")
    }

    @Test func pointerDetectionAndDereferencedTypeHandleVoidFunctionArraysAndQualifiers() throws {
        func variable(type: String?) throws -> DebugVariable {
            let typeAttr = type.map { ",type=\"\($0)\"" } ?? ""
            let rec = try MIParser.parse("^done,v={name=\"p\"\(typeAttr),value=\"0x20000000\"}")
            guard case .result(_, _, let val) = rec, let item = val["v"].flatMap(DebugVariable.init) else {
                throw MIParseError(line: "variable")
            }
            return item
        }

        #expect(DebugValueFormatter.isPointer(try variable(type: "int *")))
        #expect(DebugValueFormatter.isPointer(try variable(type: "const int * const")))
        #expect(DebugValueFormatter.isPointer(try variable(type: "void **")))
        #expect(!DebugValueFormatter.isPointer(try variable(type: "void *")))
        #expect(!DebugValueFormatter.isPointer(try variable(type: "const void *")))
        #expect(!DebugValueFormatter.isPointer(try variable(type: "volatile void * const")))
        #expect(!DebugValueFormatter.isPointer(try variable(type: "void (*)(void)")))
        #expect(!DebugValueFormatter.isPointer(try variable(type: "int (*callback)(int)")))
        #expect(!DebugValueFormatter.isPointer(try variable(type: "int *[4]")))
        #expect(!DebugValueFormatter.isPointer(try variable(type: "char *[]")))

        #expect(DebugValueFormatter.dereferencedType("const int * const") == "const int")
        #expect(DebugValueFormatter.dereferencedType("int * volatile restrict") == "int")
        #expect(DebugValueFormatter.dereferencedType("int **") == "int *")
    }

    @Test func evaluatedAddressParsingHandlesUppercaseHexAndGDBCastPrefixes() {
        #expect(DebugValueFormatter.parseEvaluatedAddress("0x20000258") == 0x2000_0258)
        #expect(DebugValueFormatter.parseEvaluatedAddress("0X20000258") == 0x2000_0258)
        #expect(DebugValueFormatter.parseEvaluatedAddress("(int (*)[4]) 0x20000258") == 0x2000_0258)
        #expect(DebugValueFormatter.parseEvaluatedAddress("(int *) 0X20000258 <result>") == 0x2000_0258)
        #expect(DebugValueFormatter.parseEvaluatedAddress("{int (void)} 0x20a <main>") == 0x20A)
        #expect(DebugValueFormatter.parseEvaluatedAddress("536871512") == 0x2000_0258)
        #expect(DebugValueFormatter.parseEvaluatedAddress("main") == nil)
        #expect(DebugValueFormatter.parseEvaluatedAddress("{a = 1}") == nil)
        #expect(DebugValueFormatter.parseEvaluatedAddress("0x12G") == nil)
    }

    // MARK: - Regression tests: Disassembly

    @Test func disassemblyInterleavesSourceOnlyWhenFileMatchesSourceFile() throws {
        let folder = try TemporaryFolder()
        let realMain = folder.url.appending(path: "main.c")
        let otherFile = folder.url.appending(path: "other.c")
        try "int x = 1;\nint y = 2;\n".write(to: realMain, atomically: true, encoding: .utf8)
        try "int z = 3;\n".write(to: otherFile, atomically: true, encoding: .utf8)
        let symlinkMain = folder.url.appending(path: "link_main.c")
        try FileManager.default.createSymbolicLink(at: symlinkMain, withDestinationURL: realMain)

        let instMain = try makeInstruction(address: 0x200, instruction: "movs r0, #0", file: realMain, line: 1)
        let instOther = try makeInstruction(address: 0x202, instruction: "movs r0, #1", file: otherFile, line: 2)
        let instNoFile = try makeInstruction(address: 0x204, instruction: "movs r0, #2", file: nil, line: 1)
        let sourceLines = [1: "int x = 1;", 2: "int y = 2;"]
        let panel = DisassemblyViewController()

        // Matching symlinked sourceFile interleaves main.c but skips other.c.
        panel.update(
            instructions: [instMain, instOther],
            programCounter: 0x200,
            sourceLines: sourceLines,
            sourceFile: symlinkMain
        )
        #expect(panel.rows == [
            .source(line: 1, text: "int x = 1;"),
            .instruction(instMain, isProgramCounter: true),
            .instruction(instOther, isProgramCounter: false)
        ])

        // Nil sourceFile skips instructions that carry an inst.file, but keeps interleaving for nil inst.file.
        panel.update(
            instructions: [instMain, instNoFile],
            programCounter: 0x204,
            sourceLines: sourceLines,
            sourceFile: nil
        )
        #expect(panel.rows == [
            .instruction(instMain, isProgramCounter: false),
            .source(line: 1, text: "int x = 1;"),
            .instruction(instNoFile, isProgramCounter: true)
        ])
    }

    // MARK: - Regression tests: Call Stack + Locals

    @Test func callStackLocalsAvoidsCrossFunctionChangeCollisions() throws {
        let panel = CallStackLocalsViewController()
        let main0 = try makeFrame(level: 0, address: 0x200, function: "main", line: 10)
        let main1 = try makeFrame(level: 1, address: 0x200, function: "main", line: 10)
        let helper0 = try makeFrame(level: 0, address: 0x300, function: "helper", line: 4)
        let varMainA = try makeVariable(name: "a", type: "int", value: "1")
        let varHelperA1 = try makeVariable(name: "a", isArgument: true, type: "int", value: "99")
        let varHelperA2 = try makeVariable(name: "a", isArgument: true, type: "int", value: "100")

        // Stop 1: in main, a = 1.
        panel.update(frames: [main0], variablesByFrame: [0: [varMainA]])
        #expect(panel.changedKeys.isEmpty)

        // Stop 2: stepped into helper(a=99) above main(a=1); neither variable changed.
        panel.update(frames: [helper0, main1], variablesByFrame: [0: [varHelperA1], 1: [varMainA]])
        #expect(panel.changedKeys.isEmpty)

        // Stop 3: helper's a changes 99 -> 100 while main's a stays 1.
        panel.update(frames: [helper0, main1], variablesByFrame: [0: [varHelperA2], 1: [varMainA]])
        #expect(panel.changedKeys == ["0:a"])

        // Stop 4: back in main with a still 1; must not falsely collide with helper's a.
        panel.update(frames: [main0], variablesByFrame: [0: [varMainA]])
        #expect(panel.changedKeys.isEmpty)
    }

    @Test func callStackLocalsDereferencesInFramePreservesExpansionHandlesNilAndKeyboardSelect() async throws {
        let panel = CallStackLocalsViewController()
        let helper0 = try makeFrame(level: 0, address: 0x300, function: "helper", line: 4)
        let main1 = try makeFrame(level: 1, address: 0x200, function: "main", line: 10)
        let ptrHelper = try makeVariable(name: "p", type: "int *", value: "0x20000004")
        let ptrMain = try makeVariable(name: "p", type: "int *", value: "0x20000008")

        // Frame-qualified dereferencedValues disambiguate same pointer name in two frames.
        panel.update(
            frames: [helper0, main1],
            variablesByFrame: [0: [ptrHelper], 1: [ptrMain]],
            dereferencedValues: ["0:*p": "11", "1:*p": "22"]
        )
        #expect(panel.frameNodes[0].children.first?.children.first?.rawValue == "11")
        #expect(panel.frameNodes[1].children.first?.children.first?.rawValue == "22")

        // Keyboard selection triggers onSelectFrame; mouse click (selectionDidChange + rowClicked)
        // deduplicates to a single call, while re-clicking an already-selected frame fires again.
        var selectedFrames: [StackFrame] = []
        panel.onSelectFrame = { selectedFrames.append($0) }
        let mainRow = panel.outlineView.row(forItem: panel.frameNodes[1])
        panel.outlineView.selectRowIndexes(IndexSet(integer: mainRow), byExtendingSelection: false)
        panel.rowClicked(nil)
        #expect(selectedFrames == [main1])
        panel.rowClicked(nil)
        #expect(selectedFrames == [main1, main1])

        // Expanding a pointer in frame 1 uses onDereferenceInFrame with frameLevel == 1.
        var derefCalls: [(String, Int)] = []
        var returnNil = false
        panel.onDereferenceInFrame = { expr, level in
            derefCalls.append((expr, level))
            return returnNil ? nil : "42"
        }
        panel.update(frames: [helper0, main1], variablesByFrame: [0: [ptrHelper], 1: [ptrMain]])
        let mainPtrNode = try #require(panel.frameNodes[1].children.first)
        panel.outlineView.expandItem(mainPtrNode)
        await waitUntil("frame 1 pointer dereferences") { mainPtrNode.children.first?.rawValue != nil }
        #expect(derefCalls.last?.0 == "*p")
        #expect(derefCalls.last?.1 == 1)
        #expect(mainPtrNode.children.first?.rawValue == "42")

        // Next stop preserves expanded pointer state and renders "<unavailable>" when deref returns nil.
        returnNil = true
        panel.update(frames: [helper0, main1], variablesByFrame: [0: [ptrHelper], 1: [ptrMain]])
        let nextMainPtr = try #require(panel.frameNodes[1].children.first)
        #expect(panel.outlineView.isItemExpanded(nextMainPtr))
        await waitUntil("unavailable deref completes") { nextMainPtr.children.first?.rawValue != nil }
        #expect(nextMainPtr.children.first?.rawValue == "<unavailable>")
        let childRow = panel.outlineView.row(forItem: nextMainPtr.children.first)
        let valueCell = panel.outlineView.view(atColumn: 1, row: childRow, makeIfNecessary: true) as? NSTableCellView
        #expect(valueCell?.textField?.stringValue == "<unavailable>")
    }

    @Test func callStackLocalsIgnoresStaleDereferenceAfterUpdate() async throws {
        let panel = CallStackLocalsViewController()
        let main0 = try makeFrame(level: 0, address: 0x200, function: "main", line: 10)
        let ptrVar = try makeVariable(name: "p", type: "int *", value: "0x20000004")
        var continuation: CheckedContinuation<String?, Never>?
        panel.onDereference = { _ in
            await withCheckedContinuation { continuation = $0 }
        }

        panel.update(frames: [main0], variablesByFrame: [0: [ptrVar]])
        let oldPtr = try #require(panel.frameNodes.first?.children.first)
        let oldChild = try #require(oldPtr.children.first)
        panel.outlineView.expandItem(oldPtr)
        await waitUntil("dereference started") { continuation != nil }

        // A new stop replaces frameNodes before the old dereference finishes.
        panel.onDereference = nil
        panel.update(frames: [main0], variablesByFrame: [0: [ptrVar]], dereferencedValues: ["0:*p": "99"])
        continuation?.resume(returning: "123")
        await Task.yield()

        // The stale child was not mutated and the new child kept its fresh value.
        #expect(oldChild.rawValue == nil)
        #expect(panel.frameNodes.first?.children.first?.children.first?.rawValue == "99")
    }

    // MARK: - Regression tests: Registers

    @Test func registersPanelPreservesExpansionHighlightsFlagsAndShowsFPUGroupBeforeInternal() throws {
        let panel = RegistersViewController()
        let stop1 = [
            RegisterValue(name: "r0", value: 0),
            RegisterValue(name: "xpsr", value: 0x6100_0000), // Z=1, C=1, T=1, ISR=0
            RegisterValue(name: "control", value: 0),
            RegisterValue(name: "fpscr", value: 0x0000_0000),
            RegisterValue(name: "s0", value: 0x3F80_0000),
            RegisterValue(name: "d0", value: 0x3FF0_0000_0000_0000)
        ]
        panel.update(with: stop1)
        #expect(panel.nodes.map(\.key) == ["r0", "xpsr", "control", "fpu", "internal"])
        #expect(panel.nodes.last?.name == "Internal")

        let xpsr1 = try #require(panel.nodes.first { $0.key == "xpsr" })
        let fpu1 = try #require(panel.nodes.first { $0.key == "fpu" })
        let internal1 = try #require(panel.nodes.last)
        #expect(!panel.outlineView.isItemExpanded(xpsr1))
        #expect(!panel.outlineView.isItemExpanded(fpu1))
        #expect(panel.outlineView.isItemExpanded(internal1))
        #expect(fpu1.children.map(\.name) == ["FPSCR", "S0", "D0"])
        #expect(fpu1.children.last?.value == "0x3FF0000000000000")

        // Expand xPSR and FPU; next stop must keep them expanded and highlight changed children.
        panel.outlineView.expandItem(xpsr1)
        panel.outlineView.expandItem(fpu1)

        let stop2 = [
            RegisterValue(name: "r0", value: 0),
            RegisterValue(name: "xpsr", value: 0x8100_0010), // N=1, Z=0, C=0, T=1, ISR=16 (Handler)
            RegisterValue(name: "control", value: 0),
            RegisterValue(name: "fpscr", value: 0x0000_0000),
            RegisterValue(name: "s0", value: 0x4000_0000),
            RegisterValue(name: "d0", value: 0x3FF0_0000_0000_0000)
        ]
        panel.update(with: stop2)
        let xpsr2 = try #require(panel.nodes.first { $0.key == "xpsr" })
        let fpu2 = try #require(panel.nodes.first { $0.key == "fpu" })
        let internal2 = try #require(panel.nodes.last)
        #expect(panel.outlineView.isItemExpanded(xpsr2))
        #expect(panel.outlineView.isItemExpanded(fpu2))
        #expect(panel.outlineView.isItemExpanded(internal2))

        let xpsrChanged = Set(xpsr2.children.filter(\.isChanged).map(\.name))
        #expect(xpsrChanged == ["N", "Z", "C", "ISR"])
        let internalChanged = Set(internal2.children.filter(\.isChanged).map(\.name))
        #expect(internalChanged == ["Mode"])
        let fpuChanged = Set(fpu2.children.filter(\.isChanged).map(\.name))
        #expect(fpuChanged == ["S0"])
    }

    // MARK: - Regression tests: Watch and Command

    @Test func watchPanelClearValuesAndEvaluatedSubsetAvoidFalseUnavailableAndChanges() {
        let watch = WatchViewController()
        watch.addExpression("a")
        watch.updateValues(["a": "1"], evaluated: ["a"])
        #expect(watch.entries == [WatchViewController.Entry(expression: "a", value: "1", isChanged: false)])

        // Adding "b" while a refresh for ["a"] finishes must not mark "b" unavailable.
        watch.addExpression("b")
        watch.updateValues(["a": "2"], evaluated: ["a"])
        #expect(watch.entries == [
            WatchViewController.Entry(expression: "a", value: "2", isChanged: true),
            WatchViewController.Entry(expression: "b", value: "—", isChanged: false)
        ])

        // When "b" is evaluated for the first time, it must not be marked changed.
        watch.updateValues(["a": "2", "b": "10"], evaluated: ["a", "b"])
        #expect(watch.entries == [
            WatchViewController.Entry(expression: "a", value: "2", isChanged: false),
            WatchViewController.Entry(expression: "b", value: "10", isChanged: false)
        ])

        // clearValues resets displayed values and history while preserving expressions.
        watch.clearValues()
        #expect(watch.expressions == ["a", "b"])
        #expect(watch.entries == [
            WatchViewController.Entry(expression: "a", value: "—", isChanged: false),
            WatchViewController.Entry(expression: "b", value: "—", isChanged: false)
        ])
        watch.updateValues(["a": "99", "b": "100"], evaluated: ["a", "b"])
        #expect(watch.entries.allSatisfy { !$0.isChanged })
    }

    @Test func commandViewAppendsStyledTextAndCapsBufferLength() throws {
        let command = CommandViewController()
        command.maxLength = 64
        command.appendOutput(String(repeating: "A", count: 50))
        command.appendOutput(String(repeating: "B", count: 30))

        #expect((command.textView.string as NSString).length == 64)
        #expect(command.textView.string == String(repeating: "A", count: 34) + String(repeating: "B", count: 30))
        let storage = try #require(command.textView.textStorage)
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font == EditorTheme.font)
    }

    // MARK: - Regression tests: DebugPanelsController

    @Test func panelsRefreshContinuesWhenStackFramesAreEmptyAndClearsWatchValues() async throws {
        let mainC = URL(filePath: "/tmp/empty_frames_main.c")
        let gdb = FakeDebugger { command in
            if command == "-stack-list-frames" {
                return ["^done,stack=[]"]
            }
            if command == "-data-list-register-names" {
                return ["^done,register-names=[\"r0\",\"pc\"]"]
            }
            if command == "-data-list-register-values x" {
                return ["^done,register-values=[{number=\"0\",value=\"0x0000002a\"},"
                    + "{number=\"1\",value=\"0x0000020a\"}]"]
            }
            if command.hasPrefix("-data-disassemble") {
                return ["^done,asm_insns=[{address=\"0x0000020a\",func-name=\"main\",offset=\"0\","
                    + "opcodes=\"00 20\",inst=\"movs\\tr0, #0\"}]"]
            }
            if command.hasPrefix("-data-evaluate-expression") {
                return ["^done,value=\"42\""]
            }
            if command.hasPrefix("-data-read-memory-bytes") {
                return ["^done,memory=[{begin=\"0x20000000\",offset=\"0x00000000\",end=\"0x20000004\","
                    + "contents=\"2a000000\"}]"]
            }
            return ["^done"]
        }
        let debugger = DebugController()
        debugger.connect = { _ in gdb }
        try await debugger.start(FakeBlinky.plan)
        gdb.print(FakeBlinky.stop(atLine: 1, of: mainC, reason: "breakpoint-hit"))
        await waitUntil("stopped at main") { debugger.isStopped }

        let panels = DebugPanelsController()
        panels.watch.addExpression("x")
        panels.memory.showMemory(at: 0x2000_0000, bytes: [0, 0, 0, 0])
        let stopFrame = try makeFrame(level: 0, address: 0x20A, function: "main", file: mainC, line: 1)

        await panels.refresh(using: debugger, at: stopFrame, sourceText: "int x = 42;\n", sourceFile: mainC)

        #expect(panels.callStackLocals.frameNodes.map(\.name) == ["main"])
        #expect(panels.registers.nodes.first { $0.key == "r0" }?.value == "0x0000002A")
        #expect(panels.disassembly.rows.count == 1)
        #expect(panels.watch.entries.first?.value == "42")
        #expect(panels.memory.rows.first?.bytes == [0x2A, 0x00, 0x00, 0x00])

        panels.clear()
        #expect(panels.watch.expressions == ["x"])
        #expect(panels.watch.entries.first?.value == "—")
        #expect(panels.memory.addressField.stringValue.isEmpty)
    }

    @Test func inspectMemoryParsesCastPrefixedPointersAndReportsFailure() async throws {
        let mainC = URL(filePath: "/tmp/inspect_mem_main.c")
        let gdb = FakeDebugger { command in
            if command.contains("\"&arr\"") {
                return ["^done,value=\"(int (*)[4]) 0X20000258\""]
            }
            if command.contains("\"missing_sym\"") {
                return ["^error,msg=\"No symbol \\\"missing_sym\\\" in current context.\""]
            }
            if command.hasPrefix("-data-read-memory-bytes 0x20000258") {
                return ["^done,memory=[{begin=\"0x20000258\",offset=\"0x00000000\",end=\"0x2000025c\","
                    + "contents=\"9dffffff\"}]"]
            }
            if command.hasPrefix("-data-read-memory-bytes") {
                return ["^error,msg=\"Cannot access memory\""]
            }
            return ["^done"]
        }
        let debugger = DebugController()
        debugger.connect = { _ in gdb }
        try await debugger.start(FakeBlinky.plan)
        gdb.print(FakeBlinky.stop(atLine: 1, of: mainC, reason: "breakpoint-hit"))
        await waitUntil("stopped") { debugger.isStopped }

        let panels = DebugPanelsController()
        await panels.inspectMemory(query: "&arr", using: debugger)
        #expect(panels.memory.currentAddress == 0x2000_0258)
        #expect(panels.memory.rows.first?.bytes == [0x9D, 0xFF, 0xFF, 0xFF])
        #expect(panels.memory.statusMessage.isEmpty)

        // Unresolvable expression clears stale rows and reports failure.
        await panels.inspectMemory(query: "missing_sym", using: debugger)
        #expect(panels.memory.currentAddress == nil)
        #expect(panels.memory.rows.isEmpty)
        #expect(panels.memory.statusMessage.contains("missing_sym"))
    }

    @Test func postAwaitCancellationPreventsUpdatingWatchesAndMemoryAfterResume() async throws {
        let mainC = URL(filePath: "/tmp/cancel_guard_main.c")
        let gdb = FakeDebugger { command in
            if command.hasPrefix("-exec-continue") {
                return ["^running", "*running,thread-id=\"all\""]
            }
            if command.hasPrefix("-data-evaluate-expression") {
                return ["^done,value=\"123\""]
            }
            if command.hasPrefix("-data-read-memory-bytes") {
                return ["^done,memory=[{begin=\"0x20000000\",offset=\"0x00000000\",end=\"0x20000004\","
                    + "contents=\"deadbeef\"}]"]
            }
            return ["^done"]
        }
        let debugger = DebugController()
        debugger.connect = { _ in gdb }
        try await debugger.start(FakeBlinky.plan)
        gdb.print(FakeBlinky.stop(atLine: 1, of: mainC, reason: "breakpoint-hit"))
        await waitUntil("stopped") { debugger.isStopped }

        let panels = DebugPanelsController()
        panels.watch.addExpression("count")
        panels.memory.showMemory(at: 0x2000_0000, bytes: [0x01, 0x02, 0x03, 0x04])

        // Cancelled task must not update watch values or memory rows.
        let cancelledWatchTask = Task {
            await panels.refreshWatches(using: debugger)
        }
        cancelledWatchTask.cancel()
        await cancelledWatchTask.value
        #expect(panels.watch.entries.first?.value == "—")

        let cancelledMemTask = Task {
            await panels.refreshMemory(using: debugger)
        }
        cancelledMemTask.cancel()
        await cancelledMemTask.value
        #expect(panels.memory.rows.first?.bytes == [0x01, 0x02, 0x03, 0x04])
    }

    // MARK: - Unified pane tab bar

    private func containsSubview<T: NSView>(ofType _: T.Type, in view: NSView) -> Bool {
        if view is T { return true }
        return view.subviews.contains { containsSubview(ofType: T.self, in: $0) }
    }

    @Test func auxiliaryTabsPinsUnifiedTabBarFlushToTopLeadingEdge() throws {
        let panels = DebugPanelsController()
        let tabs = panels.auxiliaryTabs
        tabs.view.frame = NSRect(x: 0, y: 0, width: 380, height: 260)
        tabs.view.layoutSubtreeIfNeeded()

        #expect(!containsSubview(ofType: NSTabView.self, in: tabs.view))
        #expect(!containsSubview(ofType: NSSegmentedControl.self, in: tabs.view))
        #expect(tabs.tabBar.items.map(\.title) == ["Watch 1", "Memory 1", "Peripherals"])
        #expect(tabs.tabBar.items.map(\.isSelected) == [true, false, false])

        let barFrame = tabs.tabBar.convert(tabs.tabBar.bounds, to: tabs.view)
        #expect(barFrame.height == EditorTabBar.height)
        #expect(barFrame.minX == 0)
        #expect(barFrame.width == 380)
        #expect(barFrame.maxY == tabs.view.bounds.maxY)

        // Tabs stay left-aligned at x = 0 instead of floating centered in the column.
        let firstTab = try #require(tabs.tabBar.tabView(at: 0))
        let firstTabFrame = firstTab.convert(firstTab.bounds, to: tabs.tabBar)
        #expect(firstTabFrame.minX == 0)
        #expect(tabs.tabBar.accessibilityRole() == .tabGroup)
        #expect(firstTab.accessibilityRole() == .radioButton)
        #expect(firstTab.accessibilityValue() as? Bool == true)
    }

    @Test func auxiliaryTabsSwitchesContentViaClickAndIndexAndFillsBelowTabBar() throws {
        let panels = DebugPanelsController()
        let tabs = panels.auxiliaryTabs
        tabs.view.frame = NSRect(x: 0, y: 0, width: 380, height: 260)
        tabs.view.layoutSubtreeIfNeeded()

        let memoryTab = try #require(tabs.tabBar.tabView(at: 1))
        #expect(memoryTab.accessibilityPerformPress())
        tabs.view.layoutSubtreeIfNeeded()
        #expect(tabs.selectedTabViewItemIndex == 1)
        #expect(panels.memory.view.isDescendant(of: tabs.view))

        tabs.selectedTabViewItemIndex = 2
        tabs.view.layoutSubtreeIfNeeded()
        #expect(tabs.selectedTabViewItemIndex == 2)
        #expect(tabs.tabBar.items.map(\.isSelected) == [false, false, true])
        #expect(panels.peripherals.view.isDescendant(of: tabs.view))

        let barFrame = tabs.tabBar.convert(tabs.tabBar.bounds, to: tabs.view)
        let contentFrame = panels.peripherals.view.convert(panels.peripherals.view.bounds, to: tabs.view)
        #expect(contentFrame.minX == 0)
        #expect(contentFrame.width == 380)
        #expect(contentFrame.minY == 0)
        #expect(contentFrame.maxY == barFrame.minY)

        // Out-of-bounds indices are ignored safely.
        tabs.selectedTabViewItemIndex = 99
        #expect(tabs.selectedTabViewItemIndex == 2)
    }

    @Test func bottomAndAuxiliaryPanelsShareUnifiedTabBarHeightInMainWindow() throws {
        let controller = MainWindowController(boardMonitor: FakeBoardMonitor())
        let mainSplit = try #require(controller.window?.contentViewController as? NSSplitViewController)
        controller.showIssuesPanel()
        controller.debugPanels.setLayoutVisible(true, mainSplit: mainSplit, editorSplit: controller.editorSplit)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(controller.bottomPanel.tabBar.bounds.height == EditorTabBar.height)
        #expect(controller.debugPanels.auxiliaryTabs.tabBar.bounds.height == EditorTabBar.height)
    }
}
