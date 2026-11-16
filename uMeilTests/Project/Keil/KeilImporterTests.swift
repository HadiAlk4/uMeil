import AppKit
import Foundation
import Testing
@testable import uMeil

struct KeilImporterTests {
    @Test func findsTheKeilProjectFileInAFolder() throws {
        let folder = try TemporaryFolder()
        #expect(KeilImporter.keilProjectFile(in: folder.url) == nil)

        let keilFile = try KeilFixture.make(in: folder.url)
        #expect(KeilImporter.keilProjectFile(in: folder.url)?.lastPathComponent == keilFile.lastPathComponent)
    }

    @Test func importsAKeilProjectAlongsideItsOwnFiles() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        let keilStartupPath = "RTE/Device/TM4C1294NCPDT/startup_TM4C129.s"
        let startupBefore = try Data(contentsOf: folder.url.appending(path: keilStartupPath))

        let result = try KeilImporter.importProject(at: keilFile)

        #expect(result.projectFile.lastPathComponent == "Template.umeil")
        #expect(try ProjectFile.load(from: result.projectFile) == result.project)
        #expect(result.project.name == "Template")
        #expect(result.project.target == .init(chip: .tm4c1294ncpdt, board: .ekTM4C1294XL))
        #expect(result.project.sources == [
            "main.c",
            "RTE/Device/TM4C1294NCPDT/system_TM4C129.c",
            "uMeil/startup_gcc.c"
        ])
        #expect(result.project.includePaths == [
            ".",
            "inc",
            "RTE/Device/TM4C1294NCPDT",
            "RTE/_Target_1"
        ])
        #expect(result.project.build == .init(
            cStandard: "c11",
            optimization: .none,
            defines: ["LAB=4", "USE_SERIAL"],
            compilerFlags: ["-Wall"],
            linkerFlags: [],
            linkerScript: "uMeil/tm4c1294ncpdt.ld",
            useDriverLib: false
        ))

        // Keil's own startup file is still there, byte for byte.
        let startupAfter = try Data(contentsOf: folder.url.appending(path: keilStartupPath))
        #expect(startupAfter == startupBefore)

        // The GNU startup file was written from the Keil startup's vector table.
        let gnuStartup = try String(contentsOf: folder.url.appending(path: "uMeil/startup_gcc.c"), encoding: .utf8)
        #expect(gnuStartup.contains("UART0_Handler"))
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "uMeil/tm4c1294ncpdt.ld").path))

        // The user is told about the Arm Compiler library, the Windows path, and TM4C129.h.
        #expect(result.notes.contains { $0.contains("Lib4.lib") })
        #expect(result.notes.contains { $0.contains("C:/Course/Common") })
        #expect(result.notes.contains { $0.contains("TM4C129.h") })
    }

    @Test func doesNotWarnAboutTheDeviceHeaderWhenItIsPresent() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        let inc = folder.url.appending(path: "inc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inc, withIntermediateDirectories: true)
        try Data("/* TM4C129 */\n".utf8).write(to: inc.appending(path: "TM4C129.h"))

        let result = try KeilImporter.importProject(at: keilFile)

        #expect(!result.notes.contains { $0.contains("TM4C129.h") })
    }

    @Test func fallsBackToCoreVectorsWhenKeilsStartupFileIsMissing() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        try FileManager.default.removeItem(at: folder.url.appending(path: "RTE/Device/TM4C1294NCPDT/startup_TM4C129.s"))

        let result = try KeilImporter.importProject(at: keilFile)

        let gnuStartup = try String(contentsOf: folder.url.appending(path: "uMeil/startup_gcc.c"), encoding: .utf8)
        #expect(gnuStartup.contains("SysTick_Handler"))
        #expect(!gnuStartup.contains("UART0_Handler"))
        #expect(result.notes.contains { $0.contains("startup file was not found") })
    }

    @Test func refusesUnsupportedChipsAndAlreadyImportedFolders() throws {
        let unsupportedFolder = try TemporaryFolder()
        let unsupported = try KeilFixture.make(in: unsupportedFolder.url, device: "TM4C123GH6PM")
        #expect(throws: KeilImportError.unsupportedDevice("TM4C123GH6PM")) {
            try KeilImporter.importProject(at: unsupported)
        }

        let importedFolder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: importedFolder.url)
        let first = try KeilImporter.importProject(at: keilFile)
        #expect(throws: KeilImportError.alreadyImported(first.projectFile)) {
            try KeilImporter.importProject(at: keilFile)
        }
    }

    @Test func mapsKeilCompilerSettingsToGNUOnes() {
        #expect(KeilImporter.optimization(forKeilLevel: 0) == .none)
        #expect(KeilImporter.optimization(forKeilLevel: 1) == .none)
        #expect(KeilImporter.optimization(forKeilLevel: 2) == .debug)
        #expect(KeilImporter.optimization(forKeilLevel: 3) == .more)
        #expect(KeilImporter.optimization(forKeilLevel: 6) == .size)

        #expect(KeilImporter.cStandard(forKeilLevel: 1) == "c90")
        #expect(KeilImporter.cStandard(forKeilLevel: 3) == "c99")
        #expect(KeilImporter.cStandard(forKeilLevel: 5) == "c11")
        #expect(KeilImporter.cStandard(forKeilLevel: 6) == "gnu11")
    }

    @Test(.enabled(if: BuildTestEnvironment.canBuild))
    func anImportedProjectBuildsWithTheGNUToolchain() async throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        let imported = try KeilImporter.importProject(at: keilFile)

        let plan = try BuildEngine.plan(forProjectFile: imported.projectFile)
        let result = try await BuildEngine().build(plan)

        #expect(result.succeeded, "Build failed:\n\(result.log)")
        #expect(result.compiledSources == [
            "main.c",
            "RTE/Device/TM4C1294NCPDT/system_TM4C129.c",
            "uMeil/startup_gcc.c"
        ])
        #expect(result.elf != nil)
        #expect(result.sections?.code ?? 0 > 100)
    }

    @MainActor
    @Test func importingFromTheWindowOpensTheFolderAndFirstSource() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())

        let imported = try controller.importKeilProject(at: keilFile)

        #expect(controller.folder == imported.projectFile.deletingLastPathComponent())
        #expect(controller.editor.document?.url.lastPathComponent == "main.c")

        let menu = MainMenu.make(appName: "uMeil")
        let fileMenu = try #require(menu.items.compactMap(\.submenu).first { $0.title == "File" })
        let item = try #require(fileMenu.items.first { $0.title == "Import Keil Project…" })
        #expect(item.action == #selector(MainWindowController.importKeilProject(_:)))
    }
}
