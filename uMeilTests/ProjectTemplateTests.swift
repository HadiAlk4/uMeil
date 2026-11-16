import CryptoKit
import Foundation
import Testing
@testable import uMeil

struct ProjectTemplateTests {
    private func blinky() throws -> ProjectTemplate {
        try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
    }

    /// Every file under `folder`, as relative path to SHA-256 of its contents.
    private func snapshot(of folder: URL) throws -> [String: String] {
        let root = folder.resolvingSymlinksInPath().path + "/"
        let files = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))

        var result: [String: String] = [:]
        for case let file as URL in files where !file.hasDirectoryPath {
            let path = file.resolvingSymlinksInPath().path
            let digest = SHA256.hash(data: try Data(contentsOf: file))
            result[String(path.dropFirst(root.count))] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    // MARK: The built-in templates

    @Test func appShipsTheBlinkyTemplate() throws {
        let templates = try ProjectTemplate.all()
        #expect(templates.map(\.identifier) == ["Blinky"])

        let blinky = try blinky()
        #expect(blinky.name == "Blinky")
        #expect(blinky.summary.contains("EK-TM4C1294XL"))
    }

    /// Snapshot test. If the template changes on purpose, update the hashes
    /// (`shasum -a 256 <file>`) and the expected project below.
    @Test func newBlinkyProjectMatchesTheSnapshot() throws {
        let folder = try TemporaryFolder()
        let projectFile = try blinky().createProject(named: "MyBlinky", in: folder.url)

        var files = try snapshot(of: folder.url)
        #expect(files.removeValue(forKey: "MyBlinky/MyBlinky.umeil") != nil)
        #expect(files == [
            "MyBlinky/src/main.c": "0dc51c01011657d9ba98c5cb00dbccb5bbd5d3adf74a6e84efe4713512531db2",
            "MyBlinky/startup/startup.c": "01254a674093fd9dac2f825154be8384b1db8824e39b309e6a3575980adfce9c",
            "MyBlinky/tm4c1294ncpdt.ld": "2aa656c76402b57e421301aef43056da3cf4ff04e9ccbd604573d0e0f9f0e527"
        ])

        #expect(try ProjectFile.load(from: projectFile) == Project(
            name: "MyBlinky",
            target: .init(chip: .tm4c1294ncpdt, board: .ekTM4C1294XL),
            sources: ["src/main.c", "startup/startup.c"],
            includePaths: ["src"],
            build: .init(
                cStandard: "gnu11",
                optimization: .none,
                defines: [],
                compilerFlags: ["-Wall", "-Wextra"],
                linkerFlags: [],
                linkerScript: "tm4c1294ncpdt.ld",
                useDriverLib: true
            )
        ))
    }

    @Test func newProjectListsOnlyFilesThatExist() throws {
        let folder = try TemporaryFolder()
        let projectFile = try blinky().createProject(named: "MyBlinky", in: folder.url)
        let project = try ProjectFile.load(from: projectFile)
        let projectFolder = projectFile.deletingLastPathComponent()

        for path in project.sources + project.includePaths + [project.build.linkerScript] {
            #expect(FileManager.default.fileExists(atPath: projectFolder.appending(path: path).path), "\(path)")
        }
    }

    // MARK: Creating projects

    @Test func doesNotOverwriteAnExistingFolder() throws {
        let folder = try TemporaryFolder()
        let existing = folder.url.appending(path: "MyBlinky", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)

        #expect(throws: ProjectTemplateError.alreadyExists(existing)) {
            try blinky().createProject(named: "MyBlinky", in: folder.url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path).isEmpty)
    }

    @Test(arguments: ["", " ", ".hidden", "a/b", "a:b", "../escape", "trailing ", "two\nlines"])
    func rejectsBadProjectNames(name: String) throws {
        let folder = try TemporaryFolder()

        #expect(throws: ProjectTemplateError.invalidName(name)) {
            try blinky().createProject(named: name, in: folder.url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).isEmpty)
    }

    @Test func leavesNothingBehindWhenTheTemplateIsBroken() throws {
        let folder = try TemporaryFolder()
        let broken = folder.url.appending(path: "Broken", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: try blinky().directory, to: broken)
        try Data(#"{"formatVersion": 99}"#.utf8).write(to: broken.appending(path: "project.json"))

        let output = folder.url.appending(path: "Output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

        #expect(throws: ProjectFileError.self) {
            try ProjectTemplate(directory: broken).createProject(named: "MyBlinky", in: output)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    }

    // MARK: TivaWare

    @Test func appShipsTheTivaWareFilesBlinkyNeeds() throws {
        let blinky = try blinky()
        let main = try String(contentsOf: blinky.directory.appending(path: "files/src/main.c"), encoding: .utf8)
        let includes = main.matches(of: /#include "(.+)"/).map { String($0.output.1) }
        #expect(includes == ["inc/hw_memmap.h", "driverlib/gpio.h", "driverlib/sysctl.h"])

        for header in includes + ["inc/tm4c1294ncpdt.h", "TI-BSD-EULA.txt"] {
            let url = TivaWare.includeDirectory().appending(path: header)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(header)")
        }
    }

    @Test func prebuiltDriverLibIsAnArchiveOfTheRightVersion() throws {
        let library = try Data(contentsOf: TivaWare.library())
        #expect(library.starts(with: Data("!<arch>\n".utf8)))

        let header = TivaWare.includeDirectory().appending(path: "driverlib/gpio.h")
        #expect(try String(contentsOf: header, encoding: .utf8).contains("revision \(TivaWare.version) "))
    }

    // MARK: Chips and boards

    @Test func chipDescribesTheTM4C1294() {
        let chip = Chip.tm4c1294ncpdt
        #expect(chip.cpuFlags == ["-mcpu=cortex-m4", "-mthumb", "-mfpu=fpv4-sp-d16", "-mfloat-abi=hard"])
        #expect(chip.defines == ["PART_TM4C1294NCPDT"])
        #expect(chip.flash == .init(origin: 0, length: 0x10_0000))
        #expect(chip.ram == .init(origin: 0x2000_0000, length: 0x4_0000))
        #expect(Board.ekTM4C1294XL.chip == chip)
    }
}
