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
}
