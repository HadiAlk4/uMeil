import Foundation
import Testing
@testable import uMeil

struct KeilCourseLibraryTests {
    /// An `ar` archive with a System V symbol table naming `symbols`, laid
    /// out the way Arm's `armar` writes the course libraries.
    static func archive(symbols: [String]) -> Data {
        var table = Data()
        let count = UInt32(symbols.count)
        table.append(contentsOf: withUnsafeBytes(of: count.bigEndian, Array.init))
        for _ in symbols {
            table.append(contentsOf: [0, 0, 0, 0x50])
        }
        for symbol in symbols {
            table.append(contentsOf: Array(symbol.utf8) + [0])
        }
        func field(_ text: String, _ width: Int) -> String {
            text.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        let header = field("/", 16) + field("0", 12) + field("0", 6) + field("0", 6) + field("0", 8)
            + field("\(table.count)", 10) + "`\n"
        var data = Data("!<arch>\n".utf8)
        data.append(Data(header.utf8))
        data.append(table)
        if table.count % 2 == 1 {
            data.append(0x0A)
        }
        data.append(Data("lab.o/          0           0     0     0       4         `\n.ORC".utf8))
        return data
    }

    @Test func readsTheSymbolTableOfAnArmCompilerLibrary() {
        let symbols = ["Setup_UART", "PK2_3Hz_Clock", "TIMER0A_Handler", "Uvalues"]
        #expect(KeilCourseLibrary.symbols(inArchive: Self.archive(symbols: symbols)) == Set(symbols))
        #expect(KeilCourseLibrary.symbols(inArchive: Data("!<arch>\nnot a library\n".utf8)) == nil)
        #expect(KeilCourseLibrary.symbols(inArchive: Data("hello".utf8)) == nil)
    }

    @Test func knowsEachLabLibraryByName() throws {
        let lab1A = try #require(KeilCourseLibrary.symbols(forLibraryNamed: "Lab1A.lib"))
        let lab2 = try #require(KeilCourseLibrary.symbols(forLibraryNamed: "Lab2_Wed.lib"))
        let lab3 = try #require(KeilCourseLibrary.symbols(forLibraryNamed: "lib3.lib"))
        let lab4 = try #require(KeilCourseLibrary.symbols(forLibraryNamed: "Lib4.lib"))
        #expect(lab1A.contains("writePFData"))
        #expect(lab2.contains("RedirectOutput"))
        #expect(lab3.contains("PK2_3Hz_Clock"))
        #expect(lab4.contains("readDec"))
        for symbols in [lab1A, lab2, lab3, lab4] {
            #expect(KeilCourseLibrary.missing(from: symbols).isEmpty)
        }
        #expect(KeilCourseLibrary.symbols(forLibraryNamed: "Other.lib") == nil)
    }

    @Test func reportsFunctionsItCannotStandInFor() {
        #expect(KeilCourseLibrary.missing(from: ["msDelay", "Uvalues", "Read_Num"]) == ["Read_Num"])
        #expect(!KeilCourseLibrary.coversAny(of: ["arm_fir_f32"]))
    }

    /// Interrupt handlers cannot be weak, so they are only written when the
    /// library being replaced has them. Otherwise a lab that defines its own
    /// `TIMER0A_Handler` would not link.
    @Test func onlyWritesInterruptHandlersTheLibraryHas() throws {
        let lab4 = try #require(KeilCourseLibrary.symbols(forLibraryNamed: "Lib4.lib"))
        let lab4Source = KeilCourseLibrary.source(providing: lab4)
        #expect(!lab4Source.contains("TIMER0A_Handler"))
        #expect(!lab4Source.contains("UART0_Handler"))

        let lab3Source = KeilCourseLibrary.source(providing: KeilCourseLibrary.lab3Symbols)
        #expect(lab3Source.contains("void TIMER0A_Handler(void)"))
        #expect(lab3Source.contains("ES_WEAK void Setup_UART(void)"))

        let lab2Source = KeilCourseLibrary.source(providing: KeilCourseLibrary.lab2WednesdaySymbols)
        #expect(lab2Source.contains("void UART4_Handler(void)"))
        #expect(lab2Source.contains("ES_WEAK void setup_UART(void)"))
    }

    @Test func importingUsesTheLibrarysOwnSymbolTable() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        try Self.archive(symbols: ["Setup_UART", "PK2_3Hz_Clock", "Read_Num"])
            .write(to: folder.url.appending(path: "Lib4.lib"))

        let result = try KeilImporter.importProject(at: keilFile)

        let library = try String(contentsOf: folder.url.appending(path: "uMeil/es_lib.c"), encoding: .utf8)
        #expect(library.contains("void TIMER0A_Handler(void)"))
        #expect(result.notes.contains { $0.contains("does not provide Read_Num") })
    }

    @Test func anUnknownLibraryIsLeftOut() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        try Self.archive(symbols: ["arm_fir_f32"]).write(to: folder.url.appending(path: "Lib4.lib"))

        let result = try KeilImporter.importProject(at: keilFile)

        #expect(!result.project.sources.contains("uMeil/es_lib.c"))
        #expect(result.notes.contains { $0.contains("Lib4.lib was left out") })
    }

    /// The labs replace library functions with their own of the same name;
    /// that must link, as it does in Keil. Builds a Lab 3 style project that
    /// writes its own `Setup_UART` and still uses the library's square wave.
    @Test(.enabled(if: BuildTestEnvironment.canBuild))
    func aLabsOwnFunctionReplacesTheLibrarysWhenBuilt() async throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        try Self.archive(symbols: Array(KeilCourseLibrary.lab3Symbols))
            .write(to: folder.url.appending(path: "Lib4.lib"))
        try """
            #include <TM4C129.h>
            #include <stdbool.h>

            extern void PK2_3Hz_Clock(void);
            extern void Write_UART(char c);

            #define GPIOG GPIOG_AHB

            volatile char letter = 'A';

            void Setup_UART(void)
            {
                SYSCTL->RCGCUART |= 1u;
            }

            void GPIOG_Handler(void)
            {
                GPIOG->ICR = 1u;
                letter = letter == 'Z' ? 'A' : letter + 1;
            }

            int main(void)
            {
                Setup_UART();
                PK2_3Hz_Clock();
                while (true) {
                    Write_UART(letter);
                    __ASM("nop");
                }
            }

            """.write(to: folder.url.appending(path: "main.c"), atomically: true, encoding: .utf8)
        let imported = try KeilImporter.importProject(at: keilFile)

        let result = try await BuildEngine().build(try BuildEngine.plan(forProjectFile: imported.projectFile))

        #expect(result.succeeded, "Build failed:\n\(result.log)")
        #expect(!result.log.contains("redefined"), "\(result.log)")
    }
}
