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
        // The pipe only closes when every process holding it has quit, so
        // the stream is also ended when GDB itself exits.
        process.terminationHandler = { _ in continuation.finish() }

        try process.run()

        let output = outputPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            var pending = Data()
            let newline = UInt8(ascii: "\n")
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let end = pending.firstIndex(of: newline) {
                    // swiftlint:disable:next optional_data_string_conversion
                    var line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    continuation.yield(line)
                    pending.removeSubrange(pending.startIndex...end)
                }
            }
            continuation.finish()
        }
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
