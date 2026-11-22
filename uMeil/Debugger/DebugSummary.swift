import Foundation

/// Turns the debugger's state into the one-line status under the issues list.
enum DebugSummary {
    /// For example "Stopped at main.c:21 in main" or "Running".
    static func statusText(for state: DebugController.State, reason: StopReason? = nil) -> String {
        switch state {
        case .idle:
            return "Debug session ended"
        case .starting:
            return "Starting debug session…"
        case .running:
            return "Running"
        case .stopped(let frame):
            let prefix = stopPrefix(for: reason)
            guard let frame else { return prefix }
            let function = frame.function.map { " in \($0)" } ?? ""
            if let file = frame.file, let line = frame.line {
                return "\(prefix) at \(file.lastPathComponent):\(line)\(function)"
            }
            let address = frame.address.map { " at 0x" + String($0, radix: 16) } ?? ""
            return "\(prefix)\(function)\(address), where there is no source code to show"
        }
    }

    private static func stopPrefix(for reason: StopReason?) -> String {
        switch reason {
        case .signal(let name, let meaning):
            // Pause (`-exec-interrupt`) always reports SIGINT, which is not a fault.
            if name == "SIGINT" { return "Stopped" }
            let label = !name.isEmpty ? name : (meaning ?? "signal")
            return "Stopped (\(label))"
        case .exited:
            return "Stopped (exited)"
        default:
            return "Stopped"
        }
    }
}
