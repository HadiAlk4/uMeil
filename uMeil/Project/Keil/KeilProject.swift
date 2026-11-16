import Foundation

/// What uMeil needs from a Keil µVision project file (`.uvprojx`): the
/// files, the chip, and the compiler settings of its first target.
struct KeilProject: Equatable, Sendable {
    /// What a file listed in the project is, from Keil's `FileType` number.
    enum FileKind: Equatable, Sendable {
        case cSource
        case assembly
        case library
        case header
        case other
    }

    struct File: Equatable, Sendable {
        /// Relative to the project folder, with forward slashes.
        var path: String
        var kind: FileKind
    }

    /// The name of the image Keil builds, such as "Template".
    var outputName: String
    var targetName: String
    /// The chip's part number, such as "TM4C1294NCPDT".
    var device: String
    var defines: [String]
    var includePaths: [String]
    /// Keil's optimisation setting for Arm Compiler 6: 1 is `-O0`, 2 is
    /// `-O1`, and so on. 0 means the compiler's default.
    var optimizationLevel: Int
    /// Keil's C language setting for Arm Compiler 6: 3 is c99, 6 is gnu11,
    /// and so on. 0 means the compiler's default.
    var languageLevel: Int
    /// The files in the project's groups that are part of the build.
    var files: [File]
    /// Files Keil copied in from its device pack: the startup code and the
    /// system file. Paths as for `files`.
    var packFiles: [String]

    /// Reads the contents of a `.uvprojx` file.
    static func parse(_ data: Data) throws -> KeilProject {
        guard let document = try? XMLDocument(data: data),
              let target = try? document.nodes(forXPath: "/Project/Targets/Target[1]").first
        else {
            throw KeilImportError.notAKeilProject
        }

        func text(_ path: String, in node: XMLNode) -> String {
            let found = try? node.nodes(forXPath: path).first?.stringValue
            return (found ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let fileNodes = (try? target.nodes(forXPath: "Groups/Group/Files/File")) ?? []
        let files: [File] = fileNodes.compactMap { node in
            // A file can be kept in the project but left out of the build.
            guard text("FileOption/CommonProperty/IncludeInBuild", in: node) != "0" else { return nil }
            let path = portablePath(text("FilePath", in: node))
            return path.isEmpty ? nil : File(path: path, kind: kind(forFileType: text("FileType", in: node)))
        }

        let packNodes = (try? document.nodes(forXPath: "/Project/RTE/files/file/instance")) ?? []
        let controls = "TargetOption/TargetArmAds/Cads/VariousControls"

        return KeilProject(
            outputName: text("TargetOption/TargetCommonOption/OutputName", in: target),
            targetName: text("TargetName", in: target),
            device: text("TargetOption/TargetCommonOption/Device", in: target),
            defines: list(text("\(controls)/Define", in: target), separators: ", "),
            includePaths: list(text("\(controls)/IncludePath", in: target), separators: ";").map(portablePath),
            optimizationLevel: Int(text("TargetOption/TargetArmAds/Cads/Optim", in: target)) ?? 0,
            languageLevel: Int(text("TargetOption/TargetArmAds/Cads/v6Lang", in: target)) ?? 0,
            files: files,
            packFiles: packNodes.compactMap(\.stringValue).map(portablePath).filter { !$0.isEmpty }
        )
    }

    private static func kind(forFileType type: String) -> FileKind {
        switch type {
        case "1": .cSource
        case "2": .assembly
        case "4": .library
        case "5": .header
        default: .other
        }
    }

    private static func list(_ text: String, separators: String) -> [String] {
        text.split { separators.contains($0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Turns a Windows path from the project file, such as `.\src\main.c`,
    /// into the form uMeil projects use: `src/main.c`.
    static func portablePath(_ windowsPath: String) -> String {
        var parts = windowsPath.trimmingCharacters(in: .whitespaces)
            .split { $0 == "\\" || $0 == "/" }
            .map(String.init)
        parts.removeAll { $0 == "." }
        return parts.isEmpty && !windowsPath.isEmpty ? "." : parts.joined(separator: "/")
    }

    /// Whether `path` points somewhere only the Windows PC it came from
    /// has, such as `C:/Keil_v5/…`.
    static func isWindowsAbsolute(_ path: String) -> Bool {
        path.wholeMatch(of: #/[A-Za-z]:.*/#) != nil
    }
}

enum KeilImportError: Error, Equatable, LocalizedError {
    case notAKeilProject
    /// The project is for a chip uMeil cannot build for.
    case unsupportedDevice(String)
    /// The folder already has a uMeil project.
    case alreadyImported(URL)

    var errorDescription: String? {
        switch self {
        case .notAKeilProject:
            "This is not a Keil µVision project file (.uvprojx)."
        case .unsupportedDevice(let device):
            "This Keil project is for the \(device.isEmpty ? "an unnamed chip" : device), "
                + "which uMeil cannot build for yet. uMeil supports the "
                + Chip.allCases.map(\.rawValue).joined(separator: ", ") + "."
        case .alreadyImported(let url):
            "This folder already has a uMeil project, \(url.lastPathComponent)."
        }
    }
}
