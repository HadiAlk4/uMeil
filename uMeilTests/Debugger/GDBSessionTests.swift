import Foundation
import os
import Testing
@testable import uMeil

/// Stands in for GDB: answers each command with saved lines.
final class FakeDebugger: DebuggerConnection {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let sentCommands = OSAllocatedUnfairLock(initialState: [String]())
    private let terminatedFlag = OSAllocatedUnfairLock(initialState: false)
    private let answer: @Sendable (String) -> [String]

    /// `answer` is given a command without its token and returns the lines
    /// GDB would print. A line starting with `^` gets the token put back.
    init(answer: @escaping @Sendable (String) -> [String] = { _ in ["^done"] }) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.answer = answer
    }

    /// Every command sent so far, without tokens.
    var commands: [String] { sentCommands.withLock { $0 } }
    var wasTerminated: Bool { terminatedFlag.withLock { $0 } }

    func send(_ line: String) {
        let token = String(line.prefix { $0.isNumber })
        let command = String(line.dropFirst(token.count))
        sentCommands.withLock { $0.append(command) }
        if command == "-gdb-exit" {
            continuation.yield(token + "^exit")
            continuation.finish()
            return
        }
        for line in answer(command) {
            continuation.yield(line.hasPrefix("^") ? token + line : line)
        }
    }

    /// Prints a line nobody asked for, as GDB does for events.
    func print(_ line: String) {
        continuation.yield(line)
    }

    func terminate() {
        terminatedFlag.withLock { $0 = true }
        continuation.finish()
    }
}

struct GDBSessionTests {
    private let mainC = URL(filePath: "/tmp/Blinky/src/main.c")

    /// The session's next event, or a failure if the session is over.
    private func nextEvent(_ events: inout AsyncStream<DebugEvent>.Iterator) async throws -> DebugEvent {
        try #require(await events.next())
    }

    // MARK: - Commands and answers

    @Test func aCommandReturnsTheAnswerWithItsToken() async throws {
        let gdb = FakeDebugger { command in
            command.contains("sizeof") ? ["^done,value=\"4\""] : ["^done,value=\"other\""]
        }
        let session = GDBSession(connection: gdb)

        async let other = session.evaluate("1 + 1")
        async let size = session.evaluate("sizeof(int)")

        #expect(try await size == "4")
        #expect(try await other == "other")
        #expect(gdb.commands.contains("-data-evaluate-expression \"sizeof(int)\""))
    }

