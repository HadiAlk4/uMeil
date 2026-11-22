import Foundation

/// A tool that a build, flash or debug session needs is not installed.
struct ToolNotInstalled: Error, Equatable, LocalizedError {
    var tool: Tool

    var errorDescription: String? {
        "\(tool.missingMessage) Install it from Window > Toolchain Status."
    }
}

extension Tool {
    /// What the user cannot do without the tool, for the banner that offers to install it.
    var missingMessage: String {
        switch self {
        case .compiler: "The compiler (GCC) is not installed, so the project cannot be built."
        case .debugger: "The debugger (GDB) is not installed, so a debug session cannot start."
        case .openOCD: "OpenOCD is not installed, so uMeil cannot reach the board."
        case .clangd: "Code intelligence (clangd) is not installed."
        }
    }
}

extension Error {
    /// The tool whose absence caused this error, if that is what it is about.
    var missingTool: Tool? {
        switch self as Error {
        case let error as ToolNotInstalled: error.tool
        case let error as BuildError where error == .compilerNotFound: .compiler
        case let error as FlashFailure where error == .openOCDNotFound: .openOCD
        default: nil
        }
    }
}
