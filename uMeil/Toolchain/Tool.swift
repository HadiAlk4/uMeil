import Foundation

/// An external command-line tool that uMeil depends on.
enum Tool: String, CaseIterable, Sendable {
    case compiler
    case debugger
    case openOCD
    case clangd

    /// The file name of the tool's executable.
    var executableName: String {
        switch self {
        case .compiler: "arm-none-eabi-gcc"
        case .debugger: "arm-none-eabi-gdb"
        case .openOCD: "openocd"
        case .clangd: "clangd"
        }
    }

    /// A name suitable for showing to the user.
    var displayName: String {
        switch self {
        case .compiler: "Compiler (GCC)"
        case .debugger: "Debugger (GDB)"
        case .openOCD: "OpenOCD"
        case .clangd: "Code Intelligence (clangd)"
        }
    }

    /// Arguments that make the tool print its version and exit.
    var versionArguments: [String] { ["--version"] }
}
