import Foundation

/// Reads a pipe as data arrives and splits it into lines, without keeping a
/// thread blocked on the read. Like `ProcessRunner`, it relies on the file
/// handle's `readabilityHandler`, so long-running tools (OpenOCD, GDB) do not
/// each tie up a GCD worker thread.
enum PipeLineReader {
    /// Starts reading `file`. `onLine` is called for each complete line, and
    /// once more for any unterminated text left at the end. `onEnd` is called
    /// once, at end of file, with everything that was read. Both are called on
    /// the handle's own serial queue, never at the same time.
    static func start(
        _ file: FileHandle,
        onLine: @escaping @Sendable (String) -> Void,
        onEnd: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let buffer = Buffer()
        file.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard chunk.isEmpty else {
                buffer.append(chunk, onLine: onLine)
                return
            }
            // End of file: every process holding the write end has closed it.
            handle.readabilityHandler = nil
            try? handle.close()
            onEnd(buffer.finish(onLine: onLine))
        }
    }

    /// Decodes tool output as UTF-8, replacing any invalid bytes, and drops
    /// the carriage return of a Windows-style line ending.
    static func text(from data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        return text.hasSuffix("\r") ? String(text.dropLast()) : text
    }

    /// Only touched from one handle's readability handler, which the system
    /// never runs concurrently with itself.
    private final class Buffer: @unchecked Sendable {
        private var all = Data()
        private var pending = Data()

        func append(_ chunk: Data, onLine: (String) -> Void) {
            all.append(chunk)
            pending.append(chunk)
            let newline = UInt8(ascii: "\n")
            while let end = pending.firstIndex(of: newline) {
                onLine(PipeLineReader.text(from: pending[pending.startIndex..<end]))
                pending.removeSubrange(pending.startIndex...end)
            }
        }

        func finish(onLine: (String) -> Void) -> String {
            if !pending.isEmpty {
                onLine(PipeLineReader.text(from: pending))
                pending.removeAll()
            }
            return PipeLineReader.text(from: all)
        }
    }
}
