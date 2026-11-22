import Foundation

/// A line in a source file.
struct SourceLine: Hashable, Sendable {
    let file: URL
    /// Counting from 1.
    let line: Int

    /// Symbolic links are resolved, so the path GDB reports and the path the
    /// editor opened compare equal.
    init(file: URL, line: Int) {
        self.file = file.resolvingSymlinksInPath().standardizedFileURL
        self.line = line
    }
}

/// Runs debug sessions for one window: starts and stops GDB, follows whether
/// the program is running, and keeps the breakpoints.
///
/// Breakpoints can be set before a session starts. They are handed to GDB
/// when it does, and outlive it.
@MainActor
final class DebugController {
    enum State: Equatable {
        /// No session.
        case idle
        /// Connecting, writing the program, running to `main`.
        case starting
        case running
        /// Stopped at `frame`, which is `nil` if GDB could not say where.
        case stopped(StackFrame?)
    }

    private(set) var state = State.idle {
        didSet {
            if case .stopped = state {
                onStateChange?(state)
            } else if state != oldValue {
                onStateChange?(state)
            }
        }
    }

    /// Why the program stopped most recently, or `nil` when idle, running, or after a reset.
    private(set) var lastStopReason: StopReason?

    var onStateChange: ((State) -> Void)?
    /// Called when a breakpoint is added, removed, or moved by GDB.
    var onBreakpointsChange: (() -> Void)?
    /// Called with each piece of output from GDB and OpenOCD.
    var onOutput: ((String) -> Void)?

    /// Starts the debugger. Replaceable so tests can debug without GDB.
    var connect: (DebugPlan) throws -> any DebuggerConnection = { plan in
        try GDBProcess(plan.gdb, arguments: plan.gdbArguments)
    }

    /// Maximum number of characters kept in `log`. Older lines are dropped first.
    static let maximumLogLength = 500_000
    /// Maximum UTF-8 byte length kept in `log`.
    static let maxLogBytes = 512 * 1024

    private(set) var breakpoints: Set<SourceLine> = []
    /// The breakpoints GDB has, for the session that is running.
    private var inserted: [SourceLine: Breakpoint] = [:]
    /// Incremented by `clearBreakpoints()` so in-flight inserts cannot restore old breakpoints.
    private var breakpointEpoch = 0
    /// Tail of the serialized breakpoint-toggle queue while a session is active.
    private var breakpointQueueTail: Task<Void, Never>?
    /// Lines with code, by file, for the program being debugged.
    private var executableLines: [URL: Set<Int>] = [:]
    private(set) var session: GDBSession?
    /// Consumes events for the active session until `.ended`.
    private var eventTask: Task<Void, Never>?
    /// Coalesces concurrent `stop()` calls so GDB is only resumed and exited once.
    private var stopTask: Task<Void, Never>?
    /// The chip of the session that is running.
    private(set) var chip: Chip?
    /// Everything GDB and OpenOCD printed in this session, capped to `maximumLogLength` / `maxLogBytes`.
    private(set) var log = ""
    private var logCharacterCount = 0

    var isActive: Bool { state != .idle }

    var isStopped: Bool {
        if case .stopped = state, stopTask == nil { true } else { false }
    }

    // MARK: - Starting and stopping

    /// Starts a session and runs the program to `main`. Returns once the
    /// program is on the chip and running; `state` follows it from there.
    func start(_ plan: DebugPlan) async throws {
        guard state == .idle else { return }
        lastStopReason = nil
        log = ""
        logCharacterCount = 0
        chip = plan.chip
        state = .starting

        let connection: any DebuggerConnection
        do {
            connection = try connect(plan)
        } catch {
            chip = nil
            state = .idle
            throw error
        }
        let session = GDBSession(connection: connection)
        self.session = session
        let task = Task { [weak self] in
            for await event in session.events {
                guard let self, self.session === session else { break }
                self.handle(event)
            }
        }
        self.eventTask = task

        do {
            for command in plan.connectCommands {
                try await session.send(command)
            }
            await insertBreakpoints(into: session)
            for command in plan.loadCommands {
                try await session.send(command)
            }
        } catch {
            await session.end()
            await task.value
            let sessionLog = await session.log
            let combinedLog = log.isEmpty ? sessionLog : (sessionLog.isEmpty ? log : log + "\n" + sessionLog)
            if self.session === session {
                cleanupSession()
            }
            throw Self.startFailure(error, log: combinedLog)
        }
        if self.session === session, state == .starting {
            lastStopReason = nil
            state = .running
        }
    }

