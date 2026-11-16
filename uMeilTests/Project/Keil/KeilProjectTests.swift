import Foundation
import Testing
@testable import uMeil

struct KeilProjectTests {
    @Test func readsTheFirstTargetOfAProjectFile() throws {
        let keil = try KeilProject.parse(Data(KeilFixture.projectFile(device: "TM4C1294NCPDT").utf8))

        #expect(keil.outputName == "Template")
        #expect(keil.targetName == "Target 1")
        #expect(keil.device == "TM4C1294NCPDT")
        #expect(keil.optimizationLevel == 1)
        #expect(keil.languageLevel == 5)
        // The C compiler's settings, not the assembler's.
        #expect(keil.defines == ["LAB=4", "USE_SERIAL"])
        #expect(keil.includePaths == ["inc", "C:/Course/Common"])
        // old.c is in the project but switched off for the build.
        #expect(keil.files == [
            .init(path: "main.c", kind: .cSource),
            .init(path: "Lib4.h", kind: .header),
            .init(path: "Lib4.lib", kind: .library)
        ])
        #expect(keil.packFiles == [
            "RTE/Device/TM4C1294NCPDT/startup_TM4C129.s",
            "RTE/Device/TM4C1294NCPDT/system_TM4C129.c"
        ])
    }

    @Test func refusesFilesThatAreNotKeilProjects() {
        #expect(throws: KeilImportError.notAKeilProject) {
            try KeilProject.parse(Data("{ \"formatVersion\": 1 }".utf8))
        }
        #expect(throws: KeilImportError.notAKeilProject) {
            try KeilProject.parse(Data("<Project><Targets/></Project>".utf8))
        }
    }

    @Test func turnsWindowsPathsIntoPortableOnes() {
        #expect(KeilProject.portablePath(#".\main.c"#) == "main.c")
        #expect(KeilProject.portablePath(#".\src\drivers\uart.c"#) == "src/drivers/uart.c")
        #expect(KeilProject.portablePath(#"..\common\lib.c"#) == "../common/lib.c")
        #expect(KeilProject.portablePath("RTE/Device/system.c") == "RTE/Device/system.c")
        #expect(KeilProject.portablePath(".") == ".")
        #expect(KeilProject.portablePath("") == "")

        #expect(KeilProject.isWindowsAbsolute("C:/Keil_v5/ARM/Packs"))
        #expect(!KeilProject.isWindowsAbsolute("../common"))
    }
}

struct KeilStartupTests {
    @Test func readsTheVectorTableOfAKeilStartupFile() throws {
        let names = try #require(KeilStartup.vectorNames(inKeilStartup: KeilFixture.keilStartup))

        #expect(names.count == 20)
        #expect(names[0] == "__initial_sp")
        #expect(names[1] == "Reset_Handler")
        #expect(names[7] == nil)
        #expect(names[15] == "SysTick_Handler")
        #expect(names[16...] == ["GPIOA_Handler", "GPIOB_Handler", nil, "UART0_Handler"])
    }

    @Test func givesNothingForAFileWithoutAVectorTable() {
        #expect(KeilStartup.vectorNames(inKeilStartup: "") == nil)
        #expect(KeilStartup.vectorNames(inKeilStartup: "int main(void) { return 0; }\n") == nil)
        // The words appear, but only in a comment.
        #expect(KeilStartup.vectorNames(inKeilStartup: "; __Vectors DCD Reset_Handler\n") == nil)
    }

    @Test func theGNUStartupKeepsTheHandlerNamesAndFillsTheRestOfTheTable() throws {
        let names = try #require(KeilStartup.vectorNames(inKeilStartup: KeilFixture.keilStartup))

        let source = KeilStartup.gnuSource(vectors: names, interruptCount: 114, basedOn: "startup_TM4C129.s")

        #expect(source.contains("written by uMeil from the vector table in startup_TM4C129.s"))
        #expect(source.contains("const vector_t vector_table[130] = {"))
        #expect(source.contains(#"void SysTick_Handler(void) __attribute__((weak, alias("Default_Handler")));"#))
        #expect(source.contains(#"void UART0_Handler(void) __attribute__((weak, alias("Default_Handler")));"#))
        // Defined in the file itself, so they must not also be aliases.
        #expect(!source.contains("void Reset_Handler(void) __attribute__"))
        #expect(!source.contains("void Default_Handler(void) __attribute__"))
        #expect(!source.contains("__initial_sp"))

        let entries = source.split(whereSeparator: \.isNewline).map(String.init)
        let first = try #require(entries.firstIndex(of: "    (vector_t)&__stack_top,"))
        #expect(entries[first + 1] == "    Reset_Handler,")
        #expect(entries[first + 7] == "    0,")
        #expect(entries[first + 15] == "    SysTick_Handler,")
        #expect(entries[first + 16] == "    GPIOA_Handler, // Interrupt 0")
        #expect(entries[first + 18] == "    0, // Interrupt 2")
        #expect(entries[first + 19] == "    UART0_Handler, // Interrupt 3")
        #expect(entries[first + 20] == "    Default_Handler, // Interrupt 4")
        #expect(entries[first + 129] == "    Default_Handler, // Interrupt 113")
        #expect(entries[first + 130] == "};")
    }
}
