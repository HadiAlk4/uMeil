import Foundation

/// Replaces the prebuilt Arm Compiler course libraries with C source that the
/// GNU toolchain can compile.
///
/// The `.lib` archives shipped with the course labs (`ES_Library.lib`,
/// `Lib4.lib`, `Lab1A.lib`, `lib3.lib`, `Lab2_Wed.lib`) contain `.ORC`
/// objects from Arm Compiler 6, which the GNU linker cannot read. Their symbol
/// tables are ordinary `ar` ones, though, so uMeil reads which functions a
/// library provides and writes `uMeil/es_lib.c` implementing them.
///
/// Each lab asks students to replace some library functions with their own
/// of the same name. Keil's linker allows that because it only takes a
/// function from an archive when nothing else defines it. Here every
/// function is weak instead, which has the same effect. Interrupt handlers
/// are the exception: they must override the startup file's weak defaults,
/// so the parts that need one are only written when the library has them.
enum KeilCourseLibrary {
    static let fileName = "es_lib.c"

    // MARK: - What each library provides

    /// The functions of `ES_Library.lib` and `Lib4.lib`, and the Port F, J
    /// and N helpers and UART0 serial functions of `Lab1A.lib`. All weak.
    static let coreSymbols: Set<String> = [
        "ES_Serial", "ES_echo", "ES_getchar", "ES_printf", "ES_putchar", "ES_utob", "PortN_LEDs", "readDec",
        "msDelay", "setSysClk80MHz", "getSysClk",
        "enablePF", "setPFOutput", "setPFInput", "writePFData", "readPFData",
        "enablePJ", "setPJOutput", "setPJInput", "writePJData", "readPJData",
        "enablePN", "setPNOutput", "setPNInput", "writePNData", "readPNData",
        "enableSerial", "setBaudRate115200", "serialRead", "serialWrite"
    ]

    /// `lib3.lib` (Experiment 3, GPIO interrupts): UART0 functions and the
    /// 3 Hz square wave on PK2, which needs `TIMER0A_Handler`.
    static let lab3Symbols: Set<String> = [
        "Setup_UART", "Read_UART", "Write_UART", "Test_UART", "PK2_3Hz_Clock", "Configure_Led_D4",
        "TIMER0A_Handler"
    ]

    /// `Lab2_Wed.lib` (Experiment 2, UART3): the functions students rewrite,
    /// and the redirection of UART3, wired to UART4, to the USB serial port
    /// on UART0, which needs `UART0_Handler` and `UART4_Handler`.
    static let lab2WednesdaySymbols: Set<String> = [
        "setup_GPIO", "setup_UART", "read_UART", "write_UART", "banner", "RedirectOutput",
        "UART0_Handler", "UART4_Handler"
    ]

    /// Names in the libraries' symbol tables that are their own internals,
    /// such as lookup tables, and that no lab calls.
    static let internalSymbols: Set<String> = ["Uvalues", "buf", "setSysClk", "startTimer0A"]

    static var providedSymbols: Set<String> { coreSymbols.union(lab3Symbols).union(lab2WednesdaySymbols) }

    /// Whether uMeil can stand in for any of a library's `symbols`.
    static func coversAny(of symbols: Set<String>) -> Bool {
        !symbols.isDisjoint(with: providedSymbols)
    }

    /// The functions in `symbols` that uMeil's stand-in does not provide,
    /// sorted.
    static func missing(from symbols: Set<String>) -> [String] {
        symbols.subtracting(providedSymbols).subtracting(internalSymbols).sorted()
    }

    /// The source for `es_lib.c`, providing at least `symbols`.
    static func source(providing symbols: Set<String>) -> String {
        var parts = [header, serialAndDelaySource, printfAndClockSource, portSource]
        if !symbols.isDisjoint(with: lab3Symbols) {
            parts.append(lab3Source)
        }
        if !symbols.isDisjoint(with: lab2WednesdaySymbols) {
            parts.append(lab2WednesdaySource)
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Reading a library

    /// The global symbols in the `ar` archive at `url`, or `nil` if it is
    /// not one or cannot be read.
    ///
    /// Arm's `armar` writes the System V symbol table: a member named `/`
    /// holding a big-endian count, that many offsets, then the names.
    static func symbols(ofLibraryAt url: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return symbols(inArchive: data)
    }

    static func symbols(inArchive data: Data) -> Set<String>? {
        let bytes = [UInt8](data)
        guard bytes.count >= 68, bytes.starts(with: Array("!<arch>\n".utf8)) else { return nil }

        let headerSize = 60
        let start = 8
        let name = String(bytes: bytes[start..<start + 16], encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
        let sizeText = String(bytes: bytes[start + 48..<start + 58], encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
        guard name == "/", let size = sizeText.flatMap({ Int($0) }) else { return nil }

        let body = start + headerSize
        guard size >= 4, body + size <= bytes.count else { return nil }
        let count = bytes[body..<body + 4].reduce(0) { $0 << 8 | Int($1) }
        var cursor = body + 4 + 4 * count
        guard cursor <= body + size else { return nil }

        var symbols = Set<String>()
        while symbols.count < count, cursor < body + size {
            let end = bytes[cursor..<body + size].firstIndex(of: 0) ?? body + size
            if end > cursor, let symbol = String(bytes: bytes[cursor..<end], encoding: .utf8) {
                symbols.insert(symbol)
            }
            cursor = end + 1
        }
        return symbols
    }

    /// The symbols of a course library known by `name`, for when its file is
    /// not in the folder.
    static func symbols(forLibraryNamed name: String) -> Set<String>? {
        switch name.lowercased() {
        case "es_library.lib", "lib4.lib":
            ["ES_Serial", "ES_getchar", "ES_putchar", "ES_printf", "ES_utob", "readDec", "msDelay",
             "setSysClk80MHz", "PortN_LEDs", "enablePN", "setPNOutput", "setPNInput", "writePNData", "readPNData"]
        case "lab1a.lib":
            ["enablePF", "setPFOutput", "setPFInput", "writePFData", "readPFData",
             "enablePJ", "setPJOutput", "setPJInput", "writePJData", "readPJData",
             "enablePN", "setPNOutput", "setPNInput", "writePNData", "readPNData",
             "enableSerial", "setBaudRate115200", "serialRead", "serialWrite", "msDelay"]
        case "lib3.lib":
            lab3Symbols.union(["msDelay"])
        case "lab2_wed.lib":
            lab2WednesdaySymbols.union(["msDelay", "setSysClk80MHz"])
        default:
            nil
        }
    }

}
