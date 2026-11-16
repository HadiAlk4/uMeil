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
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }

    var onStateChange: ((State) -> Void)?
    /// Called when a breakpoint is added, removed, or moved by GDB.
    var onBreakpointsChange: (() -> Void)?
    /// Called with each piece of output from GDB and OpenOCD.
    var onOutput: ((String) -> Void)?

    /// Starts the debugger. Replaceable so tests can debug without GDB.
    var connect: (DebugPlan) throws -> any DebuggerConnection = { plan in
        try GDBProcess(plan.gdb, arguments: plan.gdbArguments)
    }

    private(set) var breakpoints: Set<SourceLine> = []
    /// The breakpoints GDB has, for the session that is running.
    private var inserted: [SourceLine: Breakpoint] = [:]
    /// Lines with code, by file, for the program being debugged.
    private var executableLines: [URL: Set<Int>] = [:]
    private(set) var session: GDBSession?
    /// Everything GDB and OpenOCD printed in this session.
    private(set) var log = ""

    var isActive: Bool { state != .idle }

    var isStopped: Bool {
        if case .stopped = state { true } else { false }
    }

    // MARK: - Starting and stopping

    /// Starts a session and runs the program to `main`. Returns once the
    /// program is on the chip and running; `state` follows it from there.
    func start(_ plan: DebugPlan) async throws {
        guard state == .idle else { return }
        state = .starting
        log = ""

        let session: GDBSession
        do {
            session = GDBSession(connection: try connect(plan))
        } catch {
            state = .idle
            throw error
        }
        self.session = session
        Task { [weak self] in
            for await event in session.events {
                self?.handle(event)
            }
        }

        do {
            for command in plan.connectCommands {
                try await session.send(command)
            }
            await insertBreakpoints(into: session)
            for command in plan.loadCommands {
                try await session.send(command)
            }
        } catch {
            let failure = Self.startFailure(error, log: log)
            await session.end()
            throw failure
        }
        if state == .starting {
            state = .running
        }
    }

    /// Ends the session and leaves the program running on the chip.
    func stop() async {
        guard let session else { return }
        if isStopped {
            // GDB lets go of a running chip without stopping it.
            try? await session.resume()
        }
        await session.end()
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
                state = .running
            }
        case .stopped(let stop):
            // On connecting GDB reports where it found the chip, with no
            // reason. The session has not reached `main` yet.
            if stop.reason == .other("") { return }
            state = .stopped(stop.frame)
        case .output(let text):
            log += text
            onOutput?(text)
        case .ended:
            session = nil
            inserted = [:]
            executableLines = [:]
            state = .idle
        }
    }

    // MARK: - Running

    func resume() async throws { try await session?.resume() }
    func pause() async throws { try await session?.pause() }
    func stepOver() async throws { try await session?.stepOver() }
    func stepInto() async throws { try await session?.stepInto() }
    func stepOut() async throws { try await session?.stepOut() }

    func run(to location: SourceLine) async throws {
        try await session?.run(toLine: location.line, of: location.file)
    }

    /// Resets the chip and leaves it stopped at its first instruction.
    func reset() async throws {
        guard let session else { return }
        state = .stopped(try await session.reset())
    }

    // MARK: - Breakpoints

    func breakpointLines(in file: URL) -> Set<Int> {
        let file = SourceLine(file: file, line: 0).file
        return Set(breakpoints.filter { $0.file == file }.map(\.line))
    }

    /// Adds a breakpoint at `location`, or removes the one that is there.
    ///
    /// During a session GDB may put a new breakpoint on a later line, the
    /// next one that has code. Returns false, changing nothing, while the
    /// program is running: GDB cannot change breakpoints then.
    @discardableResult
    func toggleBreakpoint(at location: SourceLine) async -> Bool {
        guard let session else {
            if breakpoints.remove(location) == nil {
                breakpoints.insert(location)
            }
            onBreakpointsChange?()
            return true
        }
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
    private func insertBreakpoints(into session: GDBSession) async {
        let wanted = breakpoints.sorted { ($0.file.path, $0.line) < ($1.file.path, $1.line) }
        for location in wanted {
            breakpoints.remove(location)
            await insert(location, into: session)
        }
        onBreakpointsChange?()
    }

    /// Sets one breakpoint in GDB and records it where GDB put it. A place
    /// GDB refuses, such as a file that is not in the program, is kept so it
    /// is not lost, but will not stop anything.
    private func insert(_ location: SourceLine, into session: GDBSession) async {
        guard let breakpoint = try? await session.insertBreakpoint(line: location.line, of: location.file) else {
            breakpoints.insert(location)
            return
        }
        let actual = SourceLine(file: breakpoint.file ?? location.file, line: breakpoint.line ?? location.line)
        if let duplicate = inserted[actual] {
            // GDB moved it onto a line that already had one.
            try? await session.deleteBreakpoint(duplicate)
        }
        inserted[actual] = breakpoint
        breakpoints.insert(actual)
    }

    // MARK: - Lines with code

    /// The lines of `file` a breakpoint can stop on. Empty without a session.
    func executableLines(in file: URL) async -> Set<Int> {
        let file = SourceLine(file: file, line: 0).file
        if let known = executableLines[file] { return known }
        guard let session, let lines = try? await session.executableLines(of: file) else { return [] }
        if self.session != nil {
            executableLines[file] = lines
        }
        return lines
    }
}
