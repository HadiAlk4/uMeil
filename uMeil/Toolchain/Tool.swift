import Foundation

/// An external command-line tool that uMeil depends on.
enum Tool: String, CaseIterable, Sendable {
    case compiler
    case debugger
    case openOCD

    /// The file name of the tool's executable.
    var executableName: String {
        switch self {
        case .compiler: "arm-none-eabi-gcc"
        case .debugger: "arm-none-eabi-gdb"
        case .openOCD: "openocd"
        }
    }

    /// A name suitable for showing to the user.
    var displayName: String {
        switch self {
        case .compiler: "Compiler (GCC)"
        case .debugger: "Debugger (GDB)"
        case .openOCD: "OpenOCD"
        }
    }

    /// Arguments that make the tool print its version and exit.
    var versionArguments: [String] { ["--version"] }
}
