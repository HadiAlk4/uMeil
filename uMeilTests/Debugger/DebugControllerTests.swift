import Foundation
import Testing
@testable import uMeil

/// Lines GDB prints while debugging Blinky, for tests without a board.
enum FakeBlinky {
    /// A `FakeDebugger` that answers the way GDB does. A breakpoint asked
    /// for on a line in `movedLines` is put on the line it maps to, as GDB
    /// does for a line without code.
    static func debugger(movedLines: [Int: Int] = [:], refusing refused: String? = nil) -> FakeDebugger {
        FakeDebugger { command in
            if let refused, command.hasPrefix(refused) {
                return ["^error,msg=\"Remote connection closed\""]
            }
            if command.hasPrefix("-exec-") && command != "-exec-interrupt" {
                return ["^running", "*running,thread-id=\"all\""]
            }
            if command.hasPrefix("-break-insert --source") {
                let parts = command.split(separator: "\"")
                let file = String(parts[1])
                let asked = Int(command.split(separator: " ").last ?? "") ?? 0
                let line = movedLines[asked] ?? asked
                return ["^done,bkpt={number=\"\(asked)\",enabled=\"y\",addr=\"0x00000222\",func=\"main\","
                    + "fullname=\"\(file)\",line=\"\(line)\"}"]
            }
            if command.hasPrefix("-symbol-list-lines") {
                return ["^done,lines=[{pc=\"0x0000020a\",line=\"21\"},{pc=\"0x00000222\",line=\"28\"},"
                    + "{pc=\"0x00000236\",line=\"31\"},{pc=\"0x00000000\",line=\"0\"}]"]
            }
            if command == "-stack-info-frame" {
                return ["^done,frame={level=\"0\",addr=\"0x00000258\",func=\"Reset_Handler\"}"]
            }
            return ["^done"]
        }
    }

    /// GDB's report that the program stopped on `line` of `file`.
    static func stop(atLine line: Int, of file: URL, reason: String = "end-stepping-range") -> String {
        "*stopped,reason=\"\(reason)\",frame={addr=\"0x0000020a\",func=\"main\",args=[],"
            + "fullname=\"\(file.path(percentEncoded: false))\",line=\"\(line)\"},thread-id=\"1\""
    }

    /// What GDB reports on connecting, before the program is loaded.
    static let stopOnConnecting = "*stopped,frame={addr=\"0x00000472\",func=\"SysCtlDelay\",args=[]},thread-id=\"1\""

    /// A pause in library code, which has no source to show.
    static let stopInLibrary = "*stopped,reason=\"signal-received\",signal-name=\"SIGINT\","
        + "signal-meaning=\"Interrupt\",frame={addr=\"0x00000472\",func=\"SysCtlDelay\",args=[]},thread-id=\"1\""

    static let plan = DebugPlan(
        gdb: URL(filePath: "/tools/arm-none-eabi-gdb"),
        openOCD: URL(filePath: "/tools/openocd"),
        image: URL(filePath: "/tmp/Blinky/build/Blinky.elf"),
        chip: .tm4c1294ncpdt
    )
}

/// Waits for something that happens a moment later, on the main actor.
@MainActor
func waitUntil(
    _ what: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition(), "Timed out waiting until \(what)", sourceLocation: sourceLocation)
}

@MainActor
struct DebugControllerTests {
    let mainC = URL(filePath: "/tmp/Blinky/src/main.c")

    func makeController(_ gdb: any DebuggerConnection) -> DebugController {
        let controller = DebugController()
        controller.connect = { _ in gdb }
        return controller
    }

    /// A session that has started and stopped at `main`.
    func startedAtMain(_ gdb: FakeDebugger) async throws -> DebugController {
        let controller = makeController(gdb)
        try await controller.start(FakeBlinky.plan)
        gdb.print(FakeBlinky.stop(atLine: 21, of: mainC, reason: "breakpoint-hit"))
        await waitUntil("the program stops at main") { controller.isStopped }
        return controller
    }

