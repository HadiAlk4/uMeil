import Foundation

/// How far a flash has got. The raw value is the word in the marker line
/// OpenOCD prints when the stage begins.
enum FlashStage: String, CaseIterable, Sendable {
    /// OpenOCD has started and is looking for the board.
    case connecting
    /// The debug probe and chip answered.
    case connected
    case writing
    case verifying
    case resetting
    case done

    /// What to tell the user while this stage runs.
    var title: String {
        switch self {
        case .connecting: "Connecting to the board…"
        case .connected: "Checking the chip…"
        case .writing: "Writing firmware…"
        case .verifying: "Verifying…"
        case .resetting: "Restarting the board…"
        case .done: "Flashed"
        }
    }

    /// How much of the progress bar is filled when this stage begins, 0 to 1.
    /// OpenOCD does not report progress within a stage, so the bar moves in
    /// steps; writing takes the longest and gets the biggest one.
    var progress: Double {
        switch self {
        case .connecting: 0.05
        case .connected: 0.15
        case .writing: 0.25
        case .verifying: 0.7
        case .resetting: 0.9
        case .done: 1
        }
    }
}

/// Why a flash did not happen or did not finish.
enum FlashFailure: Error, Equatable, LocalizedError {
    case openOCDNotFound
    case boardNotConnected
    /// The board holds a different chip. `found` is its part number, when
    /// OpenOCD could name it.
    case wrongChip(found: String?, expected: Chip)
    /// The firmware read back from the chip differs from what was written.
    case verifyFailed
    case imageNotFound(URL)
    /// The chosen file is not a program for an Arm chip.
    case notAnImage(URL)
    case stopped
    /// Anything else, with OpenOCD's own error message.
    case other(String)

    var errorDescription: String? {
        switch self {
        case .openOCDNotFound:
            "OpenOCD is not installed. Install it from Window > Toolchain Status."
        case .boardNotConnected:
            "No board found. Plug the LaunchPad's DEBUG USB port into this Mac, then try again."
        case .wrongChip(let found?, let expected):
            "This board has a \(found) chip, but this firmware is for the \(expected.rawValue). Nothing was written."
        case .wrongChip(nil, let expected):
            "The chip on this board is not a \(expected.rawValue), which this firmware is for. Nothing was written."
        case .verifyFailed:
            "The firmware was written, but reading it back did not match. "
                + "Flash again; if it keeps failing, try another USB cable."
        case .imageNotFound(let url):
            "The firmware image \(url.lastPathComponent) is missing. Build the project, then flash again."
        case .notAnImage(let url):
            "\(url.lastPathComponent) is not a firmware image for an Arm chip. "
                + "Choose the .axf or .elf file that a build produced."
        case .stopped:
            "Flashing was stopped. The board may hold part of a program, so flash again before using it."
        case .other(let message):
            "Flashing failed: \(message)"
        }
    }
}

/// Reads what OpenOCD prints while flashing.
enum FlashOutput {
    /// The stage that `line` announces, if it is one of uMeil's marker lines.
    static func stage(announcedBy line: some StringProtocol) -> FlashStage? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(FlashPlan.markerPrefix) else { return nil }
        return FlashStage(rawValue: String(line.dropFirst(FlashPlan.markerPrefix.count)))
    }

    /// The part number OpenOCD found, from the line
    /// "TI/LMI Stellaris information: Chip is class 10 (Snowflake) TM4C1294NCPDT rev A2".
    static func chipName(in output: String) -> String? {
        guard let match = output.firstMatch(of: #/Chip is class \d+ \([^)]*\) (.+?) rev \S+/#) else {
            return nil
        }
        return String(match.1)
    }

    /// How many bytes were written, from the line
    /// "wrote 16384 bytes from file /proj/build/Blinky.elf in 1.313867s (12.178 KiB/s)".
    /// The count is whole 16 kB flash pages, not the size of the program.
    static func bytesWritten(in output: String) -> Int? {
        output.firstMatch(of: #/wrote (\d+) bytes from file/#).flatMap { Int($0.1) }
    }

    /// Works out what went wrong from everything OpenOCD printed.
    ///
    /// Returns `nil` only for a run that finished: exit code 0 and the final
    /// marker line present.
    static func failure(in output: String, exitCode: Int32, plan: FlashPlan) -> FlashFailure? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let stages = lines.compactMap { stage(announcedBy: $0) }
        if exitCode == 0, stages.contains(.done) {
            return nil
        }

        if lines.contains(FlashPlan.wrongChipMarker) {
            return .wrongChip(found: chipName(in: output), expected: plan.chip)
        }
        // The flash driver could not recognise the chip as a Tiva part at all.
        if output.contains("Cannot identify target as a Stellaris") {
            return .wrongChip(found: nil, expected: plan.chip)
        }

        let errors = lines.compactMap { line in
            line.wholeMatch(of: #/Error: (.*)/#).map { String($0.1) }
        }
        // The ICDI probe cannot drive the chip's reset pin and says so at
        // every reset, in flashes that work too. It is never the cause.
        .filter { $0 != "SRST error" }
        // The debug probe never answered: OpenOCD could not open it over USB.
        if !stages.contains(.connected), errors.contains(where: isProbeMissing) {
            return .boardNotConnected
        }
        if errors.contains(where: { $0.hasPrefix("couldn't open ") }) {
            return .imageNotFound(plan.image)
        }
        if stages.contains(.verifying), !stages.contains(.resetting),
           lines.contains(where: isVerifyMismatch) {
            return .verifyFailed
        }

        // Otherwise pass on OpenOCD's own words. The first error is the
        // cause; later ones are usually consequences of it.
        if let first = errors.first(where: { !$0.isEmpty }) {
            return .other(first)
        }
        return .other("OpenOCD stopped unexpectedly (exit code \(exitCode)).")
    }

    /// Whether an error says the ICDI debug probe is not on USB.
    private static func isProbeMissing(_ error: String) -> Bool {
        // "open failed" is what the ICDI driver reports when no device with
        // its USB ID is plugged in.
        error == "open failed" || error.contains("unable to open") || error.contains("No device found")
    }

    /// Whether a line reports that the chip's contents differ from the image.
    private static func isVerifyMismatch(_ line: String) -> Bool {
        line.contains("checksum mismatch") || line.contains("contents differ")
            || line.wholeMatch(of: #/(?:Error: )?diff \d+ address 0x.*/#) != nil
    }
}
