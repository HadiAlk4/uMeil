import Foundation

/// Every breakpoint in the project, on or off, for the Breakpoints list.
///
/// The debugger only knows the breakpoints that are on. One that is turned
/// off is taken out of the debugger and remembered here, so turning it back
/// on puts it where it was.
struct BreakpointList: Equatable {
    struct Entry: Equatable {
        let location: SourceLine
        let isEnabled: Bool

        /// "main.c:12"
        var title: String { "\(location.file.lastPathComponent):\(location.line)" }
    }

    /// Breakpoints the user turned off.
    private(set) var disabled: Set<SourceLine> = []

    /// The breakpoints on and off, by file and then by line.
    func entries(enabled: Set<SourceLine>) -> [Entry] {
        let turnedOn = enabled.map { Entry(location: $0, isEnabled: true) }
        let turnedOff = disabled.subtracting(enabled).map { Entry(location: $0, isEnabled: false) }
        return (turnedOn + turnedOff).sorted { lhs, rhs in
            let left = lhs.location, right = rhs.location
            if left.file != right.file {
                return left.file.path(percentEncoded: false)
                    .localizedStandardCompare(right.file.path(percentEncoded: false)) == .orderedAscending
            }
            return left.line < right.line
        }
    }

    /// Lines of `file` with a breakpoint that is off.
    func disabledLines(in file: URL) -> Set<Int> {
        let file = SourceLine(file: file, line: 0).file
        return Set(disabled.filter { $0.file == file }.map(\.line))
    }

    mutating func markDisabled(_ location: SourceLine) {
        disabled.insert(location)
    }

    mutating func forget(_ location: SourceLine) {
        disabled.remove(location)
    }

    /// A breakpoint turned on from the gutter is no longer off.
    mutating func forget(_ enabled: Set<SourceLine>) {
        disabled.subtract(enabled)
    }

    mutating func removeAll() {
        disabled.removeAll()
    }
}
