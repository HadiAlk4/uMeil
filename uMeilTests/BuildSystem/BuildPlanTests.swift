import Foundation
import Testing
@testable import uMeil

struct DependencyFileTests {
    @Test func readsASimpleRule() {
        #expect(DependencyFile.dependencies(in: "build/warn.o: src/warn.c\n") == ["src/warn.c"])
    }

    @Test func joinsContinuedLinesAndSkipsTheExtraRulesFromMP() {
        let text = """
        build/obj/src/main.c.o: src/main.c src/board.h \\
         /sdk/inc/hw_memmap.h \\
         /sdk/driverlib/gpio.h
        src/board.h:
        /sdk/inc/hw_memmap.h:
        """

        #expect(DependencyFile.dependencies(in: text) == [
            "src/main.c", "src/board.h", "/sdk/inc/hw_memmap.h", "/sdk/driverlib/gpio.h"
        ])
    }

    @Test func handlesEscapedSpacesAndDollarSigns() {
        let text = "build/obj/a.o: src/my\\ file.c /Users/me/Application\\ Support/x.h src/cost$$.h\n"

        #expect(DependencyFile.dependencies(in: text) == [
            "src/my file.c", "/Users/me/Application Support/x.h", "src/cost$.h"
        ])
    }

    @Test func givesNothingForTextThatIsNotARule() {
        #expect(DependencyFile.dependencies(in: "").isEmpty)
        #expect(DependencyFile.dependencies(in: "not a rule at all\n").isEmpty)
        #expect(DependencyFile.dependencies(in: "target-only:\n").isEmpty)
    }
}

struct ProgramSizeTests {
    @Test func parsesSizeOutput() {
        let output = """
           text\t   data\t    bss\t    dec\t    hex\tfilename
           1396\t      8\t     16\t   1420\t    58c\tbuild/Blinky.elf
        """

        let size = ProgramSize.parse(output)

        #expect(size == ProgramSize(text: 1396, data: 8, bss: 16))
        #expect(size?.flash == 1404) // code plus the starting values of variables
        #expect(size?.ram == 24)
    }

    @Test func givesNothingForUnexpectedOutput() {
        #expect(ProgramSize.parse("") == nil)
        #expect(ProgramSize.parse("size: 'nope.elf': No such file\n") == nil)
    }
}

struct BuildPlanTests {
    private let directory = URL(filePath: "/Users/me/Blinky", directoryHint: .isDirectory)
    private let environment = BuildEnvironment(
        compiler: URL(filePath: "/tools/bin/arm-none-eabi-gcc"),
        tivaWareDirectory: URL(filePath: "/app/TivaWare.bundle", directoryHint: .isDirectory)
    )

    private func project(useDriverLib: Bool = true) -> Project {
        Project(
            name: "Blinky",
            target: .init(chip: .tm4c1294ncpdt, board: .ekTM4C1294XL),
            sources: ["src/main.c", "startup/startup.c"],
            includePaths: ["src"],
            build: .init(
                cStandard: "gnu11",
                optimization: .debug,
                defines: ["DEBUG=1"],
                compilerFlags: ["-Wall", "-Wextra"],
                linkerFlags: ["-lm"],
                linkerScript: "tm4c1294ncpdt.ld",
                useDriverLib: useDriverLib
            )
        )
    }

