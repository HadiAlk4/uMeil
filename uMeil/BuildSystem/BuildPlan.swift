import Foundation

/// The tools and SDK files a build uses.
struct BuildEnvironment: Equatable, Sendable {
    /// `arm-none-eabi-gcc`. It compiles and, as a driver, links.
    var compiler: URL
    /// The folder holding the TivaWare headers and prebuilt `driverlib`.
    var tivaWareDirectory: URL = TivaWare.bundledDirectory

    /// `arm-none-eabi-objcopy`, which lives next to the compiler.
    var objcopy: URL { sibling("arm-none-eabi-objcopy") }
    /// `arm-none-eabi-size`, which lives next to the compiler.
    var size: URL { sibling("arm-none-eabi-size") }

    private func sibling(_ name: String) -> URL {
        compiler.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
    }
}

/// One source file to compile.
struct CompileStep: Equatable, Sendable {
    /// The source, relative to the project folder, as written in the project.
    var source: String
    /// The object file, relative to the project folder.
    var object: String
    /// The `.d` file the compiler writes next to the object.
    var dependencyFile: String
    /// The full compiler arguments.
    var arguments: [String]

    /// Arguments safe to pass to `clangd` in `compile_commands.json`: omits
    /// GCC-only diagnostic flags that clang rejects (`-fdiagnostics-column-unit=byte`)
    /// and dependency-file options that expect `build/obj` folders to exist.
    var clangdArguments: [String] {
        var filtered: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            switch argument {
            case "-MF":
                skipNext = true
            case "-MMD", "-MP", "-fdiagnostics-color=never", "-fdiagnostics-column-unit=byte":
                continue
            default:
                filtered.append(argument)
            }
        }
        return filtered
    }
}

/// Every command needed to turn a project into firmware.
///
/// All commands run with the project folder as their working directory and
/// refer to project files by relative path. That keeps compiler messages
/// short ("src/main.c:12:5") and build output the same wherever the project lives.
struct BuildPlan: Equatable, Sendable {
    var projectDirectory: URL
    var environment: BuildEnvironment
    var compileSteps: [CompileStep]
    var linkArguments: [String]
    var objcopyArguments: [String]
    var sizeArguments: [String]

    /// Paths relative to the project folder.
    var elf: String
    var binary: String
    var map: String

    /// The folder, inside the project folder, that holds everything a build produces.
    static let buildDirectoryName = "build"

    init(project: Project, projectDirectory: URL, environment: BuildEnvironment) {
        self.projectDirectory = projectDirectory
        self.environment = environment

        let build = Self.buildDirectoryName
        let outputName = Self.fileName(for: project.name)
        elf = "\(build)/\(outputName).elf"
        binary = "\(build)/\(outputName).bin"
        map = "\(build)/\(outputName).map"

        let common = Self.commonCompileArguments(for: project, environment: environment)
        let steps = project.sources.map { source in
            let object = "\(build)/obj/\(Self.objectName(for: source))"
            let dependencyFile = object + ".d"
            return CompileStep(
                source: source,
                object: object,
                dependencyFile: dependencyFile,
                // -MMD writes the list of included headers; -MP keeps a deleted header from breaking it.
                arguments: common + ["-MMD", "-MP", "-MF", dependencyFile, "-c", source, "-o", object]
            )
        }
        compileSteps = steps

        var link = project.target.chip.cpuFlags
        link += [
            // The project supplies its own startup code and vector table.
            "-nostartfiles",
            // The small C library, with stubs for the system calls a bare chip lacks.
            "--specs=nano.specs",
            "--specs=nosys.specs",
            "-Wl,--gc-sections",
            "-Wl,-Map=\(map)",
            "-T", project.build.linkerScript
        ]
        link += steps.map(\.object)
        if project.build.useDriverLib {
            link.append(TivaWare.library(in: environment.tivaWareDirectory).path(percentEncoded: false))
        }
        // Last, so the project can add libraries such as -lm after its objects.
        link += project.build.linkerFlags
        link += ["-o", elf]
        linkArguments = link

        objcopyArguments = ["-O", "binary", elf, binary]
        sizeArguments = [elf]
    }

    /// The compiler arguments every source in the project shares.
    private static func commonCompileArguments(for project: Project, environment: BuildEnvironment) -> [String] {
        let chip = project.target.chip
        let settings = project.build

        var arguments = chip.cpuFlags
        arguments += [
            "-std=\(settings.cStandard)",
            "-\(settings.optimization.rawValue)",
            "-g",
            // One section per function and variable, so the linker can drop unused ones.
            "-ffunction-sections",
            "-fdata-sections",
            // Color codes would end up in the parsed messages.
            "-fdiagnostics-color=never",
            // Report columns as byte positions in the line, not as screen
            // columns with tabs expanded. The editor converts bytes to its
            // own UTF-16 offsets before moving the cursor there.
            "-fdiagnostics-column-unit=byte"
        ]
        arguments += (chip.defines + settings.defines).map { "-D\($0)" }
        arguments += project.includePaths.map { "-I\($0)" }
        if settings.useDriverLib {
            let headers = TivaWare.includeDirectory(in: environment.tivaWareDirectory)
            arguments.append("-I\(headers.path(percentEncoded: false))")
        }
        arguments += settings.compilerFlags
        return arguments
    }

    /// Files other than objects that the link depends on, relative to the
    /// project folder or absolute.
    var linkInputs: [String] {
        guard let scriptIndex = linkArguments.firstIndex(of: "-T") else { return [] }
        var inputs = [linkArguments[scriptIndex + 1]]
        inputs += linkArguments.filter { $0.hasSuffix(".a") && !$0.hasPrefix("-") }
        return inputs
    }

    /// The object file name for a source: its path with `.o` added, so
    /// `src/main.c` and `lib/main.c` do not collide. `..` is replaced so a
    /// source outside the project still builds inside the build folder.
    private static func objectName(for source: String) -> String {
        source
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0 == ".." ? "__" : String($0) }
            .joined(separator: "/") + ".o"
    }

    /// The project name as a safe file name.
    private static func fileName(for projectName: String) -> String {
        let cleaned = projectName.map { $0 == "/" || $0 == ":" ? "_" : $0 }
        return cleaned.isEmpty ? "firmware" : String(cleaned)
    }

    /// Resolves a path used in a command against the project folder.
    func url(for path: String) -> URL {
        path.hasPrefix("/") ? URL(filePath: path) : projectDirectory.appending(path: path)
    }
}