    @Test func anErrorAnswerIsThrownWithGDBsMessage() async throws {
        let refusal = try BlinkySession.line(startingWith: "^error,msg=\"No symbol")
        let session = GDBSession(connection: FakeDebugger { _ in [refusal] })

        await #expect(throws: DebugError.refused("No symbol \"nosuchvar\" in current context.")) {
            try await session.evaluate("nosuchvar")
        }
    }

    @Test func commandsStillWaitingFailWhenGDBQuits() async throws {
        let gdb = FakeDebugger { _ in [] }
        let session = GDBSession(connection: gdb)

        let answer = Task { try await session.send("-exec-continue") }
        while gdb.commands.isEmpty { await Task.yield() }
        gdb.terminate()

        await #expect(throws: DebugError.sessionEnded) { try await answer.value }
        await #expect(throws: DebugError.sessionEnded) { try await session.send("-exec-next") }
    }

    @Test func endingTheSessionAsksGDBToQuit() async throws {
        let gdb = FakeDebugger()
        let session = GDBSession(connection: gdb)

        await session.end()

        #expect(gdb.commands == ["-gdb-exit"])
        var events = session.events.makeAsyncIterator()
        #expect(try await nextEvent(&events) == .ended)
        #expect(await events.next() == nil)
    }

    // MARK: - Events

    @Test func runningAndStoppingArriveAsEvents() async throws {
        let gdb = FakeDebugger()
        let session = GDBSession(connection: gdb)
        var events = session.events.makeAsyncIterator()

        gdb.print("*running,thread-id=\"all\"")
        gdb.print(try BlinkySession.line(startingWith: "*stopped,reason=\"breakpoint-hit\",disp=\"keep\""))

        #expect(try await nextEvent(&events) == .running)
        guard case .stopped(let stop) = try await nextEvent(&events) else {
            Issue.record("Expected a stop")
            return
        }
        #expect(stop.reason == .breakpoint(number: "2"))
        #expect(stop.frame?.function == "main")
        #expect(stop.frame?.file == mainC)
        #expect(stop.frame?.line == 28)
        #expect(stop.frame?.address == 0x222)
    }

    @Test func eachKindOfStopIsToldApart() throws {
        func reason(of prefix: String) throws -> StopReason {
            let record = try MIParser.parse(BlinkySession.line(startingWith: prefix))
            guard case .event(_, _, let values) = record else { return .other("not an event") }
            return StopEvent(values).reason
        }

        #expect(try reason(of: "*stopped,reason=\"end-stepping-range\"") == .stepFinished)
        #expect(try reason(of: "*stopped,reason=\"signal-received\"")
            == .signal(name: "SIGINT", meaning: "Interrupt"))
        // What GDB reports on connecting to a chip that was already running.
        #expect(try reason(of: "*stopped,frame=") == .other(""))
    }

    @Test func aPauseInCodeWithoutDebugInformationHasNoFileOrLine() throws {
        let record = try MIParser.parse(BlinkySession.line(startingWith: "*stopped,reason=\"signal-received\""))
        guard case .event(_, _, let values) = record else { return }
        let frame = try #require(StopEvent(values).frame)

        #expect(frame.function == "SysCtlDelay")
        #expect(frame.address == 0x472)
        #expect(frame.file == nil)
        #expect(frame.line == nil)
    }

    @Test func outputFromGDBAndOpenOCDArrivesAsText() async throws {
        let gdb = FakeDebugger()
        let session = GDBSession(connection: gdb)
        var events = session.events.makeAsyncIterator()

        gdb.print(try BlinkySession.line(startingWith: "@\"SRST"))
        gdb.print("Info : clock speed 1 kHz")
        gdb.print("=thread-created,id=\"1\",group-id=\"i1\"")
        gdb.print("(gdb) ")
        gdb.print("~\"done\\n\"")

        #expect(try await nextEvent(&events) == .output("SRST error\n"))
        #expect(try await nextEvent(&events) == .output("Info : clock speed 1 kHz\n"))
        #expect(try await nextEvent(&events) == .output("done\n"))
    }

    // MARK: - The debugger's actions

    @Test func startingConnectsLoadsAndRunsToMain() async throws {
        let gdb = FakeDebugger()
        let session = GDBSession(connection: gdb)
        let plan = DebugPlan(
            gdb: URL(filePath: "/tools/arm-none-eabi-gdb"),
            openOCD: URL(filePath: "/Application Support/it's/openocd"),
            image: URL(filePath: "/tmp/My \"Blinky\"/build/Blinky.elf"),
            chip: .tm4c1294ncpdt
        )

        try await session.start(plan)

        #expect(plan.gdbArguments == ["--interpreter=mi3", "-q", "-nx", "-iex", "set auto-load off"])
        #expect(gdb.commands == [
            "-gdb-set mi-async on",
            "-gdb-set confirm off",
            #"-file-exec-and-symbols "/tmp/My \"Blinky\"/build/Blinky.elf""#,
            #"-target-select extended-remote | '/Application Support/it'\''s/openocd'"#
                + " -c 'bindto localhost' -c 'gdb_port pipe' -c 'telnet_port disabled'"
                + " -c 'tcl_port disabled' -f 'board/ek-tm4c1294xl.cfg'",
            #"-interpreter-exec console "monitor reset halt""#,
            "-target-download",
            #"-interpreter-exec console "monitor reset halt""#,
            "-break-insert -t main",
            "-exec-continue"
        ])
    }

    @Test func startingStopsAtTheFirstCommandGDBRefuses() async throws {
        let gdb = FakeDebugger { command in
            command.hasPrefix("-target-select") ? ["^error,msg=\"Remote connection closed\""] : ["^done"]
        }
        let session = GDBSession(connection: gdb)
        let plan = DebugPlan(
            gdb: URL(filePath: "/gdb"),
            openOCD: URL(filePath: "/openocd"),
            image: URL(filePath: "/Blinky.elf"),
            chip: .tm4c1294ncpdt
        )

        await #expect(throws: DebugError.refused("Remote connection closed")) {
            try await session.start(plan)
        }
        #expect(gdb.commands.last?.hasPrefix("-target-select") == true)
    }

    @Test func eachRunActionSendsItsCommand() async throws {
        let gdb = FakeDebugger()
        let session = GDBSession(connection: gdb)

        try await session.resume()
        try await session.pause()
        try await session.stepOver()
        try await session.stepInto()
        try await session.stepOut()
        try await session.run(toLine: 31, of: URL(filePath: "/tmp/My Lab/main.c"))

        #expect(gdb.commands == [
            "-exec-continue",
            "-exec-interrupt",
            "-exec-next",
            "-exec-step",
            "-exec-finish",
            "-break-insert -t --source \"/tmp/My Lab/main.c\" --line 31",
            "-exec-continue"
        ])
    }

    @Test func aBreakpointReportsWhereGDBPutIt() async throws {
        let answer = try BlinkySession.line(startingWith: "^done,bkpt={number=\"2\"")
        let gdb = FakeDebugger { _ in [answer] }
        let session = GDBSession(connection: gdb)

        let breakpoint = try await session.insertBreakpoint(line: 28, of: mainC)
        try await session.deleteBreakpoint(breakpoint)

        #expect(breakpoint.number == "2")
        #expect(breakpoint.file == mainC)
        #expect(breakpoint.line == 28)
        #expect(breakpoint.address == 0x222)
        #expect(breakpoint.isEnabled)
        #expect(gdb.commands == ["-break-insert --source \"/tmp/Blinky/src/main.c\" --line 28", "-break-delete 2"])
    }

    @Test func theCallStackIsListedRunningFunctionFirst() async throws {
        let answer = try BlinkySession.line(startingWith: "^done,stack=[")
        let session = GDBSession(connection: FakeDebugger { _ in [answer] })

        let frames = try await session.frames()

        #expect(frames.map(\.level) == [0])
        #expect(frames.first?.function == "main")
        #expect(frames.first?.line == 21)
    }

    @Test func variablesAreListedWithTypeAndValue() async throws {
        // Blinky's main has no variables, so this answer follows the GDB manual.
        let answer = #"^done,variables=[{name="a",arg="1",type="int",value="5"},"#
            + #"{name="p",type="int *",value="0x20000258"},{name="table",type="int [4]"}]"#
        let gdb = FakeDebugger { _ in [answer] }
        let session = GDBSession(connection: gdb)

        let variables = try await session.variables(inFrame: 1)

        #expect(variables.map(\.name) == ["a", "p", "table"])
        #expect(variables.map(\.isArgument) == [true, false, false])
        #expect(variables.map(\.type) == ["int", "int *", "int [4]"])
        #expect(variables.map(\.value) == ["5", "0x20000258", nil])
        #expect(gdb.commands == ["-stack-list-variables --thread 1 --frame 1 --simple-values"])
    }

    @Test func registersAreNamedAndTheNamesAreOnlyAskedForOnce() async throws {
        let names = try BlinkySession.line(startingWith: "^done,register-names=")
        let values = try BlinkySession.line(startingWith: "^done,register-values=")
        let gdb = FakeDebugger { command in
            command == "-data-list-register-names" ? [names] : [values]
        }
        let session = GDBSession(connection: gdb)

        let registers = try await session.registers()
        _ = try await session.registers()

        #expect(registers.prefix(17).map(\.name) == [
            "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12",
            "sp", "lr", "pc", "xpsr"
        ])
        let byName = Dictionary(uniqueKeysWithValues: registers.map { ($0.name, $0.value) })
        #expect(byName["sp"] == 0x2003_fff0)
        #expect(byName["lr"] == 0x293)
        #expect(byName["pc"] == 0x20a)
        #expect(byName["xpsr"] == 0x6100_0000)
        #expect(["msp", "psp", "primask", "basepri", "faultmask", "control"].allSatisfy { byName[$0] != nil })
        #expect(gdb.commands.filter { $0 == "-data-list-register-names" }.count == 1)
    }

    @Test func memoryIsReadAsBytesInAddressOrder() async throws {
        let answer = try BlinkySession.line(startingWith: "^done,memory=")
        let gdb = FakeDebugger { _ in [answer] }
        let session = GDBSession(connection: gdb)

        let bytes = try await session.readMemory(at: 0x2000_0000, count: 16)

        #expect(bytes == [
            0x02, 0x46, 0x00, 0x20, 0xc0, 0x43, 0x0a, 0x4e, 0x0b, 0x46, 0x00, 0x24, 0x0d, 0xe0, 0x11, 0x5d
        ])
        #expect(gdb.commands == ["-data-read-memory-bytes 0x20000000 16"])
    }

    @Test func memoryIsWrittenAsHexBytesInAddressOrder() async throws {
        let gdb = FakeDebugger()
        let session = GDBSession(connection: gdb)

        // 0x00000002 stored little-endian at GPIO_PORTN_DATA: LED D1 on.
        try await session.writeMemory(at: 0x4006_43FC, bytes: [0x02, 0x00, 0x00, 0x00])
        try await session.writeMemory(at: 0x2000_0000, bytes: [])

        #expect(gdb.commands == ["-data-write-memory-bytes 0x400643fc 02000000"])
    }

    @Test func aRefusedMemoryReadThrowsGDBsReason() async throws {
        let gdb = FakeDebugger { _ in [#"^error,msg="Unable to read memory.""#] }
        let session = GDBSession(connection: gdb)

        await #expect(throws: DebugError.refused("Unable to read memory.")) {
            try await session.readMemory(at: 0x4006_4400, count: 4)
        }
    }

    @Test func resetReportsWhereTheChipStopped() async throws {
        let frame = try BlinkySession.line(startingWith: "^done,frame=")
        let gdb = FakeDebugger { command in
            command == "-stack-info-frame" ? [frame] : ["^done"]
        }
        let session = GDBSession(connection: gdb)

        let stopped = try await session.reset()

        #expect(stopped?.function == "SysCtlDelay")
        #expect(gdb.commands == [
            #"-interpreter-exec console "monitor reset halt""#,
            #"-interpreter-exec console "maintenance flush register-cache""#,
            "-stack-info-frame"
        ])
    }

    @Test func anAnswerWithoutTheExpectedFieldIsAnError() async throws {
        let session = GDBSession(connection: FakeDebugger())

        await #expect(throws: DebugError.unexpectedAnswer("-stack-list-frames")) {
            try await session.frames()
        }
    }
}

