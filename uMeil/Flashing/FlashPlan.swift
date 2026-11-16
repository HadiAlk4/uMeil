import Foundation

/// The OpenOCD command that writes a firmware image to a board.
///
/// OpenOCD's own `program` command is not used: it gives no control over
/// what happens between connecting and writing, and older versions break on
/// file names with spaces. The same steps are spelled out here instead, with
/// a marker line printed before each one so progress can be followed.
struct FlashPlan: Equatable, Sendable {
    var openOCD: URL
    /// The firmware image (`.elf`) to write.
    var image: URL
    var chip: Chip
    var arguments: [String]

    init(openOCD: URL, image: URL, chip: Chip) {
        self.openOCD = openOCD
        self.image = image
        self.chip = chip

        let file = Self.tclQuoted(image.path(percentEncoded: false))
        let commands = [
            // Connect to the debug probe and the chip.
            "init",
            Self.announce(.connected),
            // Stop the chip so its flash can be read and written.
            "reset init",
            Self.chipCheck(for: chip),
            Self.announce(.writing),
            "flash write_image erase \(file)",
            Self.announce(.verifying),
            "verify_image \(file)",
            Self.announce(.resetting),
            "reset run",
            Self.announce(.done),
            "shutdown"
        ]
        // A command that fails ends OpenOCD with a non-zero exit code, so
        // nothing after a failed step runs.
        arguments = ["-f", chip.openOCDConfig] + commands.flatMap { ["-c", $0] }
    }

    // MARK: - Marker lines

    /// The start of every line uMeil asks OpenOCD to print.
    static let markerPrefix = "uMeil: "

    /// Printed, instead of writing anything, when the chip on the board is
    /// not the one the project is for.
    static let wrongChipMarker = markerPrefix + "wrong chip"

    /// The line that announces `stage`.
    static func marker(for stage: FlashStage) -> String {
        markerPrefix + stage.rawValue
    }

    private static func announce(_ stage: FlashStage) -> String {
        "echo \(tclQuoted(marker(for: stage)))"
    }

    // MARK: - Checking the chip

    /// Asks OpenOCD which chip it found and stops before writing if it is
    /// not `chip`. Boards with other Tiva chips use the same debug probe, so
    /// OpenOCD would otherwise happily write to them.
    ///
    /// `flash info` describes the chip in a line such as
    /// "TI/LMI Stellaris information: Chip is class 10 (Snowflake) TM4C1294NCPDT rev A1".
    /// If that line is missing altogether the check lets the flash go ahead,
    /// rather than refuse a good board because OpenOCD changed its wording.
    private static func chipCheck(for chip: Chip) -> String {
        """
        set umeil_chip [flash info 0]
        echo $umeil_chip
        if {[string match "*Chip is class*" $umeil_chip] \
        && ![string match "* \(chip.rawValue) rev*" $umeil_chip]} {
            echo \(tclQuoted(wrongChipMarker))
            shutdown error
        }
        """
    }

    // MARK: - Quoting

    /// `text` as one word in OpenOCD's command language (Tcl), whatever
    /// characters it contains.
    static func tclQuoted(_ text: String) -> String {
        var quoted = "\""
        for character in text {
            if #"\"$["#.contains(character) {
                quoted.append("\\")
            }
            quoted.append(character)
        }
        return quoted + "\""
    }
}

extension Chip {
    /// The OpenOCD script that sets up the debug probe and this chip.
    ///
    /// For the TM4C1294NCPDT this is the EK-TM4C1294XL board script: the
    /// on-board ICDI probe (`interface/ti-icdi.cfg`) and the Tiva target
    /// (`target/stellaris.cfg`). OpenOCD 0.12.0 ships it under this name;
    /// newer builds renamed it to `board/ti_ek-tm4c1294xl.cfg` but still
    /// accept the old name.
    var openOCDConfig: String {
        switch self {
        case .tm4c1294ncpdt: "board/ek-tm4c1294xl.cfg"
        }
    }
}
