import Foundation
import Testing
@testable import uMeil

enum BuildTestEnvironment {
    /// Whether tests that need a real compiler should run.
    static let canBuild = ProcessInfo.processInfo.environment["UMEIL_REQUIRE_TOOLS"] == "1"
        || ToolLocator.standard().locate(.compiler) != nil
}

/// Builds real projects with the real compiler.
///
/// Skipped when no compiler is installed, so the suite still passes on a Mac
/// without a toolchain. CI installs one and sets `UMEIL_REQUIRE_TOOLS=1`,
/// which turns a missing compiler into a failure.
@Suite(.enabled(if: BuildTestEnvironment.canBuild))
struct BuildEngineTests {
    /// A new Blinky project in a scratch folder, and the plan to build it.
    private func makeBlinky(in folder: TemporaryFolder) throws -> (projectFile: URL, plan: BuildPlan) {
        let template = try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
        let projectFile = try template.createProject(named: "Blinky", in: folder.url)
        return (projectFile, try BuildEngine.plan(forProjectFile: projectFile))
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// Sets a file's modification date to now, as saving it in an editor would.
    private func touch(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func exists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    // MARK: - A clean build

    @Test func buildsBlinkyIntoFirmware() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)

        let result = try await BuildEngine().build(plan)

        #expect(result.succeeded, "Build failed:\n\(result.log)")
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(result.compiledSources == ["src/main.c", "startup/startup.c"])
        #expect(result.didLink)
        #expect(exists(result.elf))
        #expect(exists(result.binary))
        #expect(exists(plan.url(for: plan.map)))

        // The image must fit the chip and actually contain code.
        let size = try #require(result.size)
        #expect(size.text > 200)
        #expect(size.flash < 1024 * 1024)
        #expect(size.ram < 256 * 1024)

        // The same bytes, split the way Keil reports them.
        let sections = try #require(result.sections)
        #expect(sections.code > 200)
        #expect(sections.code + sections.readOnlyData == size.text)
        #expect(sections.readWriteData == size.data)
        #expect(sections.zeroInitializedData == size.bss)
        #expect(result.log.contains(sections.keilSummary))
    }

    @Test func constantsAreReportedAsReadOnlyData() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        let main = plan.projectDirectory.appending(path: "src/main.c")
        let before = try #require(try await BuildEngine().build(plan).sections)

        // A 400-byte table of constants that the program reads. It has to be
        // used, or the linker leaves it out.
        var source = try String(contentsOf: main, encoding: .utf8)
        source = """
        const unsigned char table[400] = { 1, 2, 3 };
        volatile unsigned int tableIndex;

        """ + source.replacing("int main(void)\n{\n", with: "int main(void)\n{\n    tableIndex = table[tableIndex];\n")
        #expect(source.contains("tableIndex = table[tableIndex];"))
        try source.write(to: main, atomically: true, encoding: .utf8)
        let after = try #require(try await BuildEngine().build(plan).sections)