// swiftlint:disable file_length
extension GDBSessionTests {
    // MARK: - Regression tests

    @Test func cQuotedEscapesNewlinesCarriageReturnsTabsAndStripsControlCharacters() {
        #expect(DebugPlan.cQuoted("a\nb\rc\r\nd\te") == #""a\nb\rc\r\nd\te""#)
        #expect(DebugPlan.cQuoted("x\u{00}\u{1B}\u{7F}y") == #""xy""#)
        #expect(DebugPlan.cQuoted("line1\n-exec-continue") == #""line1\n-exec-continue""#)
        let quoted = DebugPlan.cQuoted("first\r\nsecond\nthird")
        #expect(!quoted.contains("\n"))
        #expect(!quoted.contains("\r"))
    }

    @Test func targetSelectPreservesConsecutiveSpacesAndQuotesViaShellQuoting() {
        let plan = DebugPlan(
            gdb: URL(filePath: "/tools/arm-none-eabi-gdb"),
            openOCD: URL(filePath: "/tmp/a  b/ \"quoted\"/it's/openocd"),
            image: URL(filePath: "/tmp/Blinky.elf"),
            chip: .tm4c1294ncpdt
        )
        let targetCommand = plan.connectCommands[3]
        #expect(targetCommand.hasPrefix("-target-select extended-remote | "))
        #expect(targetCommand.contains("'/tmp/a  b/ \"quoted\"/it'\\''s/openocd'"))
    }

