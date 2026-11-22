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
    /// user's own `.gdbinit` out of the session, and `set auto-load off`
    /// prevents loading untrusted project-local scripts or `.gdbinit` files.
    var gdbArguments: [String] { ["--interpreter=mi3", "-q", "-nx", "-iex", "set auto-load off"] }

    /// Commands that set GDB up and connect it to the chip.
    var connectCommands: [String] {
        [
            // Lets commands such as pause be sent while the program runs.
            "-gdb-set mi-async on",
            "-gdb-set confirm off",
            "-file-exec-and-symbols \(Self.cQuoted(image.path(percentEncoded: false)))",
            // GDB maps `-target-select` directly to the CLI `target` command
            // (`DEF_MI_CMD_CLI`) without running `mi_parse_argv`: MI-quoting
            // the pipe command makes GDB treat `"| ..."` as a literal device
            // name, whereas raw `| <shellQuoted>` passes paths with consecutive
            // spaces, quotes, and backslashes verbatim to `$SHELL -c`.
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
            "-c", "'bindto localhost'",
            "-c", "'gdb_port pipe'",
            "-c", "'telnet_port disabled'",
            "-c", "'tcl_port disabled'",
            "-f", Self.shellQuoted(chip.openOCDConfig)
        ].joined(separator: " ")
    }

    // MARK: - Quoting

    /// `text` as one word for the shell, stripping line breaks and NUL so it
    /// cannot split a GDB/MI command line.
    static func shellQuoted(_ text: String) -> String {
        let sanitized = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { $0.value != 0x0A && $0.value != 0x0D && $0.value != 0x00 }
        ))
        return "'" + sanitized.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `text` as a quoted string in a GDB/MI command, escaping quotes,
    /// backslashes, line breaks, and tabs, and stripping NUL and remaining
    /// ASCII control characters so pasted or multiline input cannot inject
    /// extra MI command lines.
    static func cQuoted(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22:
                quoted.append("\\\"")
            case 0x5C:
                quoted.append("\\\\")
            case 0x0A:
                quoted.append("\\n")
            case 0x0D:
                quoted.append("\\r")
            case 0x09:
                quoted.append("\\t")
            case ..<0x20, 0x7F:
                continue
            default:
                quoted.unicodeScalars.append(scalar)
            }
        }
        quoted.append("\"")
        return quoted
    }
}
