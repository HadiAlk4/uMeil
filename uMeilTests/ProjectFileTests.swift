import Foundation
import Testing
@testable import uMeil

struct ProjectFileTests {
    private static let sample = Project(
        name: "Demo",
        target: .init(chip: .tm4c1294ncpdt, board: .ekTM4C1294XL),
        sources: ["src/main.c", "startup/startup.c"],
        includePaths: ["src"],
        build: .init(
            cStandard: "gnu11",
            optimization: .debug,
            defines: ["DEBUG=1"],
            compilerFlags: ["-Wall"],
            linkerFlags: [],
            linkerScript: "tm4c1294ncpdt.ld",
            useDriverLib: true
        )
    )

    private static let sampleJSON = """
        {
          "build" : {
            "compilerFlags" : [
              "-Wall"
            ],
            "cStandard" : "gnu11",
            "defines" : [
              "DEBUG=1"
            ],
            "linkerFlags" : [

            ],
            "linkerScript" : "tm4c1294ncpdt.ld",
            "optimization" : "Og",
            "useDriverLib" : true
          },
          "formatVersion" : 1,
          "includePaths" : [
            "src"
          ],
          "name" : "Demo",
          "sources" : [
            "src/main.c",
            "startup/startup.c"
          ],
          "target" : {
            "board" : "EK-TM4C1294XL",
            "chip" : "TM4C1294NCPDT"
          }
        }

        """

    // MARK: Writing and reading

    @Test func writesStableReadableJSON() throws {
        let written = String(bytes: try ProjectFile.encode(Self.sample), encoding: .utf8)
        #expect(written == Self.sampleJSON)
    }

    @Test func readsWhatItWrote() throws {
        let data = try ProjectFile.encode(Self.sample)
        #expect(try ProjectFile.decode(data) == Self.sample)
    }

    @Test func savesAndLoadsFromDisk() throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Demo.umeil")

        try ProjectFile.save(Self.sample, to: url)
        #expect(try ProjectFile.load(from: url) == Self.sample)
    }

    @Test func boardIsOptional() throws {
        var project = Self.sample
        project.target.board = nil

        let data = try ProjectFile.encode(project)
        #expect(String(bytes: data, encoding: .utf8)?.contains("board") == false)
        #expect(try ProjectFile.decode(data) == project)
    }

    // MARK: Files uMeil must refuse

    @Test(arguments: ["", "not json", "[1, 2]", "{}", #"{"formatVersion": "1"}"#, #"{"formatVersion": 0}"#])
    func rejectsFilesThatAreNotProjects(text: String) {
        #expect(throws: ProjectFileError.notAProjectFile) {
            try ProjectFile.decode(Data(text.utf8))
        }
    }

    @Test func rejectsFilesFromANewerVersion() {
        let json = Self.sampleJSON.replacing(#""formatVersion" : 1"#, with: #""formatVersion" : 2"#)
        #expect(throws: ProjectFileError.newerFormat(found: 2, supported: 1)) {
            try ProjectFile.decode(Data(json.utf8))
        }
    }

    @Test func reportsAMissingField() {
        let json = Self.sampleJSON.replacing(#""linkerScript" : "tm4c1294ncpdt.ld","#, with: "")
        #expect(throws: ProjectFileError.invalid(#""build.linkerScript" is missing"#)) {
            try ProjectFile.decode(Data(json.utf8))
        }
    }

    @Test func reportsAnUnsupportedChip() {
        let json = Self.sampleJSON.replacing("TM4C1294NCPDT", with: "TM4C123GH6PM")
        #expect(throws: ProjectFileError.invalid(#""target.chip" has a value uMeil does not support"#)) {
            try ProjectFile.decode(Data(json.utf8))
        }
    }

    // MARK: Older versions of the format

    /// The real format is still at version 1, so there is nothing older to
    /// read yet. These tests pretend the current version is 3 and that
    /// versions 1 and 2 stored the name and the chip differently.
    private static let pretendMigrations: [Int: ProjectFile.Migration] = [
        1: { json in
            json["name"] = json.removeValue(forKey: "title")
        },
        2: { json in
            json["target"] = ["chip": json.removeValue(forKey: "chip")]
        }
    ]

    private static func olderFile(version: Int) throws -> Data {
        let current = try JSONSerialization.jsonObject(with: Data(sampleJSON.utf8))
        var json = try #require(current as? [String: Any])
        json["formatVersion"] = version
        if version <= 2 {
            json["chip"] = "TM4C1294NCPDT"
            json["target"] = nil
        }
        if version <= 1 {
            json["title"] = json.removeValue(forKey: "name")
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test(arguments: [1, 2, 3])
    func upgradesOlderFiles(version: Int) throws {
        let project = try ProjectFile.decode(
            Self.olderFile(version: version),
            currentVersion: 3,
            migrations: Self.pretendMigrations
        )

        var expected = Self.sample
        if version <= 2 {
            expected.target.board = nil
        }
        #expect(project == expected)
    }

    @Test func rejectsOlderFilesItCannotUpgrade() throws {
        let data = try Self.olderFile(version: 1)
        #expect(throws: ProjectFileError.noMigration(from: 1)) {
            try ProjectFile.decode(data, currentVersion: 3, migrations: [2: Self.pretendMigrations[2]!])
        }
    }

    @Test func everyOlderVersionHasAMigration() {
        for version in 1..<ProjectFile.currentVersion {
            #expect(ProjectFile.migrations[version] != nil, "No migration from format version \(version)")
        }
    }
}