    /// Ends the session and leaves the program running on the chip.
    func stop() async {
        if let existing = stopTask {
            await existing.value
            return
        }
        guard let session else { return }
        let wasStopped = isStopped
        let taskToDrain = eventTask
        let task = Task {
            if wasStopped {
                // GDB lets go of a running chip without stopping it.
                try? await session.resume()
            }
            await session.end()
            await taskToDrain?.value
        }
        stopTask = task
        await task.value
        if stopTask == task {
            stopTask = nil
        }
    }

    /// Stops the session cleanly, forcing immediate termination if GDB does
    /// not exit within `timeout`.
    func stop(timeout: Duration) async {
        guard isActive else { return }
        let once = StopCompletion()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.terminateImmediately()
                once.run { continuation.resume() }
            }
            Task { [weak self] in
                await self?.stop()
                timer.cancel()
                once.run { continuation.resume() }
            }
        }
    }

    /// Synchronously kills the underlying debugger process/connection and resets
    /// state to idle, used on app termination when an async stop cannot run or times out.
    func terminateImmediately() {
        let activeSession = session
        eventTask?.cancel()
        cleanupSession()
        activeSession?.terminateImmediately()
    }

    private func cleanupSession() {
        session = nil
        eventTask = nil
        inserted = [:]
        executableLines = [:]
        chip = nil
        lastStopReason = nil
        state = .idle
    }

    /// OpenOCD's reason for a failed start, which GDB reports only as
    /// "Remote connection closed".
    private static func startFailure(_ error: any Error, log: String) -> any Error {
        let probeIsMissing = log.contains("Error: open failed") || log.contains("unable to open")
            || log.contains("No device found")
        return probeIsMissing ? FlashFailure.boardNotConnected : error
    }

    private func handle(_ event: DebugEvent) {
        switch event {
        case .running:
            if state != .starting {
                lastStopReason = nil
                state = .running
            }
        case .stopped(let stop):
            // On connecting GDB reports where it found the chip, with no
            // reason. The session has not reached `main` yet.
            if stop.reason == .other("") { return }
            lastStopReason = stop.reason
            state = .stopped(stop.frame)
        case .output(let text):
            appendLog(text)
            onOutput?(text)
        case .ended:
            cleanupSession()
        }
    }

    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        log.append(text)
        logCharacterCount += text.count

        if logCharacterCount > Self.maximumLogLength {
            let actualExcess = log.count - Self.maximumLogLength
            if actualExcess > 0 {
                let target = log.index(log.startIndex, offsetBy: actualExcess - 1)
                let cut: String.Index
                if let newline = log[target...].firstIndex(where: \.isNewline),
                   log.index(after: newline) < log.endIndex {
                    cut = log.index(after: newline)
                } else {
                    cut = log.index(after: target)
                }
                log.removeSubrange(..<cut)
            }
            logCharacterCount = log.count
        }
        if log.utf8.count > Self.maxLogBytes {
            var cut = log.utf8.index(log.utf8.startIndex, offsetBy: log.utf8.count - Self.maxLogBytes)
            while cut < log.endIndex, cut.samePosition(in: log) == nil { cut = log.utf8.index(after: cut) }
            log.removeSubrange(..<cut)
            logCharacterCount = log.count
        }
    }
}

// Kept in an extension in the same file to keep the class body short.
extension DebugController {
    // MARK: - Running

    func resume() async throws { try await session?.resume() }
    func pause() async throws { try await session?.pause() }
    func stepOver() async throws { try await session?.stepOver() }
    func stepInto() async throws { try await session?.stepInto() }
    func stepOut() async throws { try await session?.stepOut() }
    func run(to location: SourceLine) async throws { try await session?.run(toLine: location.line, of: location.file) }

    /// Resets the chip and leaves it stopped at its first instruction.
    func reset() async throws {
        guard isStopped, let session else { return }
        let frame = try await session.reset()
        guard self.session === session else { return }
        lastStopReason = nil
        state = .stopped(frame)
    }

