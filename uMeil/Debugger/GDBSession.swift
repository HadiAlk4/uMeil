import Foundation
import os

/// A conversation with GDB through its machine interface.
///
/// Commands are sent with a number in front, and GDB puts the same number
/// on its answer, so each `send` can wait for its own result while events
/// (the program stopped, a line of output) arrive in between on `events`.
actor GDBSession {
    /// Maximum UTF-8 byte length retained in `log`.
    static let maxLogBytes = 512 * 1024

    /// What happens during the session, in order. Ends after `.ended`.
    nonisolated let events: AsyncStream<DebugEvent>

    private let connection: any DebuggerConnection
    private let eventContinuation: AsyncStream<DebugEvent>.Continuation
    private let readerTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private var nextToken = 1
    private var waiting: [Int: CheckedContinuation<MIValue, any Error>] = [:]
    private var hasEnded = false
    private var isEnding = false
    /// The thread reported by the most recent `*stopped` event.
    private(set) var currentThreadId = "1"
    /// Bounded session output (GDB streams + OpenOCD log), updated synchronously
    /// before `.output` is yielded on `events`.
    private(set) var log = ""
    /// Register names by GDB's register number, asked for once.
    var registerNames: [String]?

    init(connection: any DebuggerConnection) {
        self.connection = connection
        let (events, eventContinuation) = AsyncStream.makeStream(of: DebugEvent.self)
        self.events = events
        self.eventContinuation = eventContinuation
        let task = Task { [weak self, connection, eventContinuation] in
            for await line in connection.lines {
                guard let self else { break }
                await self.handle(line)
            }
            if let self {
                await self.finishReading()
            } else {
                eventContinuation.yield(.ended)
                eventContinuation.finish()
            }
        }
        readerTask.withLock { $0 = task }
    }

    deinit {
        readerTask.withLock { $0 }?.cancel()
        for continuation in waiting.values {
            continuation.resume(throwing: DebugError.sessionEnded)
        }
        eventContinuation.finish()
    }

    /// Sends an MI command, such as `-exec-next`, and waits for GDB's answer.
    ///
    /// Throws `DebugError.refused` with GDB's message if it answers with an
    /// error, and `DebugError.sessionEnded` if it quits first.
    @discardableResult
    func send(_ command: String) async throws -> MIValue {
        guard !command.unicodeScalars.contains(where: {
            $0.value == 0x0A || $0.value == 0x0D || $0.value == 0x00
        }) else {
            throw DebugError.refused("Invalid debugger command.")
        }
        guard !hasEnded, !isEnding else { throw DebugError.sessionEnded }
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
        if !isEnding {
            isEnding = true
            connection.send("-gdb-exit")
        }
        // Usually GDB is gone long before this; the wait only matters if it hangs.
        for _ in 0..<20 where !hasEnded {
            try? await Task.sleep(for: .milliseconds(100))
        }
        connection.terminate()
    }

    /// Terminates the underlying debugger process synchronously without waiting
    /// for a `-gdb-exit` handshake. Intended for app termination.
    nonisolated func terminateImmediately() {
        connection.terminate()
    }

    // MARK: - Reading

    private func finishReading() {
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
            emitOutput(line + "\n")
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
            let stop = StopEvent(values)
            if let threadId = stop.threadId, !threadId.isEmpty {
                currentThreadId = threadId
            }
            eventContinuation.yield(.stopped(stop))
        case .stream(_, let text):
            emitOutput(text)
        case .event, .prompt:
            break
        }
    }

    private func emitOutput(_ text: String) {
        appendLog(text)
        eventContinuation.yield(.output(text))
    }

    private func appendLog(_ text: String) {
        log.append(text)
        let total = log.utf8.count
        guard total > Self.maxLogBytes else { return }
        var cut = log.utf8.index(log.utf8.startIndex, offsetBy: total - Self.maxLogBytes)
        if cut < log.endIndex, cut.samePosition(in: log) == nil {
            cut = log.index(after: cut)
        }
        log.removeSubrange(log.startIndex..<cut)
    }
}
