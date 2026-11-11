import Foundation

/// How much flash and RAM a firmware image uses, from `arm-none-eabi-size`.
struct ProgramSize: Equatable, Sendable {
    /// Code and constants.
    var text: Int
    /// Variables with a starting value. They take up both flash and RAM.
    var data: Int
    /// Variables without a starting value.
    var bss: Int

    var flash: Int { text + data }
    var ram: Int { data + bss }

    /// Parses the default (Berkeley) output of `size`:
    ///
    ///        text    data     bss     dec     hex filename
    ///        1396       0       0    1396     574 build/Blinky.elf
    static func parse(_ output: String) -> ProgramSize? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 3, let text = Int(fields[0]), let data = Int(fields[1]), let bss = Int(fields[2]) {
                return ProgramSize(text: text, data: data, bss: bss)
            }
        }
        return nil
    }
}

/// What a build did and what it produced.
struct BuildResult: Sendable {
    /// True if every step ran without an error. Warnings do not count.
    var succeeded: Bool
    /// Messages from this build, including saved warnings for files that
    /// were up to date and so were not compiled again.
    var diagnostics: [Diagnostic]
    /// The sources that were compiled this time, as written in the project.
    var compiledSources: [String]
    /// Whether the firmware was linked again.
    var didLink: Bool
    /// The outputs, when the build succeeded.
    var elf: URL?
    var binary: URL?
    var size: ProgramSize?
    /// Every command that ran, with its output, for showing to the user.
    var log: String
}

enum BuildError: Error, Equatable, LocalizedError {
    case compilerNotFound

    var errorDescription: String? {
        switch self {
        case .compilerNotFound:
            "The compiler (arm-none-eabi-gcc) is not installed. Install it from Window > Toolchain Status."
        }
    }
}

/// Builds a project by running the compiler directly: no Make, CMake, or Ninja.
///
/// Builds are incremental. A source is only compiled again if it, a header
/// it includes, or its compiler flags changed since its object file was made.
struct BuildEngine: Sendable {
    var runner: any ProcessRunning = ProcessRunner()
    /// How many sources are compiled at the same time.
    var maxParallelJobs = max(ProcessInfo.processInfo.activeProcessorCount, 1)

    /// Loads the project at `projectFile` and works out how to build it.
    static func plan(forProjectFile projectFile: URL, locator: ToolLocator = .standard()) throws -> BuildPlan {
        let project = try ProjectFile.load(from: projectFile)
        guard let compiler = locator.locate(.compiler) else {
            throw BuildError.compilerNotFound
        }
        return BuildPlan(
            project: project,
            projectDirectory: projectFile.deletingLastPathComponent(),
            environment: BuildEnvironment(compiler: compiler)
        )
    }

    /// Runs the build. Compiler and linker errors are reported in the
    /// result; this only throws when the build cannot be attempted at all,
    /// for example when a tool cannot be launched.
    func build(_ plan: BuildPlan) async throws -> BuildResult {
        var result = BuildResult(succeeded: false, diagnostics: [], compiledSources: [], didLink: false, log: "")
        try prepareDirectories(for: plan)
        try writeCompileCommands(for: plan)

        // Compile what is out of date.
        let outdated = plan.compileSteps.indices.filter { needsCompile(plan.compileSteps[$0], in: plan) }
        let outputs = try await compile(outdated.map { plan.compileSteps[$0] }, in: plan)
        var compileFailed = false

        for (index, step) in plan.compileSteps.enumerated() {
            let messages: String
            if let position = outdated.firstIndex(of: index) {
                let output = outputs[position]
                messages = output.standardError
                result.compiledSources.append(step.source)
                result.log += commandLine(plan.environment.compiler, step.arguments) + output.combinedOutput
                try record(output, for: step, in: plan)
                compileFailed = compileFailed || output.exitCode != 0
            } else {
                // Up to date: show the warnings from when it was last compiled.
                messages = (try? String(contentsOf: plan.url(for: step.object + ".log"), encoding: .utf8)) ?? ""
            }
            result.diagnostics += DiagnosticParser.parse(messages, workingDirectory: plan.projectDirectory)
        }
        result.diagnostics = Self.removingDuplicates(result.diagnostics)
        guard !compileFailed else { return result }

        // Link, if anything that goes into the firmware changed.
        if needsLink(plan, compiledAnything: !outdated.isEmpty) {
            let output = try await run(plan.environment.compiler, plan.linkArguments, in: plan, log: &result.log)
            result.diagnostics += DiagnosticParser.parse(output.standardError, workingDirectory: plan.projectDirectory)
            guard output.exitCode == 0 else {
                // A failed link can leave a broken image behind.
                try? FileManager.default.removeItem(at: plan.url(for: plan.elf))
                return result
            }
            try Self.joined(plan.linkArguments).write(to: linkArgumentsFile(plan), atomically: true, encoding: .utf8)
            result.didLink = true
        }

        // Make the raw image that gets flashed.
        let binaryExists = Self.modificationDate(plan.url(for: plan.binary)) != nil
        if result.didLink || !binaryExists {
            let output = try await run(plan.environment.objcopy, plan.objcopyArguments, in: plan, log: &result.log)
            result.diagnostics += DiagnosticParser.parse(output.standardError, workingDirectory: plan.projectDirectory)
            guard output.exitCode == 0 else { return result }
        }

        let size = try await run(plan.environment.size, plan.sizeArguments, in: plan, log: &result.log)
        result.size = ProgramSize.parse(size.standardOutput)
        result.elf = plan.url(for: plan.elf)
        result.binary = plan.url(for: plan.binary)
        result.succeeded = true
        return result
    }

