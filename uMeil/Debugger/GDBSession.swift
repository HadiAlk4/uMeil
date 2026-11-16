import Foundation

/// A conversation with GDB through its machine interface.
///
/// Commands are sent with a number in front, and GDB puts the same number
/// on its answer, so each `send` can wait for its own result while events
/// (the program stopped, a line of output) arrive in between on `events`.
actor GDBSession {
    /// What happens during the session, in order. Ends after `.ended`.
    nonisolated let events: AsyncStream<DebugEvent>

    private let connection: any DebuggerConnection
    private let eventContinuation: AsyncStream<DebugEvent>.Continuation
    private var nextToken = 1
    private var waiting: [Int: CheckedContinuation<MIValue, any Error>] = [:]
    private var hasEnded = false
    /// Register names by GDB's register number, asked for once.
    var registerNames: [String]?

    init(connection: any DebuggerConnection) {
        self.connection = connection
        (events, eventContinuation) = AsyncStream.makeStream(of: DebugEvent.self)
        Task { await self.readLines() }
    }

    /// Sends an MI command, such as `-exec-next`, and waits for GDB's answer.
    ///
    /// Throws `DebugError.refused` with GDB's message if it answers with an
    /// error, and `DebugError.sessionEnded` if it quits first.
    @discardableResult
    func send(_ command: String) async throws -> MIValue {
        guard !hasEnded else { throw DebugError.sessionEnded }
        let token = nextToken
        nextToken += 1
        return try await withCheckedThrowingContinuation { continuation in
            waiting[token] = continuation
            connection.send("\(token)\(command)")
        }
    }

    /// Asks GDB to quit, which also stops OpenOCD, and makes sure it does.
    func end() async {
        guard !hasEnded else { return }
        connection.send("-gdb-exit")
        // Usually GDB is gone long before this; the wait only matters if it hangs.
        for _ in 0..<20 where !hasEnded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        connection.terminate()
    }

    // MARK: - Reading

    private func readLines() async {
        for await line in connection.lines {
            handle(line)
        }
        hasEnded = true
        for continuation in waiting.values {
            continuation.resume(throwing: DebugError.sessionEnded)
        }
        waiting.removeAll()
        eventContinuation.yield(.ended)
        eventContinuation.finish()
    }

    private func handle(_ line: String) {
        guard let record = try? MIParser.parse(line) else {
            // Not GDB/MI: OpenOCD's log, which shares GDB's error stream.
            eventContinuation.yield(.output(line + "\n"))
            return
        }

        switch record {
        case .result(let token, let outcome, let values):
            guard let token, let continuation = waiting.removeValue(forKey: token) else { return }
            if outcome == .error {
                continuation.resume(throwing: DebugError.refused(values.text("msg") ?? "Unknown error"))
            } else {
                continuation.resume(returning: values)
            }
        case .event(.exec, "running", _):
            eventContinuation.yield(.running)
        case .event(.exec, "stopped", let values):
            eventContinuation.yield(.stopped(StopEvent(values)))
        case .stream(_, let text):
            eventContinuation.yield(.output(text))
        case .event, .prompt:
            break
        }
    }
}
