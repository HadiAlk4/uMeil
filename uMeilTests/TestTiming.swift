import Foundation
import Testing

/// How long tests that check timing may take.
///
/// On a developer's Mac the limits are as written. A shared CI runner has
/// few cores and runs every test at once, so the same work can take several
/// times longer without anything being wrong. CI sets `UMEIL_TIMING_SCALE`
/// (passed as `TEST_RUNNER_UMEIL_TIMING_SCALE`) to stretch every limit by
/// that factor, rather than each test guessing at its own allowance.
enum TestTiming {
    /// 1 unless the environment asks for more. Never less than 1, so a
    /// typo cannot make the limits stricter.
    static let scale: Double = {
        let text = ProcessInfo.processInfo.environment["UMEIL_TIMING_SCALE"] ?? ""
        return max(Double(text) ?? 1, 1)
    }()

    /// `seconds`, stretched for a slow machine.
    static func seconds(_ seconds: Double) -> Double {
        seconds * scale
    }

    /// `duration`, stretched for a slow machine.
    static func duration(_ duration: Duration) -> Duration {
        duration * scale
    }

    /// A `.timeLimit` of `minutes`, stretched for a slow machine and
    /// rounded up to whole minutes, the unit Swift Testing counts in.
    static func minutes(_ minutes: Int) -> TimeLimitTrait.Duration {
        .minutes(wholeMinutes(minutes))
    }

    static func wholeMinutes(_ minutes: Int) -> Int {
        Int((Double(minutes) * scale).rounded(.up))
    }
}
