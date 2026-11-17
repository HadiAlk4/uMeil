import Foundation

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

    private let process = Process()
    private let input: FileHandle
    /// Keeps lines sent from different threads from interleaving.
    private let writeQueue = DispatchQueue(label: "io.github.hadialk4.uMeil.gdb-input")

    /// Starts `executable`. Throws if it cannot be run.
    init(_ executable: URL, arguments: [String]) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        input = inputPipe.fileHandleForWriting
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
        // The stream normally ends when the pipe reaches end of file, after
        // every last line GDB printed has been read. But the pipe only closes
        // once every process holding it has quit, and OpenOCD, which GDB
        // starts, can outlive GDB. So once GDB exits, give the reader a moment
        // to drain what is left, then end the stream anyway.
        process.terminationHandler = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) {
                continuation.finish()
            }
        }

        try process.run()

        PipeLineReader.start(
            outputPipe.fileHandleForReading,
            onLine: { continuation.yield($0) },
            onEnd: { _ in continuation.finish() }
        )
    }

    func send(_ line: String) {
        writeQueue.async { [input] in
            try? input.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}