    // MARK: - Breakpoints

    func breakpointLines(in file: URL) -> Set<Int> {
        let file = SourceLine(file: file, line: 0).file
        return Set(breakpoints.filter { $0.file == file }.map(\.line))
    }

    /// Removes all saved breakpoints, such as when switching projects.
    func clearBreakpoints() {
        breakpointEpoch += 1
        let hadBreakpoints = !breakpoints.isEmpty
        breakpoints.removeAll()
        inserted.removeAll()
        if hadBreakpoints { onBreakpointsChange?() }
    }

    /// Adds a breakpoint at `location`, or removes the one that is there.
    ///
    /// During a session GDB may put a new breakpoint on a later line, the
    /// next one that has code. Returns false, changing nothing, while running.
    @discardableResult
    func toggleBreakpoint(at location: SourceLine) async -> Bool {
        if session == nil, breakpointQueueTail == nil { return toggleBreakpointOffline(at: location) }
        let previous = breakpointQueueTail
        let operation = Task { [weak self] () -> Bool in
            await previous?.value
            return await self?.performToggleBreakpoint(at: location) ?? false
        }
        let marker = Task<Void, Never> { _ = await operation.value }
        breakpointQueueTail = marker
        let result = await operation.value
        if breakpointQueueTail == marker { breakpointQueueTail = nil }
        return result
    }

    private func toggleBreakpointOffline(at location: SourceLine) -> Bool {
        if breakpoints.remove(location) == nil { breakpoints.insert(location) }
        onBreakpointsChange?()
        return true
    }

    private func performToggleBreakpoint(at location: SourceLine) async -> Bool {
        guard let session else { return toggleBreakpointOffline(at: location) }
        guard isStopped else { return false }
        if breakpoints.remove(location) != nil {
            if let breakpoint = inserted.removeValue(forKey: location) {
                try? await session.deleteBreakpoint(breakpoint)
            }
        } else {
            await insert(location, into: session)
        }
        onBreakpointsChange?()
        return true
    }

    /// Hands the breakpoints set before the session to GDB.
    func insertBreakpoints(into session: GDBSession) async {
        let startEpoch = breakpointEpoch
        let wanted = breakpoints.sorted { ($0.file.path, $0.line) < ($1.file.path, $1.line) }
        for location in wanted {
            guard self.session === session, breakpointEpoch == startEpoch else { return }
            await insert(location, into: session)
        }
        if self.session === session, breakpointEpoch == startEpoch { onBreakpointsChange?() }
    }

    /// Sets one breakpoint in GDB and records it where GDB put it. A place
    /// GDB refuses, such as a file that is not in the program, is kept so it
    /// is not lost, but will not stop anything.
    private func insert(_ location: SourceLine, into session: GDBSession) async {
        let startEpoch = breakpointEpoch
        guard let breakpoint = try? await session.insertBreakpoint(line: location.line, of: location.file) else {
            if self.session === session, breakpointEpoch == startEpoch { breakpoints.insert(location) }
            return
        }
        guard self.session === session, breakpointEpoch == startEpoch else { return }
        let actual = SourceLine(file: breakpoint.file ?? location.file, line: breakpoint.line ?? location.line)
        breakpoints.remove(location)
        if let duplicate = inserted[actual] {
            // GDB moved it onto a line that already had one.
            try? await session.deleteBreakpoint(duplicate)
            guard self.session === session, breakpointEpoch == startEpoch else { return }
        }
        inserted[actual] = breakpoint
        breakpoints.insert(actual)
    }

    // MARK: - Lines with code

    /// The lines of `file` a breakpoint can stop on. Empty without a session.
    func executableLines(in file: URL) async -> Set<Int> {
        let file = SourceLine(file: file, line: 0).file
        if let known = executableLines[file] { return known }
        guard let session, let lines = try? await session.executableLines(of: file), self.session === session
        else { return [] }
        executableLines[file] = lines
        return lines
    }
}

@MainActor
private final class StopCompletion {
    private var hasRun = false
    func run(_ body: () -> Void) { guard !hasRun else { return }; hasRun = true; body() }
}
