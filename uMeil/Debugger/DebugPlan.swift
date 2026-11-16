import Foundation

/// How to start a debug session: which GDB to run, and the commands that
/// take it from nothing to the program stopped at `main`.
///
/// GDB starts OpenOCD itself and talks to it through a pipe, so there is no
/// network port to clash with another program, and OpenOCD goes away when
/// GDB does.
struct DebugPlan: Equatable, Sendable {
    var gdb: URL
    var openOCD: URL
    /// The firmware image (`.elf`) to debug, built with debug information.
    var image: URL
    var chip: Chip

    /// `mi3` is the newest version of the machine interface. `-nx` keeps the
    /// user's own `.gdbinit` out of the session.
    var gdbArguments: [String] { ["--interpreter=mi3", "-q", "-nx"] }

    /// Commands that set GDB up and connect it to the chip.
    var connectCommands: [String] {
        [
            // Lets commands such as pause be sent while the program runs.
            "-gdb-set mi-async on",
            "-gdb-set confirm off",
            "-file-exec-and-symbols \(Self.cQuoted(image.path(percentEncoded: false)))",
            "-target-select extended-remote | \(openOCDCommand)"
        ]
    }

    /// Commands that put the program on the chip and run it to `main`.
    /// The last one starts the program; the stop at `main` arrives as an event.
    var loadCommands: [String] {
        [
            Self.resetCommand,
            "-target-download",
            // Start again from the new program's reset vector.
            Self.resetCommand,
            "-break-insert -t main",
            "-exec-continue"
        ]
    }

    /// Resets the chip and leaves it stopped at its first instruction.
    static let resetCommand = "-interpreter-exec console \"monitor reset halt\""

    /// The shell command GDB runs to start OpenOCD as its GDB server.
    /// `gdb_port` is the spelling OpenOCD 0.12.0 knows; newer builds prefer
    /// `gdb port` but still accept it.
    private var openOCDCommand: String {
        [
            Self.shellQuoted(openOCD.path(percentEncoded: false)),
            "-c", "'gdb_port pipe'",
            "-f", Self.shellQuoted(chip.openOCDConfig)
        ].joined(separator: " ")
    }

    // MARK: - Quoting

    /// `text` as one word for the shell, whatever characters it contains.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `text` as a quoted string in a GDB/MI command.
    static func cQuoted(_ text: String) -> String {
        var quoted = "\""
        for character in text {
            if character == "\"" || character == "\\" {
                quoted.append("\\")
            }
            quoted.append(character)
        }
        return quoted + "\""
    }
}
