import Foundation
import os
import Testing
@testable import uMeil

/// A `DebuggerConnection` that lets tests delay replies, ignore `-gdb-exit`, and count `terminate()`.
private final class ControlledDebugger: DebuggerConnection {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: (commands: [String](), terminates: 0))
    private let onSend: @Sendable (String, String, AsyncStream<String>.Continuation) -> Void

    init(onSend: @escaping @Sendable (String, String, AsyncStream<String>.Continuation) -> Void) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.onSend = onSend
    }

    var commands: [String] { state.withLock { $0.commands } }
    var terminateCount: Int { state.withLock { $0.terminates } }

    func send(_ line: String) {
        let token = String(line.prefix { $0.isNumber })
        let command = String(line.dropFirst(token.count))
        state.withLock { $0.commands.append(command) }
        onSend(token, command, continuation)
    }

    func emit(_ line: String) { continuation.yield(line) }

    func terminate() {
        state.withLock { $0.terminates += 1 }
        continuation.finish()
    }
}

extension DebugControllerTests {
    @Test func resetNotifiesOnSameFrameAndIgnoresWhenNotStopped() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)
        var stops = 0
        controller.onStateChange = { if case .stopped = $0 { stops += 1 } }

        try await controller.reset()
        try await controller.reset()
        #expect(stops == 2)

        // Consecutive identical stop events also notify, and reset is ignored while running/idle.
        gdb.print(FakeBlinky.stop(atLine: 21, of: mainC))
        await waitUntil("third stop") { stops == 3 }
        gdb.print(FakeBlinky.stop(atLine: 21, of: mainC))
        await waitUntil("fourth stop") { stops == 4 }

        let before = gdb.commands.count
        try await controller.resume()
        await waitUntil("running") { controller.state == .running }
        try await controller.reset()
        #expect(gdb.commands.dropFirst(before).allSatisfy { $0 != DebugPlan.resetCommand })
    }

    @Test func stopReasonTracksSignalsAndUpdatesSummaryStatus() async throws {
        let gdb = FakeBlinky.debugger()
        let controller = try await startedAtMain(gdb)
        #expect(controller.lastStopReason == .breakpoint(number: ""))

        try await controller.resume()
        await waitUntil("running") { controller.state == .running }
        #expect(controller.lastStopReason == nil)

        gdb.print("*stopped,reason=\"signal-received\",signal-name=\"SIGSEGV\","
            + "signal-meaning=\"Segmentation fault\",frame={addr=\"0x20a\",func=\"main\","
            + "fullname=\"\(mainC.path(percentEncoded: false))\",line=\"21\"},thread-id=\"1\"")
        await waitUntil("fault stop") { controller.isStopped }
        #expect(controller.lastStopReason == .signal(name: "SIGSEGV", meaning: "Segmentation fault"))
        #expect(DebugSummary.statusText(for: controller.state, reason: controller.lastStopReason)
            == "Stopped (SIGSEGV) at main.c:21 in main")

        try await controller.reset()
        #expect(controller.lastStopReason == nil)

        gdb.print(FakeBlinky.stopInLibrary)
        await waitUntil("sigint") { controller.lastStopReason == .signal(name: "SIGINT", meaning: "Interrupt") }
        #expect(DebugSummary.statusText(for: controller.state, reason: controller.lastStopReason)
            == "Stopped in SysCtlDelay at 0x472, where there is no source code to show")
    }

    @Test func startFailureDrainsOutputResetsStateAndAllowsRetry() async throws {
        let failing = FakeDebugger { command in
            command.hasPrefix("-target-select") ? ["Error: open failed", "^error,msg=\"Remote connection closed\""]
                : ["^done"]
        }
        let controller = makeController(failing)
        await #expect(throws: FlashFailure.boardNotConnected) { try await controller.start(FakeBlinky.plan) }
        #expect(controller.state == .idle && controller.chip == nil && controller.session == nil)

        // Immediate retry succeeds because state is already idle before start() threw.
        controller.connect = { _ in FakeBlinky.debugger() }
        try await controller.start(FakeBlinky.plan)
        #expect(controller.state == .running && controller.chip == .tm4c1294ncpdt)
        await controller.stop()
        #expect(controller.state == .idle && controller.chip == nil)

        controller.connect = { _ in throw CocoaError(.fileNoSuchFile) }
        await #expect(throws: CocoaError.self) { try await controller.start(FakeBlinky.plan) }
        #expect(controller.chip == nil)
    }

    @Test func logIsCappedAndStaleSessionLinesDoNotPolluteNewSession() async throws {
        let pending = OSAllocatedUnfairLock(initialState: (token: "", cont: AsyncStream<String>.Continuation?.none))
        let first = ControlledDebugger { token, cmd, cont in
            if cmd.hasPrefix("-symbol-list-lines") {
                pending.withLock { $0 = (token, cont) }
            } else if cmd == "-gdb-exit" {
                cont.yield(token + "^exit")
                cont.finish()
            } else {
                cont.yield(token + "^done")
            }
        }
        let controller = makeController(first)
        try await controller.start(FakeBlinky.plan)
        first.emit("START_MARKER")
        let chunk = String(repeating: "a", count: 64 * 1024)
        for _ in 0..<10 { first.emit(chunk) }
        first.emit("END_MARKER")
        await waitUntil("log drained") { controller.log.contains("END_MARKER") }
        #expect(controller.log.utf8.count <= DebugController.maxLogBytes)
        #expect(!controller.log.contains("START_MARKER"))

        let staleLookup = Task { await controller.executableLines(in: mainC) }
        await waitUntil("lookup sent") { !pending.withLock { $0.token }.isEmpty }
        await controller.stop()
        controller.connect = { _ in FakeBlinky.debugger() }
        try await controller.start(FakeBlinky.plan)
        _ = pending.withLock { $0.cont?.yield("\($0.token)^done,lines=[{pc=\"0x1\",line=\"99\"}]") }
        #expect(await staleLookup.value.isEmpty)
        #expect(await controller.executableLines(in: mainC) == [21, 28, 31])
    }

    @Test func concurrentToggleBreakpointsSerializeAndClearAndTerminateWork() async throws {
        let held = OSAllocatedUnfairLock(initialState: (token: "", cont: AsyncStream<String>.Continuation?.none))
        let path = SourceLine(file: mainC, line: 28).file.path(percentEncoded: false)
        let gdb = ControlledDebugger { token, cmd, cont in
            if cmd.hasPrefix("-break-insert --source") {
                held.withLock { $0 = (token, cont) }
            } else if cmd == "-gdb-exit" {
                // Intentionally ignore to exercise stop(timeout:) below.
            } else {
                cont.yield(token + "^done")
            }
        }
        let controller = makeController(gdb)
        try await controller.start(FakeBlinky.plan)
        gdb.emit(FakeBlinky.stop(atLine: 21, of: mainC, reason: "breakpoint-hit"))
        await waitUntil("stopped") { controller.isStopped }

        let target = SourceLine(file: mainC, line: 28)
        let click1 = Task { await controller.toggleBreakpoint(at: target) }
        let click2 = Task { await controller.toggleBreakpoint(at: target) }
        await waitUntil("insert sent") { !held.withLock { $0.token }.isEmpty }
        _ = held.withLock {
            $0.cont?.yield("\($0.token)^done,bkpt={number=\"7\",enabled=\"y\",fullname=\"\(path)\",line=\"28\"}")
        }
        let toggledOn = await click1.value
        let toggledOff = await click2.value
        #expect(toggledOn && toggledOff)
        #expect(controller.breakpointLines(in: mainC).isEmpty)
        #expect(gdb.commands.filter { $0.hasPrefix("-break-insert --source") }.count == 1)
        #expect(gdb.commands.filter { $0.hasPrefix("-break-delete") }.count == 1)

        await controller.stop(timeout: .milliseconds(50))
        #expect(!controller.isActive && gdb.terminateCount >= 1)

        await controller.toggleBreakpoint(at: target)
        var notified = false
        controller.onBreakpointsChange = { notified = true }
        controller.clearBreakpoints()
        #expect(controller.breakpoints.isEmpty && notified)

        let hanging = ControlledDebugger { _, _, _ in }
        controller.connect = { _ in hanging }
        let startTask = Task { try? await controller.start(FakeBlinky.plan) }
        await waitUntil("starting") { controller.state == .starting && !hanging.commands.isEmpty }
        controller.terminateImmediately()
        #expect(controller.state == .idle && controller.chip == nil && hanging.terminateCount >= 1)
        await startTask.value
    }
}
