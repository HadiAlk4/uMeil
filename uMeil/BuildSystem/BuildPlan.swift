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

    /// C language standards accepted for `-std=`.
    static let allowedCStandards: Set<String> = [
        "c89", "gnu89", "c90", "gnu90", "c99", "gnu99",
        "c11", "gnu11", "c17", "c18", "gnu17", "gnu18",
        "c2x", "gnu2x", "c23", "gnu23"
    ]

    /// Rejects unsafe build settings, response files, dangerous compiler/linker
    /// flags, or paths escaping `projectDirectory`.
    static func validate(_ project: Project, in projectDirectory: URL) throws {
        guard allowedCStandards.contains(project.build.cStandard) else {
            throw BuildError.unsafeProjectSetting("unsupported C standard “\(project.build.cStandard)”")
        }
        for define in project.build.defines {
            guard !define.isEmpty,
                  !define.trimmingCharacters(in: .whitespaces).isEmpty,
                  !ProjectSecurity.containsControlOrNewline(define)
            else {
                throw BuildError.unsafeProjectSetting("invalid preprocessor definition “\(define)”")
            }
        }
        for source in project.sources {
            guard source != ".", ProjectSecurity.safeRelativeURL(for: source, in: projectDirectory) != nil else {
                throw BuildError.unsafeProjectSetting("unsafe source path “\(source)”")
            }
        }
        for includePath in project.includePaths {
            guard ProjectSecurity.safeRelativeURL(for: includePath, in: projectDirectory) != nil else {
                throw BuildError.unsafeProjectSetting("unsafe include path “\(includePath)”")
            }
        }
        let linkerScript = project.build.linkerScript
        guard linkerScript != ".",
              ProjectSecurity.safeRelativeURL(for: linkerScript, in: projectDirectory) != nil
        else {
            throw BuildError.unsafeProjectSetting("unsafe linker script path “\(linkerScript)”")
        }
        try validateFlags(project.build.compilerFlags, role: "compiler", in: projectDirectory)
        try validateFlags(project.build.linkerFlags, role: "linker", in: projectDirectory)
    }

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
    static func fileName(for projectName: String) -> String {
        let scalars = projectName.unicodeScalars.map { scalar -> UnicodeScalar in
            let isUnsafeChar = scalar == "/" || scalar == ":" || scalar == "\\"
            let isControlOrNewline = scalar.value < 0x20
                || (scalar.value >= 0x7F && scalar.value <= 0x9F)
                || scalar == "\u{2028}"
                || scalar == "\u{2029}"
            return (isUnsafeChar || isControlOrNewline) ? "_" : scalar
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
        let stripped = String(cleaned.drop { $0 == "." || $0 == "-" })
        return stripped.isEmpty ? "firmware" : stripped
    }

    /// Resolves a path used in a command against the project folder.
    func url(for path: String) -> URL {
        path.hasPrefix("/") ? URL(filePath: path) : projectDirectory.appending(path: path)
    }
}

// MARK: - Flag Validation

private extension BuildPlan {
    static let forbiddenDriverPrefixes: [String] = [
        "-B", "-fplugin", "--plugin", "-plugin", "-specs", "--specs", "-o",
        "-MF", "-MT", "-MQ", "-MD", "-MMD", "-imacros", "-include",
        "-dumpbase", "-dumpdir", "-auxbase", "-fprofile", "-fdump", "-T", "-isysroot"
    ]

    static let forbiddenExactOrEqualsFlags: [String] = [
        "-wrapper", "--wrapper", "-fuse-ld", "--output", "--prefix",
        "-ftest-coverage", "--coverage", "-save-temps", "--save-temps", "--script",
        "-Xlinker", "-Xpreprocessor", "-Xassembler", "--sysroot"
    ]

    static let separatePathPrefixes = ["-L", "-I", "-isystem", "-iquote", "-idirafter"]