        #expect(after.readOnlyData - before.readOnlyData == 400)
        #expect(after.code - before.code < 100)
        #expect(after.zeroInitializedData - before.zeroInitializedData == 4)
    }

    @Test func theImageStartsWithAValidVectorTable() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)

        let result = try await BuildEngine().build(plan)
        let image = try Data(contentsOf: try #require(result.binary))

        func word(at offset: Int) -> UInt32 {
            image.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        // Word 0 is the initial stack pointer: the top of the chip's 256 KB of RAM.
        #expect(word(at: 0) == 0x2004_0000)
        // Word 1 is the reset handler: an address in flash with the Thumb bit set.
        let reset = word(at: 4)
        #expect(reset & 1 == 1)
        #expect(reset < 0x0010_0000)
        #expect(Int(reset) < image.count)
    }

    @Test func writesCompileCommandsForClangd() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)

        _ = try await BuildEngine().build(plan)

        let data = try Data(contentsOf: plan.url(for: "build/compile_commands.json"))
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(entries.compactMap { $0["file"] as? String } == ["src/main.c", "startup/startup.c"])
        let arguments = try #require(entries.first?["arguments"] as? [String])
        #expect(arguments.first == plan.environment.compiler.path)
        #expect(arguments.contains("-DPART_TM4C1294NCPDT"))
    }

    // MARK: - Incremental builds

    @Test func aSecondBuildDoesNothing() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        _ = try await BuildEngine().build(plan)

        let second = try await BuildEngine().build(plan)

        #expect(second.succeeded)
        #expect(second.compiledSources.isEmpty)
        #expect(!second.didLink)
        #expect(exists(second.binary))
    }

    @Test func changingOneSourceRecompilesOnlyThatSource() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        _ = try await BuildEngine().build(plan)

        try touch(plan.url(for: "src/main.c"))
        let second = try await BuildEngine().build(plan)

        #expect(second.succeeded)
        #expect(second.compiledSources == ["src/main.c"])
        #expect(second.didLink)
    }

    @Test func changingAHeaderRecompilesTheSourcesThatIncludeIt() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        let header = plan.url(for: "src/board.h")
        let main = plan.url(for: "src/main.c")
        try write("#define BLINK_PIN GPIO_PIN_1\n", to: header)
        try write("#include \"board.h\"\n" + String(contentsOf: main, encoding: .utf8), to: main)
        _ = try await BuildEngine().build(plan)

        try touch(header)
        let second = try await BuildEngine().build(plan)

        // startup.c does not include the header, so it is left alone.
        #expect(second.compiledSources == ["src/main.c"])
    }

    @Test func changingCompilerSettingsRecompilesEverything() async throws {
        let folder = try TemporaryFolder()
        let (projectFile, plan) = try makeBlinky(in: folder)
        _ = try await BuildEngine().build(plan)

        var project = try ProjectFile.load(from: projectFile)
        project.build.optimization = .size
        try ProjectFile.save(project, to: projectFile)
        let second = try await BuildEngine().build(try BuildEngine.plan(forProjectFile: projectFile))

        #expect(second.compiledSources == ["src/main.c", "startup/startup.c"])
        #expect(second.didLink)
    }

    @Test func changingTheLinkerScriptOnlyLinksAgain() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        _ = try await BuildEngine().build(plan)

        try touch(plan.url(for: "tm4c1294ncpdt.ld"))
        let second = try await BuildEngine().build(plan)

        #expect(second.compiledSources.isEmpty)
        #expect(second.didLink)
    }

    @Test func warningsAreStillReportedWhenNothingIsRecompiled() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        let main = plan.url(for: "src/main.c")
        try write(try String(contentsOf: main, encoding: .utf8) + "\nstatic int never_used;\n", to: main)
        let first = try await BuildEngine().build(plan)
        #expect(first.diagnostics.contains { $0.message.contains("never_used") })

        let second = try await BuildEngine().build(plan)

        #expect(second.compiledSources.isEmpty)
        #expect(second.diagnostics.contains { $0.severity == .warning && $0.message.contains("never_used") })
    }

    // MARK: - Broken projects

    @Test func reportsACompileErrorWithItsFileAndLine() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        let main = plan.url(for: "src/main.c")
        try write("int main(void) {\n    return missing_variable;\n}\n", to: main)

        let result = try await BuildEngine().build(plan)

        #expect(!result.succeeded)
        #expect(!result.didLink)
        #expect(result.elf == nil)
        let error = try #require(result.diagnostics.first { $0.severity == .error })
        #expect(error.message.contains("missing_variable"))
        #expect(error.file?.lastPathComponent == "main.c")
        #expect(error.file?.resolvingSymlinksInPath() == main.resolvingSymlinksInPath())
        #expect(error.line == 2)
        #expect(error.column == 12)
    }

    @Test func aFixedErrorBuildsAgain() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        let main = plan.url(for: "src/main.c")
        let original = try String(contentsOf: main, encoding: .utf8)
        try write("this is not C\n", to: main)
        let broken = try await BuildEngine().build(plan)
        #expect(!broken.succeeded)

        try write(original, to: main)
        let fixed = try await BuildEngine().build(plan)

        #expect(fixed.succeeded)
        // startup.c compiled fine the first time and is not compiled again.
        #expect(fixed.compiledSources == ["src/main.c"])
    }

    @Test func reportsALinkErrorAndLeavesNoImageBehind() async throws {
        let folder = try TemporaryFolder()
        let (_, plan) = try makeBlinky(in: folder)
        _ = try await BuildEngine().build(plan)
        let main = plan.url(for: "src/main.c")
        let code = "extern int not_defined_anywhere(void);\nint main(void) { return not_defined_anywhere(); }\n"
        try write(code, to: main)

        let result = try await BuildEngine().build(plan)

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains {
            $0.severity == .error && $0.message.contains("undefined reference to `not_defined_anywhere'")
        })
        // The image from the earlier good build must not be mistaken for this one.
        #expect(!exists(plan.url(for: plan.elf)))
    }

    @Test func reportsASourceFileThatDoesNotExist() async throws {
        let folder = try TemporaryFolder()
        let (projectFile, _) = try makeBlinky(in: folder)
        var project = try ProjectFile.load(from: projectFile)
        project.sources.append("src/gone.c")
        try ProjectFile.save(project, to: projectFile)

        let result = try await BuildEngine().build(try BuildEngine.plan(forProjectFile: projectFile))

        #expect(!result.succeeded)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.message.contains("src/gone.c") })
    }

    @Test func failsClearlyWhenThereIsNoCompiler() throws {
        let folder = try TemporaryFolder()
        let (projectFile, _) = try makeBlinky(in: folder)
        let nowhere = ToolLocator(searchDirectories: [folder.url])

        #expect(throws: BuildError.compilerNotFound) {
            try BuildEngine.plan(forProjectFile: projectFile, locator: nowhere)
        }
    }
}