    @Test func stopEventParsesThreadIdAndSessionUsesItForVariablesAndEvaluate() async throws {
        let varsAnswer = #"^done,variables=[{name="count",type="int",value="3"}]"#
        let gdb = FakeDebugger { command in
            if command.hasPrefix("-stack-list-variables") { return [varsAnswer] }
            if command.hasPrefix("-data-evaluate-expression") { return [#"^done,value="42""#] }
            return ["^done"]
        }
        let session = GDBSession(connection: gdb)
        var events = session.events.makeAsyncIterator()

        gdb.print(
            #"*stopped,reason="breakpoint-hit",bkptno="1","#
                + #"frame={addr="0x20a",func="worker"},thread-id="3""#
        )
        guard case .stopped(let stop) = try await nextEvent(&events) else {
            Issue.record("Expected stop event")
            return
        }
        #expect(stop.threadId == "3")
        #expect(await session.currentThreadId == "3")

        _ = try await session.variables(inFrame: 2)
        #expect(try await session.evaluate("*ptr", inFrame: 2) == "42")
        #expect(try await session.evaluate("sizeof(int)") == "42")
        try await session.selectFrame(2)

        #expect(gdb.commands == [
            "-stack-list-variables --thread 3 --frame 2 --simple-values",
            "-data-evaluate-expression --thread 3 --frame 2 \"*ptr\"",
            "-data-evaluate-expression \"sizeof(int)\"",
            "-stack-select-frame 2"
        ])
    }