    // MARK: - Starting and stopping

    @Test func startingRunsToMain() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = makeController(gdb)
        var states: [DebugController.State] = []
        controller.onStateChange = { states.append($0) }

        gdb.print(FakeBlinky.stopOnConnecting)
        try await controller.start(FakeBlinky.plan)
        #expect(controller.state == .running)

        gdb.print(FakeBlinky.stop(atLine: 21, of: mainC, reason: "breakpoint-hit"))
        await waitUntil("the program stops at main") { controller.isStopped }

        guard case .stopped(let frame) = controller.state else { return }
        #expect(frame?.line == 21)
        #expect(frame?.function == "main")
        // The stop GDB reports on connecting is not shown as a stop.
        #expect(states.map { $0 == .starting || $0 == .running } == [true, true, false])
        #expect(gdb.commands == FakeBlinky.plan.connectCommands + FakeBlinky.plan.loadCommands)
    }

    @Test func aStartThatFailsEndsTheSession() async throws {
        let gdb = FakeBlinky.debugger(refusing: "-target-select")
        let controller = makeController(gdb)

        await #expect(throws: DebugError.refused("Remote connection closed")) {
            try await controller.start(FakeBlinky.plan)
        }

        await waitUntil("the session is over") { !controller.isActive }
        #expect(gdb.commands.last == "-gdb-exit")
    }

    @Test func aStartWithoutABoardSaysSo() async throws {
        let gdb = FakeBlinky.debugger(refusing: "-target-select")
        let controller = makeController(gdb)
        var output = ""
        controller.onOutput = { output += $0 }

        gdb.print("Error: open failed")
        await #expect(throws: FlashFailure.boardNotConnected) {
            try await controller.start(FakeBlinky.plan)
        }
        #expect(output == "Error: open failed\n")
    }

    @Test func aDebuggerThatCannotBeRunLeavesNoSession() async throws {
        let controller = DebugController()
        controller.connect = { _ in throw CocoaError(.fileNoSuchFile) }

        await #expect(throws: CocoaError.self) {
            try await controller.start(FakeBlinky.plan)
        }
        #expect(controller.state == .idle)
    }

    @Test func stoppingLeavesTheProgramRunningAndEndsGDB() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)

        await controller.stop()

        await waitUntil("the session is over") { controller.state == .idle }
        #expect(gdb.commands.suffix(2) == ["-exec-continue", "-gdb-exit"])
    }

    @Test func gdbQuittingByItselfEndsTheSession() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)

        gdb.terminate()

        await waitUntil("the session is over") { controller.state == .idle }
    }

    // MARK: - Running

    @Test func steppingRunsThenStopsOnTheNextLine() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)

        try await controller.stepOver()
        await waitUntil("the program is running") { controller.state == .running }
        gdb.print(FakeBlinky.stop(atLine: 22, of: mainC))
        await waitUntil("the program stops") { controller.isStopped }

        guard case .stopped(let frame) = controller.state else { return }
        #expect(frame?.line == 22)
        #expect(gdb.commands.last == "-exec-next")
    }

    @Test func resetStopsAtTheResetHandler() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)

        try await controller.reset()

        guard case .stopped(let frame) = controller.state else {
            Issue.record("Expected to be stopped, was \(controller.state)")
            return
        }
        #expect(frame?.function == "Reset_Handler")
    }

    // MARK: - Memory

    @Test func memoryReadsStopAtTheEndOfRAM() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)

        // `main`'s locals in the Keil video's program, 44 bytes below the top of RAM.
        _ = await controller.readMemory(at: 0x2003_FFD4, count: 64)
        #expect(gdb.commands.last == "-data-read-memory-bytes 0x2003ffd4 44")

        _ = await controller.readMemory(at: 0x2000_0258, count: 64)
        #expect(gdb.commands.last == "-data-read-memory-bytes 0x20000258 64")
    }

    @Test func readsAreCutAtTheEndOfFlashAndRAMOnly() {
        let chip = Chip.tm4c1294ncpdt
        #expect(chip.readableByteCount(at: 0x2003_FFF0, count: 256) == 16)
        #expect(chip.readableByteCount(at: 0x2003_FFD4, count: 4) == 4)
        #expect(chip.readableByteCount(at: 0x000F_FFFC, count: 64) == 4)
        // Peripherals and anything else are read as asked.
        #expect(chip.readableByteCount(at: 0x4006_43FC, count: 64) == 64)
        #expect(chip.readableByteCount(at: 0x2004_0000, count: 64) == 64)
    }

    // MARK: - Breakpoints

    @Test func breakpointsCanBeSetAndRemovedWithoutASession() async {
        let controller = DebugController()
        var changes = 0
        controller.onBreakpointsChange = { changes += 1 }

        await controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 28))
        await controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 31))
        await controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 28))

        #expect(controller.breakpointLines(in: mainC) == [31])
        #expect(controller.breakpointLines(in: URL(filePath: "/tmp/Blinky/startup/startup.c")).isEmpty)
        #expect(changes == 3)
    }

    @Test func breakpointsSetBeforehandAreGivenToGDBAtTheStart() async throws {
        let gdb = FakeBlinky.debugger(movedLines: [23: 25])
        let controller = makeController(gdb)
        await controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 28))
        await controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 23))

        try await controller.start(FakeBlinky.plan)

        // Line 23 has no code, so GDB put that breakpoint on line 25.
        #expect(controller.breakpointLines(in: mainC) == [25, 28])
        let inserts = gdb.commands.filter { $0.hasPrefix("-break-insert --source") }
        #expect(inserts.count == 2)
        // They are set after connecting and before the program runs.
        let firstInsert = try #require(gdb.commands.firstIndex(of: inserts[0]))
        #expect(firstInsert > (try #require(gdb.commands.firstIndex { $0.hasPrefix("-target-select") })))
        #expect(firstInsert < (try #require(gdb.commands.firstIndex(of: "-target-download"))))
    }

    @Test func breakpointsCanBeChangedWhileStoppedButNotWhileRunning() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)

        #expect(await controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 28)))
        #expect(controller.breakpointLines(in: mainC) == [28])
        #expect(await controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 28)))
        #expect(controller.breakpointLines(in: mainC).isEmpty)
        #expect(gdb.commands.last == "-break-delete 28")

        try await controller.resume()
        await waitUntil("the program is running") { controller.state == .running }
        #expect(await !controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 31)))
        #expect(controller.breakpointLines(in: mainC).isEmpty)
    }

    @Test func breakpointsOutliveTheSession() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)
        await controller.toggleBreakpoint(at: SourceLine(file: mainC, line: 28))

        await controller.stop()
        await waitUntil("the session is over") { controller.state == .idle }

        #expect(controller.breakpointLines(in: mainC) == [28])
    }

    // MARK: - Lines with code

    @Test func linesWithCodeAreOnlyKnownDuringASession() async throws {
        let gdb = FakeBlinky.debugger()
        let idle = DebugController()
        #expect(await idle.executableLines(in: mainC).isEmpty)

        let controller = try await startedAtMain(gdb)
        #expect(await controller.executableLines(in: mainC) == [21, 28, 31])
        #expect(await controller.executableLines(in: mainC) == [21, 28, 31])
        #expect(gdb.commands.filter { $0.hasPrefix("-symbol-list-lines") }.count == 1)
    }

    @Test func logIsCappedAndTrimsOldestLines() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)
        let prefix = String(repeating: "a", count: 400)
        for index in 0..<1500 {
            gdb.print("\(prefix)-\(index)")
        }

        await waitUntil("the final log line arrives") { controller.log.hasSuffix("-\(1499)\n") }
        #expect(controller.log.count <= DebugController.maximumLogLength)
        #expect(!controller.log.contains("\(prefix)-0\n"))
    }
}
