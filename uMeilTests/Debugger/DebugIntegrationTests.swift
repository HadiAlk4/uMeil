import AppKit
import Foundation
import os
import Testing
@testable import uMeil

/// A minimal `DebuggerConnection` that counts synchronous `terminate()` calls
/// without closing on `-gdb-exit`.
private final class HangingConnection: DebuggerConnection {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: (commands: [String](), terminates: 0))

    init() {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
    }

    var commands: [String] { state.withLock { $0.commands } }
    var terminateCount: Int { state.withLock { $0.terminates } }

    func send(_ line: String) {
        let token = String(line.prefix { $0.isNumber })
        let command = String(line.dropFirst(token.count))
        state.withLock { $0.commands.append(command) }
        if command != "-gdb-exit" {
            continuation.yield("\(token)^done")
        }
    }

    func terminate() {
        state.withLock { $0.terminates += 1 }
        continuation.finish()
    }
}

/// Cross-module integration tests covering the wired hooks between
/// `MainWindowController`, `DebugPanelsController`, `DebugController`, and `GDBSession`.
@MainActor
struct DebugIntegrationTests {
    private func makeStartedWindow(
        in folder: URL,
        opening file: URL,
        gdb: FakeDebugger
    ) async throws -> MainWindowController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        controller.openFolder(folder)
        controller.openFile(file)
        controller.debugger.connect = { _ in gdb }
        try await controller.debugger.start(FakeBlinky.plan)
        return controller
    }

    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    private func stopRecord(addr: String, function: String, path: String, line: Int, thread: String = "1") -> String {
        #"*stopped,reason="breakpoint-hit",frame={addr="\#(addr)",func="\#(function)","#
            + #"fullname="\#(path)",line="\#(line)"},thread-id="\#(thread)""#
    }

    @Test func startDetectsBoardNotConnectedViaSessionLogWithoutPreDrainYields() async {
        for _ in 0..<5 {
            let gdb = FakeDebugger { command in
                if command.hasPrefix("-target-select") {
                    return [
                        "* WARNING: ST-LINK/ICDI notice",
                        "Error: open failed",
                        #"^error,msg="Remote connection closed""#
                    ]
                }
                return ["^done"]
            }
            let controller = DebugController()
            controller.connect = { _ in gdb }

            await #expect(throws: FlashFailure.boardNotConnected) {
                try await controller.start(FakeBlinky.plan)
            }
            #expect(controller.state == .idle)
            #expect(controller.session == nil)
            #expect(controller.chip == nil)
        }
    }

    @Test func terminateImmediatelyTerminatesConnectionSynchronously() async throws {
        let connection = HangingConnection()
        let controller = DebugController()
        controller.connect = { _ in connection }

        try await controller.start(FakeBlinky.plan)
        #expect(controller.isActive)

        // Must call `connection.terminate()` synchronously before any await.
        controller.terminateImmediately()
        #expect(connection.terminateCount == 1)
        #expect(controller.state == .idle)
        #expect(controller.session == nil)
        #expect(controller.chip == nil)
    }

    @Test func nonZeroFramePointerDereferenceSendsThreadAndFrameToGDB() async throws {
        let folder = try TemporaryFolder()
        let mainC = folder.url.appending(path: "main.c")
        try "int main(void) {\n    int x = -99;\n    int *p = &x;\n    return *p;\n}\n"
            .write(to: mainC, atomically: true, encoding: .utf8)
        let mainPath = canonicalPath(mainC)

        let gdb = FakeDebugger { command in
            switch command {
            case "-stack-list-frames":
                return [
                    #"^done,stack=[frame={level="0",addr="0x00000220",func="helper","#
                        + #"fullname="\#(mainPath)",line="2"},"#
                        + #"frame={level="1",addr="0x0000020a",func="main","#
                        + #"fullname="\#(mainPath)",line="4"}]"#
                ]
            case "-data-list-register-names": return [#"^done,register-names=["pc"]"#]
            case "-data-list-register-values x": return [#"^done,register-values=[{number="0",value="0x00000220"}]"#]
            case #"-data-evaluate-expression --thread 3 --frame 1 "*p""#: return [#"^done,value="-99""#]
            case _ where command.hasPrefix("-stack-list-variables") && command.contains("--frame 1"):
                return [#"^done,variables=[{name="p",type="int *",value="0x20000258"}]"#]
            case _ where command.hasPrefix("-stack-list-variables"): return ["^done,variables=[]"]
            case _ where command.hasPrefix("-data-disassemble"): return ["^done,asm_insns=[]"]
            default: return ["^done"]
            }
        }

        let controller = try await makeStartedWindow(in: folder.url, opening: mainC, gdb: gdb)
        defer { controller.debugger.terminateImmediately() }

        gdb.print(stopRecord(addr: "0x00000220", function: "helper", path: mainPath, line: 2, thread: "3"))
        let locals = controller.debugPanels.callStackLocals
        await waitUntil("call stack populated with both frames") {
            locals.frameNodes.count == 2 && locals.frameNodes[1].children.first?.name == "p"
        }

        let pointerNode = try #require(locals.frameNodes[1].children.first)
        locals.outlineView.expandItem(pointerNode)
        await waitUntil("frame 1 pointer dereferenced") { pointerNode.children.first?.rawValue == "-99" }
        #expect(gdb.commands.contains(#"-data-evaluate-expression --thread 3 --frame 1 "*p""#))
    }

    @Test func selectingFrameSendsStackSelectFrameAndUpdatesEditorAndDisassembly() async throws {
        let folder = try TemporaryFolder()
        let helperC = folder.url.appending(path: "helper.c")
        let mainC = folder.url.appending(path: "main.c")
        try "void helper(void) {\n    __asm(\"nop\");\n}\n".write(to: helperC, atomically: true, encoding: .utf8)
        try "void helper(void);\nint main(void) {\n    helper();\n    return 0;\n}\n"
            .write(to: mainC, atomically: true, encoding: .utf8)
        let (helperPath, mainPath) = (canonicalPath(helperC), canonicalPath(mainC))

        let gdb = FakeDebugger { command in
            switch command {
            case "-stack-list-frames":
                return [
                    #"^done,stack=[frame={level="0",addr="0x00000220",func="helper","#
                        + #"fullname="\#(helperPath)",line="2"},"#
                        + #"frame={level="1",addr="0x0000020a",func="main","#
                        + #"fullname="\#(mainPath)",line="3"}]"#
                ]
            case "-data-list-register-names": return [#"^done,register-names=["pc"]"#]
            case "-data-list-register-values x": return [#"^done,register-values=[{number="0",value="0x00000220"}]"#]
            case _ where command.hasPrefix("-stack-list-variables"): return ["^done,variables=[]"]
            case _ where command.hasPrefix("-data-disassemble -s 0x20a"):
                return [
                    #"^done,asm_insns=[src_and_asm_line={line="3",file="main.c",fullname="\#(mainPath)","#
                        + #"line_asm_insn=[{address="0x0000020a",func-name="main",offset="4","#
                        + #"opcodes="00 f0 09 f8",inst="bl 0x220"}]}]"#
                ]
            case _ where command.hasPrefix("-data-disassemble"): return ["^done,asm_insns=[]"]
            default: return ["^done"]
            }
        }

        let controller = try await makeStartedWindow(in: folder.url, opening: helperC, gdb: gdb)
        defer { controller.debugger.terminateImmediately() }

        gdb.print(stopRecord(addr: "0x00000220", function: "helper", path: helperPath, line: 2))
        let locals = controller.debugPanels.callStackLocals
        await waitUntil("frames loaded") { locals.frameNodes.count == 2 }
        #expect(controller.editor.document?.url.lastPathComponent == "helper.c" && controller.editor.executionLine == 2)

        let callerRow = locals.outlineView.row(forItem: locals.frameNodes[1])
        #expect(callerRow >= 0)
        locals.outlineView.selectRowIndexes(IndexSet(integer: callerRow), byExtendingSelection: false)
        await waitUntil("frame 1 selected and disassembly updated") {
            gdb.commands.contains("-stack-select-frame 1")
                && controller.debugPanels.disassembly.programCounter == 0x20a
        }
        #expect(controller.editor.document?.url.lastPathComponent == "main.c" && controller.editor.executionLine == 3)
        #expect(controller.debugPanels.disassembly.rows.contains {
            if case .source(let line, let text) = $0 { line == 3 && text.contains("helper();") } else { false }
        })
    }

    @Test func mode5DisassemblyInterleavesSourceLinesOnlyWhenFileMatchesOpenEditor() async throws {
        let folder = try TemporaryFolder()
        let mainC = folder.url.appending(path: "main.c")
        let otherC = folder.url.appending(path: "other.c")
        try "int main(void) {\n    int marker = 1;\n    return marker;\n}\n"
            .write(to: mainC, atomically: true, encoding: .utf8)
        try "void other(void) {\n    int unrelated = 2;\n}\n".write(to: otherC, atomically: true, encoding: .utf8)
        let (mainPath, otherPath) = (canonicalPath(mainC), canonicalPath(otherC))

        let gdb = FakeDebugger { command in
            switch command {
            case "-stack-list-frames":
                return [
                    #"^done,stack=[frame={level="0",addr="0x0000020a",func="main","#
                        + #"fullname="\#(mainPath)",line="2"}]"#
                ]
            case "-data-list-register-names": return [#"^done,register-names=["pc"]"#]
            case "-data-list-register-values x": return [#"^done,register-values=[{number="0",value="0x0000020a"}]"#]
            case _ where command.hasPrefix("-stack-list-variables"): return ["^done,variables=[]"]
            case _ where command.hasPrefix("-data-disassemble"):
                return [
                    #"^done,asm_insns=["#
                        + #"src_and_asm_line={line="2",file="main.c",fullname="\#(mainPath)","#
                        + #"line_asm_insn=[{address="0x0000020a",opcodes="01 20",inst="movs r0, #1"}]},"#
                        + #"src_and_asm_line={line="2",file="other.c",fullname="\#(otherPath)","#
                        + #"line_asm_insn=[{address="0x0000020c",opcodes="02 20",inst="movs r0, #2"}]},"#
                        + #"src_and_asm_line={line="0",file="startup.s","#
                        + #"line_asm_insn=[{address="0x0000020e",opcodes="00 bf",inst="nop"}]}]"#
                ]
            default: return ["^done"]
            }
        }

        let controller = try await makeStartedWindow(in: folder.url, opening: mainC, gdb: gdb)
        defer { controller.debugger.terminateImmediately() }

        gdb.print(stopRecord(addr: "0x0000020a", function: "main", path: mainPath, line: 2))
        await waitUntil("mode-5 disassembly loaded") { controller.debugPanels.disassembly.rows.count == 4 }

        let disasmCmd = try #require(gdb.commands.first { $0.hasPrefix("-data-disassemble") })
        #expect(disasmCmd.hasSuffix("-- 5"))
        let sourceRows = controller.debugPanels.disassembly.rows.compactMap { row -> (Int, String)? in
            if case .source(let line, let text) = row { (line, text) } else { nil }
        }
        #expect(sourceRows.count == 1)
        #expect(sourceRows.first?.0 == 2 && sourceRows.first?.1.contains("int marker = 1;") == true)
    }
}