    @Test func sessionLogUpdatesSynchronouslyAndIsBounded() async throws {
        let gdb = FakeDebugger { command in
            if command == "-target-select" {
                return [
                    "* WARNING: probe notice",
                    "Error: open failed",
                    #"~"detail\n""#,
                    #"^error,msg="Remote connection closed""#
                ]
            }
            return ["^done"]
        }
        let session = GDBSession(connection: gdb)

        await #expect(throws: DebugError.refused("Remote connection closed")) {
            try await session.send("-target-select")
        }
        // Log must already contain OpenOCD and stream output without draining `events`.
        let captured = await session.log
        #expect(captured.contains("* WARNING: probe notice\n"))
        #expect(captured.contains("Error: open failed\n"))
        #expect(captured.contains("detail\n"))

        // Exceeding 512 KB trims oldest bytes while preserving valid UTF-8 and latest text.
        let chunk = String(repeating: "é", count: 4096) // 8 KB UTF-8 per line
        for _ in 0..<80 {
            gdb.print(chunk)
        }
        gdb.print("TAIL-MARKER")
        _ = try await session.send("-gdb-version")

        let bounded = await session.log
        #expect(bounded.utf8.count <= GDBSession.maxLogBytes)
        #expect(bounded.hasSuffix("TAIL-MARKER\n"))
    }

    @Test func terminateImmediatelyCallsConnectionTerminateSynchronously() {
        let gdb = FakeDebugger()
        let session = GDBSession(connection: gdb)

        session.terminateImmediately()

        #expect(gdb.wasTerminated)
    }

    @Test func sessionDeallocatesWithoutARetainCycleWhenDropped() async {
        let gdb = FakeDebugger()
        weak var weakSession: GDBSession?
        do {
            let session = GDBSession(connection: gdb)
            weakSession = session
            _ = try? await session.send("-gdb-version")
        }
        for _ in 0..<50 where weakSession != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakSession == nil)
    }

    @Test func disassembleUsesMode5AndHandlesNearOverflowAddresses() async throws {
        let answer = #"^done,asm_insns=["#
            + #"src_and_asm_line={line="28",file="src/main.c",fullname="/tmp/Blinky/src/main.c","#
            + #"line_asm_insn=[{address="0x00000222",func-name="main",offset="26","#
            + #"opcodes="02 21",inst="movs\tr1, #2"}]},"#
            + #"src_and_asm_line={line="0",file="startup.s","#
            + #"line_asm_insn=[{address="0x00000224",opcodes="00 bf",inst="nop"}]}]"#
        let gdb = FakeDebugger { _ in [answer] }
        let session = GDBSession(connection: gdb)

        let instructions = try await session.disassemble(from: 0x222, count: 16)
        #expect(instructions.count == 2)
        #expect(instructions[0].file == mainC)
        #expect(instructions[0].line == 28)
        #expect(instructions[1].file == nil)
        #expect(instructions[1].line == nil)

        _ = try await session.disassemble(from: UInt64.max - 8, count: 64)
        #expect(gdb.commands == [
            "-data-disassemble -s 0x222 -e 0x232 -- 5",
            "-data-disassemble -s 0xfffffffffffffff7 -e 0xffffffffffffffff -- 5"
        ])
    }

    @Test func readMemoryHandlesZeroCountMultiBlockReadsAndGaps() async throws {
        let gdb = FakeDebugger { command in
            if command.contains("0x20000000") {
                return [
                    #"^done,memory=["#
                        + #"{begin="0x20000004",offset="0x00000004",end="0x20000008",contents="05060708"},"#
                        + #"{begin="0x20000000",offset="0x00000000",end="0x20000004",contents="01020304"}]"#
                ]
            }
            if command.contains("0x20000100") {
                // Unreadable gap between offset 4 and offset 8.
                return [
                    #"^done,memory=["#
                        + #"{begin="0x20000100",offset="0x00000000",end="0x20000104",contents="aabbccdd"},"#
                        + #"{begin="0x20000108",offset="0x00000008",end="0x2000010c",contents="11223344"}]"#
                ]
            }
            if command.contains("0x20000200") {
                // Missing bytes at offset 0.
                return [
                    #"^done,memory=[{begin="0x20000204",offset="0x00000004",end="0x20000208",contents="11223344"}]"#
                ]
            }
            return [#"^done,memory=[]"#]
        }
        let session = GDBSession(connection: gdb)

        #expect(try await session.readMemory(at: 0x2000_0000, count: 0) == [])
        #expect(try await session.readMemory(at: 0x2000_0000, count: -4) == [])
        #expect(gdb.commands.isEmpty)

        #expect(try await session.readMemory(at: 0x2000_0000, count: 8) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(try await session.readMemory(at: 0x2000_0100, count: 12) == [0xaa, 0xbb, 0xcc, 0xdd])
        await #expect(throws: DebugError.unexpectedAnswer("-data-read-memory-bytes 0x20000200 8")) {
            try await session.readMemory(at: 0x2000_0200, count: 8)
        }
        await #expect(throws: DebugError.unexpectedAnswer("-data-read-memory-bytes 0x20000300 4")) {
            try await session.readMemory(at: 0x2000_0300, count: 4)
        }
    }

    @Test func pipeLineReaderSkipsRetainingFullOutputWhenDisabled() async {
        let pipe = Pipe()
        let collectedLines = OSAllocatedUnfairLock(initialState: [String]())
        let finalOutput: String = await withCheckedContinuation { continuation in
            PipeLineReader.start(
                pipe.fileHandleForReading,
                collectAll: false,
                onLine: { line in collectedLines.withLock { $0.append(line) } },
                onEnd: { text in continuation.resume(returning: text) }
            )
            try? pipe.fileHandleForWriting.write(contentsOf: Data("first\nsecond\nlast".utf8))
            try? pipe.fileHandleForWriting.close()
        }

        #expect(collectedLines.withLock { $0 } == ["first", "second", "last"])
        #expect(finalOutput.isEmpty)
    }

    @Test func gdbProcessTerminatesOnDeinitAndFinishesStreamWhenChildOutlivesProcess() async throws {
        // 1. Deallocating GDBProcess stops its process and closes stdin.
        var process: GDBProcess? = try GDBProcess(URL(filePath: "/bin/cat"), arguments: [])
        let catLines = try #require(process?.lines)
        process = nil
        for await _ in catLines {}

        // 2. When a child process outlives the direct process (as OpenOCD can
        // outlive GDB), the termination fallback closes the pipe and ends `lines`.
        let holder = try GDBProcess(
            URL(filePath: "/bin/sh"),
            arguments: ["-c", "sleep 4 & echo ready"]
        )
        var received: [String] = []
        for await line in holder.lines {
            received.append(line)
        }
        #expect(received == ["ready"])
    }
}
