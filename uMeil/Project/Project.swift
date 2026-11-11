import Foundation

/// A uMeil project: which files to build, for which chip, and with what settings.
///
/// All paths are relative to the folder that holds the project file and use
/// forward slashes, so a project can be moved or checked into Git as is.
struct Project: Codable, Equatable, Sendable {
    var name: String
    var target: Target
    /// C and assembly files to compile.
    var sources: [String]
    /// Folders searched for `#include`, on top of the ones the SDK adds.
    var includePaths: [String]
    var build: BuildSettings

    struct Target: Codable, Equatable, Sendable {
        var chip: Chip
        /// The board the chip sits on, if the project is written for a specific one.
        var board: Board?
    }

    struct BuildSettings: Codable, Equatable, Sendable {
        /// Passed to the compiler as `-std=`.
        var cStandard: String
        var optimization: Optimization
        /// Preprocessor macros, as `NAME` or `NAME=value`. The chip adds its own.
        var defines: [String]
        /// Extra compiler flags. The CPU and FPU flags come from the chip.
        var compilerFlags: [String]
        /// Extra linker flags.
        var linkerFlags: [String]
        var linkerScript: String
        /// Adds the TivaWare headers shipped with uMeil to the include paths
        /// and links the prebuilt `driverlib`.
        var useDriverLib: Bool
    }

    /// The compiler's `-O` level.
    enum Optimization: String, Codable, CaseIterable, Sendable {
        case none = "O0"
        case debug = "Og"
        case more = "O2"
        case size = "Os"
    }
}
