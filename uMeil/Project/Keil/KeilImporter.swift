import Foundation

/// What importing a Keil project produced.
struct KeilImport: Equatable, Sendable {
    /// The new uMeil project file, next to the Keil one.
    var projectFile: URL
    var project: Project
    /// Things the user should know: files that were left out, and pieces
    /// that are still missing before the project can build.
    var notes: [String]
}

/// Makes a uMeil project out of a Keil µVision project, so the same sources
/// can be built with the GNU toolchain.
///
/// Nothing Keil uses is changed or moved. The import adds a `.umeil` project
/// file next to the `.uvprojx`, and a `uMeil` folder holding a startup file
/// and a linker script for the GNU toolchain.
enum KeilImporter {
    static let fileExtension = "uvprojx"

    /// The folder, inside the project folder, for the files the import writes.
    static let supportDirectoryName = "uMeil"
    static let startupFileName = "startup_gcc.c"

    /// The Keil project file in `folder`, if there is one.
    static func keilProjectFile(in folder: URL) -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return (contents ?? [])
            .filter { $0.pathExtension == fileExtension }
            .min { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The uMeil project file that importing `keilFile` makes, next to it.
    static func projectFile(for keilFile: URL) -> URL {
        let baseName = keilFile.deletingPathExtension().lastPathComponent
        return keilFile.deletingLastPathComponent().appending(path: "\(baseName).\(ProjectFile.fileExtension)")
    }

    static let defaultLinkerScript = ProjectTemplate.bundledDirectory.appending(path: "Blinky/files/tm4c1294ncpdt.ld")

    /// Imports the Keil project at `keilFile`.
    ///
    /// - Parameter linkerScript: The linker script to copy in. The default is
    ///   the one uMeil's own projects for the chip use.
    static func importProject(
        at keilFile: URL,
        linkerScript: URL = defaultLinkerScript
    ) throws -> KeilImport {
        let keil = try KeilProject.parse(Data(contentsOf: keilFile))
        guard let chip = Chip(rawValue: keil.device) else {
            throw KeilImportError.unsupportedDevice(keil.device)
        }

        let folder = keilFile.deletingLastPathComponent()
        let baseName = keilFile.deletingPathExtension().lastPathComponent
        let projectFile = projectFile(for: keilFile)
        guard !FileManager.default.fileExists(atPath: projectFile.path(percentEncoded: false)) else {
            throw KeilImportError.alreadyImported(projectFile)
        }

        var notes: [String] = []
        var librarySymbols: Set<String>?
        var sources = sourceFiles(of: keil, in: folder, librarySymbols: &librarySymbols, notes: &notes)
        let context = ImportContext(
            keil: keil, chip: chip, folder: folder, librarySymbols: librarySymbols, linkerScript: linkerScript
        )
        let support = try writeSupportFiles(for: context, overwriteEdited: true, notes: &notes)
        sources += support.sources

        let includePaths = includePaths(of: keil, in: folder, notes: &notes)
        noteMissingDeviceHeader(of: keil, includePaths: includePaths, in: folder, notes: &notes)

        let project = Project(
            name: keil.outputName.isEmpty ? baseName : keil.outputName,
            target: .init(chip: chip, board: Board.allCases.first { $0.chip == chip }),
            sources: sources,
            includePaths: includePaths,
            build: .init(
                cStandard: cStandard(forKeilLevel: keil.languageLevel),
                optimization: optimization(forKeilLevel: keil.optimizationLevel),
                defines: keil.defines,
                compilerFlags: ["-Wall"],
                linkerFlags: [],
                linkerScript: support.linkerScript,
                // Keil projects use Keil's register header, not TivaWare.
                useDriverLib: false
            )
        )
        try ProjectFile.save(project, to: projectFile)
        return KeilImport(projectFile: projectFile, project: project, notes: notes)
    }

    // MARK: - Sources

    /// The C files to build: the ones in the project's groups, plus C files
    /// Keil copied in from its device pack (the system file).
    ///
    /// `librarySymbols` is set when the project links a course library uMeil
    /// can stand in for, to the functions those libraries provide.
    static func sourceFiles(
        of keil: KeilProject,
        in folder: URL,
        librarySymbols: inout Set<String>?,
        notes: inout [String]
    ) -> [String] {
        var sources: [String] = []
        for file in keil.files {
            let name = URL(filePath: file.path).lastPathComponent
            switch file.kind {
            case .cSource:
                if KeilProject.isWindowsAbsolute(file.path) {
                    notes.append("\(name) was left out: its path (\(file.path)) only exists on the PC it came from.")
                } else {
                    sources.append(file.path)
                }
            case .assembly:
                notes.append("\(name) was left out: it is written for Keil's assembler, which the GNU toolchain "
                    + "cannot read.")
            case .library:
                let symbols = KeilCourseLibrary.symbols(ofLibraryAt: folder.appending(path: file.path))
                    ?? KeilCourseLibrary.symbols(forLibraryNamed: name)
                guard let symbols, KeilCourseLibrary.coversAny(of: symbols) else {
                    notes.append("\(name) was left out: it is a library built by Arm Compiler, which the GNU linker "
                        + "cannot read. The functions it provides will be reported as undefined when you build.")
                    continue
                }
                librarySymbols = (librarySymbols ?? []).union(symbols)
                notes.append("\(name) was replaced with \(supportDirectoryName)/\(KeilCourseLibrary.fileName), "
                    + "because the original library was built for Arm Compiler.")
                let missing = KeilCourseLibrary.missing(from: symbols)
                if !missing.isEmpty {
                    notes.append("uMeil's stand-in for \(name) does not provide "
                        + missing.joined(separator: ", ") + ". Calls to them will be reported as undefined.")
                }
            case .header, .other:
                break
            }
        }
        for path in keil.packFiles where path.lowercased().hasSuffix(".c") && !sources.contains(path) {
            sources.append(path)
        }
        for source in sources where !exists(source, in: folder) {
            notes.append("\(source) is listed in the Keil project but is not in the folder.")
        }
        return sources
    }

    /// The startup file to write, based on the Keil startup file's vector
    /// table when the project has one.
    static func startupSource(
        for keil: KeilProject,
        chip: Chip,
        in folder: URL,
        notes: inout [String]
    ) throws -> String {
        let keilStartup = keil.packFiles.first { $0.lowercased().hasSuffix(".s") }
            ?? keil.files.first { $0.kind == .assembly && $0.path.lowercased().contains("startup") }?.path

        if let keilStartup,
           let text = try? String(contentsOf: folder.appending(path: keilStartup), encoding: .utf8),
           let vectors = KeilStartup.vectorNames(inKeilStartup: text) {
            return KeilStartup.gnuSource(
                vectors: vectors,
                interruptCount: chip.interruptCount,
                basedOn: URL(filePath: keilStartup).lastPathComponent
            )
        }
        notes.append("Keil's startup file was not found, so interrupt handlers have no names. Only the "
            + "Cortex-M4 ones, such as SysTick_Handler, will be called.")
        return KeilStartup.gnuSource(
            vectors: KeilStartup.coreVectors,
            interruptCount: chip.interruptCount,
            basedOn: nil
        )
    }

    // MARK: - Include paths

    /// Where the compiler looks for headers: the project folder, the folders
    /// Keil was told about, and the folders of the project's own headers and
    /// pack files.
    static func includePaths(of keil: KeilProject, in folder: URL, notes: inout [String]) -> [String] {
        var paths = ["."]
        for path in keil.includePaths {
            if KeilProject.isWindowsAbsolute(path) {
                notes.append("The include folder \(path) was left out: it only exists on the PC it came from.")
            } else {
                paths.append(path)
            }
        }
        paths += keil.files.filter { $0.kind == .header }.map { directory(of: $0.path) }
        paths += keil.packFiles.map(directory(of:))

        // Keil generates RTE_Components.h here, with spaces in the target's
        // name turned into underscores.
        let generated = "RTE/_" + keil.targetName.replacing(" ", with: "_")
        if exists(generated, in: folder) {
            paths.append(generated)
        }
        paths.append(supportDirectoryName)

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Keil projects include a register header, such as `TM4C129.h`, that
    /// lives in Keil's device pack on the PC and not in the project folder.
    static func noteMissingDeviceHeader(
        of keil: KeilProject,
        includePaths: [String],
        in folder: URL,
        notes: inout [String]
    ) {
        let components = folder.appending(path: "RTE/_" + keil.targetName.replacing(" ", with: "_"))
            .appending(path: "RTE_Components.h")
        guard let text = try? String(contentsOf: components, encoding: .utf8),
              let match = text.firstMatch(of: #/#define\s+CMSIS_device_header\s+"([^"]+)"/#)
        else { return }

        let header = String(match.1)
        let isPresent = includePaths.contains { exists($0 + "/" + header, in: folder) }
        if !isPresent {
            notes.append("\(header) is not in the project folder. Keil keeps it in its device pack. The project "
                + "will not build until that header, and the CMSIS headers it includes, are added to the folder.")
        }
    }

    // MARK: - Settings

    /// Arm Compiler 6's optimisation levels, as Keil numbers them, mapped to
    /// the nearest level uMeil offers.
    static func optimization(forKeilLevel level: Int) -> Project.Optimization {
        switch level {
        case 2: .debug // -O1: the closest GNU level that stays debuggable is -Og.
        case 3, 4, 5, 8: .more // -O2, -O3, -Ofast, -Omax
        case 6, 7: .size // -Os, -Oz
        default: .none // -O0, and Keil's default
        }
    }

    /// Arm Compiler 6's C language settings, as Keil numbers them.
    static func cStandard(forKeilLevel level: Int) -> String {
        switch level {
        case 1: "c90"
        case 2: "gnu90"
        case 3: "c99"
        case 4: "gnu99"
        case 5: "c11"
        default: "gnu11"
        }
    }

    // MARK: - Paths

    private static func directory(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    private static func exists(_ path: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: path).path(percentEncoded: false))
    }
}