    // MARK: - Compiling

    /// Compiles `steps`, several at a time, and returns their outputs in the same order.
    private func compile(_ steps: [CompileStep], in plan: BuildPlan) async throws -> [ProcessOutput] {
        let jobs = max(maxParallelJobs, 1)
        var outputs = [ProcessOutput?](repeating: nil, count: steps.count)

        try await withThrowingTaskGroup(of: (Int, ProcessOutput).self) { group in
            var next = 0
            while next < min(jobs, steps.count) {
                group.addTask { [next] in try await (next, compileOne(steps[next], in: plan)) }
                next += 1
            }
            while let (index, output) = try await group.next() {
                outputs[index] = output
                if next < steps.count {
                    group.addTask { [next] in try await (next, compileOne(steps[next], in: plan)) }
                    next += 1
                }
            }
        }
        return outputs.compactMap { $0 }
    }

    private func compileOne(_ step: CompileStep, in plan: BuildPlan) async throws -> ProcessOutput {
        try await runner.run(
            plan.environment.compiler,
            arguments: step.arguments,
            currentDirectory: plan.projectDirectory
        )
    }

    /// Saves what the next build needs to know about this compile: the flags
    /// used (to notice when they change) and the messages (to show again).
    private func record(_ output: ProcessOutput, for step: CompileStep, in plan: BuildPlan) throws {
        let arguments = plan.url(for: step.object + ".args")
        let log = plan.url(for: step.object + ".log")

        if output.exitCode == 0 {
            try Self.joined(step.arguments).write(to: arguments, atomically: true, encoding: .utf8)
            try output.standardError.write(to: log, atomically: true, encoding: .utf8)
        } else {
            // Make sure a failed file is compiled again next time.
            for url in [plan.url(for: step.object), arguments, log] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Deciding what is out of date

    func needsCompile(_ step: CompileStep, in plan: BuildPlan) -> Bool {
        guard let objectDate = Self.modificationDate(plan.url(for: step.object)) else { return true }

        let savedArguments = try? String(contentsOf: plan.url(for: step.object + ".args"), encoding: .utf8)
        guard savedArguments == Self.joined(step.arguments) else { return true }

        guard let rule = try? String(contentsOf: plan.url(for: step.dependencyFile), encoding: .utf8) else {
            return true
        }
        let dependencies = DependencyFile.dependencies(in: rule)
        guard !dependencies.isEmpty else { return true }

        // Out of date if any source or header is newer than the object, or is gone.
        return dependencies.contains { dependency in
            guard let date = Self.modificationDate(plan.url(for: dependency)) else { return true }
            return date > objectDate
        }
    }

    private func needsLink(_ plan: BuildPlan, compiledAnything: Bool) -> Bool {
        guard !compiledAnything, let elfDate = Self.modificationDate(plan.url(for: plan.elf)) else { return true }

        let savedArguments = try? String(contentsOf: linkArgumentsFile(plan), encoding: .utf8)
        guard savedArguments == Self.joined(plan.linkArguments) else { return true }

        // The linker script and libraries count as much as the objects do.
        return (plan.compileSteps.map(\.object) + plan.linkInputs).contains { input in
            guard let date = Self.modificationDate(plan.url(for: input)) else { return true }
            return date > elfDate
        }
    }

    private func linkArgumentsFile(_ plan: BuildPlan) -> URL {
        plan.url(for: "\(BuildPlan.buildDirectoryName)/link.args")
    }

    private static func modificationDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes?[.modificationDate] as? Date
    }

    /// Arguments as one string, for comparing with what was used last time.
    private static func joined(_ arguments: [String]) -> String {
        arguments.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func prepareDirectories(for plan: BuildPlan) throws {
        let directories = Set(plan.compileSteps.map { plan.url(for: $0.object).deletingLastPathComponent() })
            .union([plan.url(for: plan.elf).deletingLastPathComponent()])
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Writes `build/compile_commands.json`, the standard file that tells
    /// `clangd` how each source is compiled.
    private func writeCompileCommands(for plan: BuildPlan) throws {
        let compiler = plan.environment.compiler.path(percentEncoded: false)
        let entries: [[String: Any]] = plan.compileSteps.map { step in
            [
                "directory": plan.projectDirectory.path(percentEncoded: false),
                "file": step.source,
                "arguments": [compiler] + step.arguments,
                "output": step.object
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let url = plan.url(for: "\(BuildPlan.buildDirectoryName)/compile_commands.json")
        // Only rewrite it when it changes, so clangd does not re-index for nothing.
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
    }

    private func run(
        _ tool: URL,
        _ arguments: [String],
        in plan: BuildPlan,
        log: inout String
    ) async throws -> ProcessOutput {
        let output = try await runner.run(tool, arguments: arguments, currentDirectory: plan.projectDirectory)
        log += commandLine(tool, arguments) + output.combinedOutput
        return output
    }

    /// The command as the user would type it, for the build log.
    private func commandLine(_ tool: URL, _ arguments: [String]) -> String {
        let words = [tool.lastPathComponent] + arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }
        return "$ " + words.joined(separator: " ") + "\n"
    }

    private static func removingDuplicates(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        var seen = Set<Diagnostic>()
        return diagnostics.filter { seen.insert($0).inserted }
    }
}