    static func validateFlags(_ flags: [String], role: String, in projectDirectory: URL) throws {
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            guard !flag.isEmpty,
                  !flag.trimmingCharacters(in: .whitespaces).isEmpty,
                  !ProjectSecurity.containsControlOrNewline(flag),
                  !flag.hasPrefix("@"),
                  flag.hasPrefix("-")
            else {
                throw BuildError.unsafeProjectSetting("unsafe \(role) flag “\(flag)”")
            }
            if try consumeTwoArgFlag(flag, flags: flags, index: &index, role: role, in: projectDirectory) {
                continue
            }
            try validateSingleFlag(flag, role: role, in: projectDirectory)
            index += 1
        }
    }

    static func consumeTwoArgFlag(
        _ flag: String,
        flags: [String],
        index: inout Int,
        role: String,
        in projectDirectory: URL
    ) throws -> Bool {
        let expectsPath = separatePathPrefixes.contains(flag) || flag == "--library-path"
        let expectsValue = flag == "-D" || flag == "-U" || flag == "-l"
        guard expectsPath || expectsValue else { return false }
        guard index + 1 < flags.count else {
            throw BuildError.unsafeProjectSetting("incomplete \(role) flag “\(flag)”")
        }
        let next = flags[index + 1]
        if expectsPath {
            try validateFlagPath(next, flag: flag, role: role, in: projectDirectory)
        } else if flag == "-l" {
            try validateLibraryName(next, role: role)
        } else {
            guard !next.isEmpty, !ProjectSecurity.containsControlOrNewline(next), !next.hasPrefix("@") else {
                throw BuildError.unsafeProjectSetting("unsafe \(role) argument “\(next)”")
            }
        }
        index += 2
        return true
    }

    static func validateSingleFlag(_ flag: String, role: String, in projectDirectory: URL) throws {
        let matchesPrefix = forbiddenDriverPrefixes.contains { flag.hasPrefix($0) }
        let matchesExact = forbiddenExactOrEqualsFlags.contains { flag == $0 || flag.hasPrefix("\($0)=") }
        guard !matchesPrefix, !matchesExact else {
            throw BuildError.unsafeProjectSetting("disallowed \(role) flag “\(flag)”")
        }
        guard flag != "-Wl", flag != "-Wp", flag != "-Wa" else {
            throw BuildError.unsafeProjectSetting("incomplete \(role) flag “\(flag)”")
        }
        if flag.hasPrefix("-Wl,") {
            try validateLinkerPassThrough(String(flag.dropFirst(4)), in: projectDirectory)
        } else if flag.hasPrefix("-Wp,") || flag.hasPrefix("-Wa,") {
            let subFlags = String(flag.dropFirst(4)).split(separator: ",", omittingEmptySubsequences: false)
            try validateFlags(subFlags.map(String.init), role: role, in: projectDirectory)
        } else if flag.hasPrefix("--library-path=") {
            let path = String(flag.dropFirst("--library-path=".count))
            try validateFlagPath(path, flag: flag, role: role, in: projectDirectory)
        } else if let prefix = separatePathPrefixes.first(where: { flag.hasPrefix($0) && flag.count > $0.count }) {
            let path = String(flag.dropFirst(prefix.count))
            try validateFlagPath(path, flag: flag, role: role, in: projectDirectory)
        } else if flag.hasPrefix("-l"), flag.count > 2 {
            try validateLibraryName(String(flag.dropFirst(2)), role: role)
        }
    }

    static func validateLinkerPassThrough(_ argumentList: String, in projectDirectory: URL) throws {
        let tokens = argumentList.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < tokens.count {
            let step = try validateLinkerToken(tokens, at: index, argumentList: argumentList, in: projectDirectory)
            index += step
        }
    }

    static func validateLinkerToken(
        _ tokens: [String],
        at index: Int,
        argumentList: String,
        in projectDirectory: URL
    ) throws -> Int {
        let token = tokens[index]
        guard !token.isEmpty, !ProjectSecurity.containsControlOrNewline(token), !token.hasPrefix("@") else {
            throw BuildError.unsafeProjectSetting("unsafe linker flag “-Wl,\(argumentList)”")
        }
        guard !isForbiddenLinkerToken(token) else {
            throw BuildError.unsafeProjectSetting("disallowed linker flag “-Wl,\(token)”")
        }
        if token == "-L" || token == "--library-path" {
            guard index + 1 < tokens.count else {
                throw BuildError.unsafeProjectSetting("incomplete linker flag “-Wl,\(token)”")
            }
            try validateFlagPath(tokens[index + 1], flag: "-Wl,\(token)", role: "linker", in: projectDirectory)
            return 2
        }
        if token.hasPrefix("-L"), token.count > 2 {
            try validateFlagPath(String(token.dropFirst(2)), flag: "-Wl,\(token)", role: "linker", in: projectDirectory)
        } else if token.hasPrefix("--library-path=") {
            let path = String(token.dropFirst("--library-path=".count))
            try validateFlagPath(path, flag: "-Wl,\(token)", role: "linker", in: projectDirectory)
        } else if twoArgLinkerFlags.contains(token) {
            guard index + 1 < tokens.count, !tokens[index + 1].isEmpty else {
                throw BuildError.unsafeProjectSetting("incomplete linker flag “-Wl,\(token)”")
            }
            if token == "-l" { try validateLibraryName(tokens[index + 1], role: "linker") }
            return 2
        } else if !token.hasPrefix("-") {
            throw BuildError.unsafeProjectSetting("unsafe linker argument “-Wl,\(token)”")
        }
        return 1
    }

    static let twoArgLinkerFlags: Set<String> = [
        "-l", "-u", "--undefined", "-e", "--entry", "-z", "--wrap", "-defsym", "--defsym"
    ]

    static func isForbiddenLinkerToken(_ token: String) -> Bool {
        let prefixes = ["-Map", "--Map", "-plugin", "--plugin", "--dependency-file", "-dependency-file",
                        "-o", "-T", "-isysroot"]
        let exactOrEquals = ["--output", "--script", "--sysroot", "-rpath", "--rpath"]
        return prefixes.contains { token.hasPrefix($0) }
            || exactOrEquals.contains { token == $0 || token.hasPrefix("\($0)=") }
    }

    static func validateFlagPath(_ path: String, flag: String, role: String, in projectDirectory: URL) throws {
        guard !path.hasPrefix("="), ProjectSecurity.safeRelativeURL(for: path, in: projectDirectory) != nil else {
            throw BuildError.unsafeProjectSetting("unsafe \(role) path in “\(flag)”")
        }
    }

    static func validateLibraryName(_ name: String, role: String) throws {
        guard !name.isEmpty, !ProjectSecurity.containsControlOrNewline(name),
              !name.hasPrefix("@"), !name.hasPrefix("-") else {
            throw BuildError.unsafeProjectSetting("unsafe \(role) library “\(name)”")
        }
        guard !name.hasPrefix(":") || (!name.dropFirst().isEmpty && !name.contains("/")
            && !name.contains("\\") && !name.contains("..")) else {
            throw BuildError.unsafeProjectSetting("unsafe \(role) library “\(name)”")
        }
    }
}
