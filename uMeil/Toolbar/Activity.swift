import Foundation

/// What the app is doing or last did, shown in the middle of the toolbar:
/// "Building…", "Flashing 40%", "Build succeeded", "Stopped at main.c:21".
struct Activity: Equatable {
    enum Kind: Equatable {
        /// Nothing has happened yet.
        case idle
        /// Busy. `progress` runs from 0 to 1, or is `nil` when it is not known.
        case working(progress: Double?)
        case succeeded
        /// Finished, with warnings.
        case warning
        case failed
        /// Neither good nor bad news, like where the debugger stopped.
        case info
    }

    var text: String
    var kind: Kind

    static let idle = Activity(text: "Ready", kind: .idle)

    /// The kind for something that finished with `diagnostics`.
    static func outcome(of diagnostics: [Diagnostic]) -> Kind {
        if diagnostics.contains(where: { $0.severity == .error }) { return .failed }
        if diagnostics.contains(where: { $0.severity == .warning }) { return .warning }
        return .succeeded
    }
}