    @Test func compilesEachSourceWithTheChipAndProjectSettings() {
        let plan = BuildPlan(project: project(), projectDirectory: directory, environment: environment)

        #expect(plan.compileSteps.map(\.source) == ["src/main.c", "startup/startup.c"])
        #expect(plan.compileSteps[0].object == "build/obj/src/main.c.o")
        #expect(plan.compileSteps[0].dependencyFile == "build/obj/src/main.c.o.d")
        #expect(plan.compileSteps[0].arguments == [
            "-mcpu=cortex-m4", "-mthumb", "-mfpu=fpv4-sp-d16", "-mfloat-abi=hard",
            "-std=gnu11", "-Og", "-g", "-ffunction-sections", "-fdata-sections",
            "-fdiagnostics-color=never", "-fdiagnostics-column-unit=byte",
            "-DPART_TM4C1294NCPDT", "-DDEBUG=1",
            "-Isrc", "-I/app/TivaWare.bundle/",
            "-Wall", "-Wextra",
            "-MMD", "-MP", "-MF", "build/obj/src/main.c.o.d",
            "-c", "src/main.c", "-o", "build/obj/src/main.c.o"
        ])
    }

    @Test func linksTheObjectsWithDriverLibAndTheProjectsFlagsLast() {
        let plan = BuildPlan(project: project(), projectDirectory: directory, environment: environment)

        #expect(plan.linkArguments == [
            "-mcpu=cortex-m4", "-mthumb", "-mfpu=fpv4-sp-d16", "-mfloat-abi=hard",
            "-nostartfiles", "--specs=nano.specs", "--specs=nosys.specs",
            "-Wl,--gc-sections", "-Wl,-Map=build/Blinky.map",
            "-T", "tm4c1294ncpdt.ld",
            "build/obj/src/main.c.o", "build/obj/startup/startup.c.o",
            "/app/TivaWare.bundle/driverlib/libdriver.a",
            "-lm",
            "-o", "build/Blinky.elf"
        ])
        #expect(plan.linkInputs == ["tm4c1294ncpdt.ld", "/app/TivaWare.bundle/driverlib/libdriver.a"])
        #expect(plan.objcopyArguments == ["-O", "binary", "build/Blinky.elf", "build/Blinky.bin"])
        #expect(plan.sizeArguments == ["build/Blinky.elf"])
    }

    @Test func leavesTivaWareOutWhenTheProjectDoesNotUseIt() {
        let project = project(useDriverLib: false)
        let plan = BuildPlan(project: project, projectDirectory: directory, environment: environment)

        #expect(!plan.compileSteps[0].arguments.contains { $0.contains("TivaWare") })
        #expect(!plan.linkArguments.contains { $0.contains("TivaWare") })
        #expect(plan.linkInputs == ["tm4c1294ncpdt.ld"])
    }

    @Test func givesSourcesWithTheSameFileNameDifferentObjects() {
        var project = project()
        project.sources = ["src/main.c", "lib/main.c", "../shared/util.c"]

        let plan = BuildPlan(project: project, projectDirectory: directory, environment: environment)

        #expect(plan.compileSteps.map(\.object) == [
            "build/obj/src/main.c.o",
            "build/obj/lib/main.c.o",
            // Still inside the build folder, even though the source is outside the project.
            "build/obj/__/shared/util.c.o"
        ])
    }

    @Test func namesTheOutputsAfterTheProject() {
        var project = project()
        project.name = "Motor Control"

        let plan = BuildPlan(project: project, projectDirectory: directory, environment: environment)

        #expect(plan.elf == "build/Motor Control.elf")
        #expect(plan.binary == "build/Motor Control.bin")
        #expect(plan.url(for: plan.elf).path == "/Users/me/Blinky/build/Motor Control.elf")
        #expect(plan.url(for: "/abs/lib.a").path == "/abs/lib.a")
    }

    @Test func findsTheOtherToolsNextToTheCompiler() {
        #expect(environment.objcopy.path == "/tools/bin/arm-none-eabi-objcopy")
        #expect(environment.size.path == "/tools/bin/arm-none-eabi-size")
    }

    @Test func clangdArgumentsOmitGCCOnlyDiagnosticAndDependencyFlags() {
        let plan = BuildPlan(project: project(), projectDirectory: directory, environment: environment)

        #expect(plan.compileSteps[0].clangdArguments == [
            "-mcpu=cortex-m4", "-mthumb", "-mfpu=fpv4-sp-d16", "-mfloat-abi=hard",
            "-std=gnu11", "-Og", "-g", "-ffunction-sections", "-fdata-sections",
            "-DPART_TM4C1294NCPDT", "-DDEBUG=1",
            "-Isrc", "-I/app/TivaWare.bundle/",
            "-Wall", "-Wextra",
            "-c", "src/main.c", "-o", "build/obj/src/main.c.o"
        ])
    }

    @Test func sanitizesProjectFileNameAgainstTraversalAndControlChars() {
        #expect(BuildPlan.fileName(for: "Motor Control") == "Motor Control")
        #expect(BuildPlan.fileName(for: "a/b:c\\d\ne\rf\0g\u{7F}") == "a_b_c_d_e_f_g_")
        #expect(BuildPlan.fileName(for: "..--..Blinky") == "Blinky")
        #expect(BuildPlan.fileName(for: "---...") == "firmware")
        #expect(BuildPlan.fileName(for: "") == "firmware")
    }

    @Test func validatesSafeProjectSettings() throws {
        let temp = try TemporaryFolder()
        for standard in ["c89", "gnu89", "c90", "gnu90", "c99", "gnu99", "c11", "gnu11",
                         "c17", "c18", "gnu17", "gnu18", "c2x", "gnu2x", "c23", "gnu23"] {
            var candidate = project()
            candidate.build.cStandard = standard
            try BuildPlan.validate(candidate, in: temp.url)
        }

        let libsDir = temp.url.appending(path: "libs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: libsDir, withIntermediateDirectories: true)
        var withSafeFlags = project()
        withSafeFlags.includePaths = [".", "src"]
        withSafeFlags.build.compilerFlags = ["-Wall", "-Wextra", "-O2", "-Isrc"]
        withSafeFlags.build.linkerFlags = ["-Llibs", "-L", "libs", "-lm", "-Wl,--gc-sections"]
        try BuildPlan.validate(withSafeFlags, in: temp.url)
    }

    @Test func rejectsUnsafeCStandardsDefinesAndPaths() throws {
        let temp = try TemporaryFolder()
        let outside = try TemporaryFolder()
        try FileManager.default.createSymbolicLink(
            at: temp.url.appending(path: "escape"),
            withDestinationURL: outside.url
        )

        for badStd in ["", "c98", "gnu11 -wrapper /bin/sh", "c11\n-o /tmp/pwn"] {
            var candidate = project()
            candidate.build.cStandard = badStd
            #expect(throws: BuildError.self) { try BuildPlan.validate(candidate, in: temp.url) }
        }

        for badDefine in ["", "   ", "FOO\nBAR", "FOO\0BAR"] {
            var candidate = project()
            candidate.build.defines = [badDefine]
            #expect(throws: BuildError.self) { try BuildPlan.validate(candidate, in: temp.url) }
        }

        for badPath in ["-o", "@resp.txt", "../outside.c", "/etc/passwd", "escape/a.c", "a\nb.c", "a\0b.c", "."] {
            var badSource = project()
            badSource.sources = [badPath]
            #expect(throws: BuildError.self) { try BuildPlan.validate(badSource, in: temp.url) }

            var badLinker = project()
            badLinker.build.linkerScript = badPath
            #expect(throws: BuildError.self) { try BuildPlan.validate(badLinker, in: temp.url) }
        }

        for badInc in ["-I/etc", "@resp.txt", "../outside", "/etc", "escape", "inc\n-o"] {
            var badInclude = project()
            badInclude.includePaths = [badInc]
            #expect(throws: BuildError.self) { try BuildPlan.validate(badInclude, in: temp.url) }
        }
    }

    @Test func rejectsDangerousCompilerAndLinkerFlags() throws {
        let temp = try TemporaryFolder()
        let outside = try TemporaryFolder()
        try FileManager.default.createSymbolicLink(
            at: temp.url.appending(path: "escape"),
            withDestinationURL: outside.url
        )

        let dangerousCompilerFlags: [[String]] = [
            ["@evil.rsp"], ["-Wall\n-o/tmp/pwn"], ["-Wall\0"], ["/etc/passwd"],
            ["-wrapper"], ["-B."], ["-B/tmp"], ["-fplugin=evil.so"], ["--plugin=evil.so"],
            ["-specs=evil.specs"], ["--specs=nano.specs"], ["-fuse-ld=lld"],
            ["-o", "/tmp/pwn"], ["-o/tmp/pwn"], ["-MF", "/tmp/d"], ["-MF/tmp/d"],
            ["-MTtarget"], ["-MQtarget"], ["-MD"], ["-MMD"],
            ["-imacros", "/etc/passwd"], ["-include", "/etc/passwd"], ["-include/etc/passwd"],
            ["-dumpbase", "x"], ["-auxbase", "x"], ["-fprofile-generate=/tmp"],
            ["-save-temps=cwd"], ["-T", "x.ld"], ["-Xlinker", "-o"],
            ["-Xpreprocessor", "-MF"], ["-Xassembler", "-o"],
            ["--sysroot=/tmp"], ["-isysroot/tmp"], ["-I../outside"], ["-I", "../outside"],
            ["-Iescape"], ["-Wp,-MD,/tmp/pwn"], ["-Wa,@evil.rsp"]
        ]
        for flags in dangerousCompilerFlags {
            var candidate = project()
            candidate.build.compilerFlags = flags
            #expect(throws: BuildError.self, "Expected compilerFlags \(flags) to fail") {
                try BuildPlan.validate(candidate, in: temp.url)
            }
        }

        let dangerousLinkerFlags: [[String]] = [
            ["@evil.rsp"], ["-lm\n-o/tmp/pwn"], ["-lm\0"], ["/tmp/evil.o"],
            ["-Wl,-Map=evil.map"], ["-Wl,-Map,evil.map"], ["-Wl,--plugin=evil.so"],
            ["-Wl,--plugin,evil.so"], ["-Wl,--dependency-file=evil.d"], ["-Wl,-o,evil.elf"],
            ["-Wl,-o=evil.elf"], ["-Wl,@evil.rsp"], ["-Wl,-T,evil.ld"],
            ["-Wl,-L/tmp"], ["-Wl,-L,../outside"], ["-Wl,--library-path=/tmp"],
            ["-L/tmp"], ["-L", "../outside"], ["-Lescape"], ["-L", "escape"],
            ["-T", "evil.ld"], ["-o/tmp/pwn"], ["-Xlinker", "-Map=evil.map"],
            ["-l:/tmp/evil.a"]
        ]
        for flags in dangerousLinkerFlags {
            var candidate = project()
            candidate.build.linkerFlags = flags
            #expect(throws: BuildError.self, "Expected linkerFlags \(flags) to fail") {
                try BuildPlan.validate(candidate, in: temp.url)
            }
        }
    }
}
