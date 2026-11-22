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
            "uMeil/es_lib.c",
            "uMeil/startup_gcc.c"
        ])
        #expect(result.project.includePaths == [
            ".",
            "inc",
            "RTE/Device/TM4C1294NCPDT",
            "RTE/_Target_1",
            "uMeil"
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

        // The GNU startup file, TM4C129.h, course library, and linker script were written.
        let gnuStartup = try String(contentsOf: folder.url.appending(path: "uMeil/startup_gcc.c"), encoding: .utf8)
        #expect(gnuStartup.contains("UART0_Handler"))
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "uMeil/TM4C129.h").path))
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "uMeil/es_lib.c").path))
        #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "uMeil/tm4c1294ncpdt.ld").path))

        // The user is told that Lib4.lib was replaced with uMeil/es_lib.c and about the Windows path.
        #expect(result.notes.contains { $0.contains("Lib4.lib was replaced with uMeil/es_lib.c") })
        #expect(result.notes.contains { $0.contains("C:/Course/Common") })
        #expect(!result.notes.contains { $0.contains("TM4C129.h") })
    }

    @Test func warnsWhenACustomDeviceHeaderIsMissing() throws {
        let folder = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        let components = folder.url.appending(path: "RTE/_Target_1/RTE_Components.h")
        try "#define CMSIS_device_header \"CustomDevice.h\"\n".write(to: components, atomically: true, encoding: .utf8)

        let result = try KeilImporter.importProject(at: keilFile)

        #expect(result.notes.contains { $0.contains("CustomDevice.h") })
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
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(result.compiledSources == [
            "main.c",
            "RTE/Device/TM4C1294NCPDT/system_TM4C129.c",
            "uMeil/es_lib.c",
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

    @Test func skipsPathsEscapingTheProjectFolderDuringImport() throws {
        let folder = try TemporaryFolder()
        let outside = try TemporaryFolder()
        let outsideSource = outside.url.appending(path: "outside.c")
        let outsideStartup = outside.url.appending(path: "startup_out.s")
        try Data("int secret;\n".utf8).write(to: outsideSource)
        try Data(KeilFixture.keilStartup.utf8).write(to: outsideStartup)

        _ = try KeilFixture.make(in: folder.url)
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "link_out.c"), withDestinationURL: outsideSource
        )
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "link_lib.lib"), withDestinationURL: outsideSource
        )
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "link_inc"), withDestinationURL: outside.url
        )

        let maliciousXML = KeilFixture.projectFile(device: "TM4C1294NCPDT")
            .replacing("<TargetName>Target 1</TargetName>", with: "<TargetName>../../outside</TargetName>")
            .replacing(
                "<IncludePath>.\\inc;C:\\Course\\Common</IncludePath>",
                with: "<IncludePath>.\\inc;..\\outside_inc;link_inc;-I/etc</IncludePath>"
            )
            .replacing("<FilePath>.\\Lib4.lib</FilePath>", with: "<FilePath>link_lib.lib</FilePath>")
            .replacing("<FilePath>.\\old.c</FilePath>", with: "<FilePath>..\\outside.c</FilePath>")
            .replacing("<IncludeInBuild>0</IncludeInBuild>", with: "<IncludeInBuild>1</IncludeInBuild>")
            .replacing("RTE\\Device\\TM4C1294NCPDT\\startup_TM4C129.s", with: "..\\..\\startup_out.s")
            .replacing("RTE\\Device\\TM4C1294NCPDT\\system_TM4C129.c", with: "link_out.c")

        let keilFile = folder.url.appending(path: "Template.uvprojx")
        try Data(maliciousXML.utf8).write(to: keilFile)
        let result = try KeilImporter.importProject(at: keilFile)

        #expect(result.project.sources == ["main.c", "uMeil/startup_gcc.c"])
        #expect(result.project.includePaths == [".", "inc", "uMeil"])
        #expect(!result.project.sources.contains("uMeil/es_lib.c"))
        #expect(result.notes.contains { $0.contains("../outside.c") && $0.contains("outside the project folder") })
        #expect(result.notes.contains { $0.contains("link_lib.lib") && $0.contains("outside the project folder") })
        #expect(result.notes.contains { $0.contains("link_out.c") && $0.contains("outside the project folder") })
        #expect(result.notes.contains { $0.contains("../outside_inc") && $0.contains("outside the project folder") })
        #expect(result.notes.contains { $0.contains("startup_out.s") && $0.contains("outside the project folder") })
        #expect(result.notes.contains { $0.contains("RTE") && $0.contains("outside the project folder") })
    }

    @Test func refusesSymlinkedSupportDirectoryAndSupportFiles() throws {
        let folder = try TemporaryFolder()
        let outside = try TemporaryFolder()
        let keilFile = try KeilFixture.make(in: folder.url)
        try FileManager.default.createSymbolicLink(
            at: folder.url.appending(path: "uMeil"),
            withDestinationURL: outside.url
        )

        #expect(throws: ProjectSecurityError.self) {
            try KeilImporter.importProject(at: keilFile)
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.url.path)).isEmpty)

        // Now test a real uMeil directory containing a symlinked target file during reopen.
        let folder2 = try TemporaryFolder()
        let keilFile2 = try KeilFixture.make(in: folder2.url)
        _ = try KeilImporter.importProject(at: keilFile2)
        let startupURL = folder2.url.appending(path: "uMeil/startup_gcc.c")
        try FileManager.default.removeItem(at: startupURL)
        let outsideTarget = outside.url.appending(path: "target.c")
        try Data("// external\n".utf8).write(to: outsideTarget)
        try FileManager.default.createSymbolicLink(at: startupURL, withDestinationURL: outsideTarget)

        #expect(throws: ProjectSecurityError.symlinkNotAllowed(startupURL)) {
            try KeilImporter.openProject(at: keilFile2)
        }
        #expect(try String(contentsOf: outsideTarget, encoding: .utf8) == "// external\n")
    }
}
