import Foundation
import os

/// A running debugger to exchange lines of text with. A protocol so tests
/// can stand in for GDB with saved output.
protocol DebuggerConnection: Sendable {
    /// Every line the debugger prints, without line endings. The stream
    /// ends when the debugger is gone.
    var lines: AsyncStream<String> { get }

    /// Sends one line. Does nothing if the debugger is gone.
    func send(_ line: String)

    /// Stops the debugger if it is still running.
    func terminate()
}

/// A real GDB process.
final class GDBProcess: DebuggerConnection {
    let lines: AsyncStream<String>

    private struct HandleState {
        var inputClosed = false
        var outputClosed = false
    }

    private let process = Process()
    private let input: FileHandle
    private let outputHandle: FileHandle
    /// Keeps lines sent from different threads from interleaving.
    private let writeQueue = DispatchQueue(label: "io.github.hadialk4.uMeil.gdb-input")
    private let handleState = OSAllocatedUnfairLock(initialState: HandleState())

    /// Starts `executable`. Throws if it cannot be run.
    init(_ executable: URL, arguments: [String]) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        input = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        // Writing after GDB has quit must fail quietly, not end uMeil with SIGPIPE.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)

        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = inputPipe
        // OpenOCD, which GDB starts, writes its log to the same error stream.
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.lines = lines
        let outputHandle = self.outputHandle
        let handleState = self.handleState
        // The stream normally ends when the pipe reaches end of file, after
        // every last line GDB printed has been read. But the pipe only closes
        // once every process holding it has quit, and OpenOCD, which GDB
        // starts, can outlive GDB. So once GDB exits, give the reader a moment
        // to drain what is left, then stop reading and end the stream anyway.
        process.terminationHandler = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) {
                let shouldClose = handleState.withLock { state -> Bool in
                    guard !state.outputClosed else { return false }
                    state.outputClosed = true
                    return true
                }
                if shouldClose {
                    outputHandle.readabilityHandler = nil
                    try? outputHandle.close()
                }
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            handleState.withLock {
                $0.inputClosed = true
                $0.outputClosed = true
            }
            try? input.close()
            try? outputHandle.close()
            continuation.finish()
            throw error
        }

        PipeLineReader.start(
            outputHandle,
            collectAll: false,
            onLine: { continuation.yield($0) },
            onEnd: { _ in
                handleState.withLock { $0.outputClosed = true }
                continuation.finish()
            }
        )
    }

    deinit {
        terminate()
    }

    func send(_ line: String) {
        guard !line.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0x0D || $0.value == 0x00 }) else {
            return
        }
        writeQueue.async { [input, handleState] in
            guard !handleState.withLock({ $0.inputClosed }) else { return }
            try? input.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
        let shouldClose = handleState.withLock { state -> Bool in
            guard !state.inputClosed else { return false }
            state.inputClosed = true
            return true
        }
        if shouldClose {
            writeQueue.async { [input] in
                try? input.close()
            }
        }
    }
}
