import AppKit
import Foundation
import Testing
@testable import uMeil

@MainActor
struct NavigatorSectionTests {
    private func makeFiles(_ paths: [String], in temp: TemporaryDirectory) throws {
        try makeFiles(paths, in: temp.url)
    }

    private func makeFiles(_ paths: [String], in folder: URL) throws {
        for path in paths {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
    }

    private func project(sources: [String], linkerScript: String) -> Project {
        Project(
            name: "Blinky",
            target: .init(chip: .tm4c1294ncpdt, board: nil),
            sources: sources,
            includePaths: [],
            build: .init(
                cStandard: "gnu11",
                optimization: .none,
                defines: [],
                compilerFlags: [],
                linkerFlags: [],
                linkerScript: linkerScript,
                useDriverLib: false
            )
        )
    }

    @Test func tellsStartupCodeFromOtherSources() {
        #expect(NavigatorSection.isStartupCode("startup/startup.c"))
        #expect(NavigatorSection.isStartupCode("startup_TM4C129.s"))
        #expect(NavigatorSection.isStartupCode("RTE/Device/Startup_tm4c.s"))
        #expect(!NavigatorSection.isStartupCode("src/main.c"))
        #expect(!NavigatorSection.isStartupCode("src/restartup.c"))
    }

    @Test func groupsAProjectsFilesUnderHeadings() throws {
        let temp = try TemporaryDirectory()
        try makeFiles(["src/main.c", "src/uart.c", "startup/startup.c", "chip.ld"], in: temp)
        let project = project(sources: ["src/main.c", "src/uart.c", "startup/startup.c"], linkerScript: "chip.ld")

        let groups = NavigatorSection.projectFiles(of: project, in: temp.url)

        #expect(groups.map(\.kind) == [.sources, .startup, .linkerScript])
        #expect(groups.map { $0.files.map(\.lastPathComponent) } == [["main.c", "uart.c"], ["startup.c"], ["chip.ld"]])
    }

    @Test func leavesOutMissingFilesAndEmptyHeadings() throws {
        let temp = try TemporaryDirectory()
        try makeFiles(["main.c"], in: temp)
        let project = project(sources: ["main.c", "gone.c"], linkerScript: "missing.ld")

        let groups = NavigatorSection.projectFiles(of: project, in: temp.url)

        #expect(groups.map(\.kind) == [.sources])
        #expect(groups.first?.files.map(\.lastPathComponent) == ["main.c"])
    }

    @Test func theNavigatorShowsHeadingsForAProjectFolder() throws {
        let temp = try TemporaryDirectory()
        let template = try #require(try ProjectTemplate.all().first)
        let projectFile = try template.createProject(named: "Blinky", in: temp.url)
        let navigator = FileNavigatorViewController()

        navigator.showFolder(projectFile.deletingLastPathComponent())

        #expect(navigator.sections.map(\.title) == ["Sources", "Startup", "Linker Script", "Files"])
        let outline = navigator.outlineView
        let headings = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? NavigatorSection)?.title }
        #expect(headings == ["Sources", "Startup", "Linker Script", "Files"])
        #expect((outline.item(atRow: 1) as? FileNode)?.name == "main.c")
    }

    @Test func selectingAProjectSourcePicksItUnderItsHeading() throws {
        let temp = try TemporaryDirectory()
        let template = try #require(try ProjectTemplate.all().first)
        let folder = try template.createProject(named: "Blinky", in: temp.url).deletingLastPathComponent()
        let navigator = FileNavigatorViewController()
        navigator.showFolder(folder)

        navigator.select(folder.appending(path: "startup/startup.c"))

        let outline = navigator.outlineView
        let row = outline.selectedRow
        #expect((outline.item(atRow: row) as? FileNode)?.name == "startup.c")
        #expect(outline.parent(forItem: outline.item(atRow: row)) is NavigatorSection)
        #expect((outline.parent(forItem: outline.item(atRow: row)) as? NavigatorSection)?.kind == .startup)
    }

    @Test func headingsCannotBeSelected() throws {
        let temp = try TemporaryDirectory()
        let template = try #require(try ProjectTemplate.all().first)
        let folder = try template.createProject(named: "Blinky", in: temp.url).deletingLastPathComponent()
        let navigator = FileNavigatorViewController()
        navigator.showFolder(folder)

        let heading = try #require(navigator.sections.first)
        #expect(navigator.outlineView(navigator.outlineView, shouldSelectItem: heading) == false)
    }

    @Test func aFolderWithoutAProjectHasNoHeadings() throws {
        let temp = try TemporaryDirectory()
        try makeFiles(["main.c"], in: temp)
        let navigator = FileNavigatorViewController()

        navigator.showFolder(temp.url)

        #expect(navigator.sections.isEmpty)
        #expect((navigator.outlineView.item(atRow: 0) as? FileNode)?.name == "main.c")
    }

    @Test func excludesEscapingPathsAndOutsideSymlinksWhileKeepingValidPaths() throws {
        let outer = try TemporaryDirectory()
        let folder = try outer.directory("project")
        let outsideDir = try outer.directory("outsideDir")
        try makeFiles(["secret.c", "startup_secret.c", "outside.ld", "outsideDir/nested.c"], in: outer)
        try makeFiles(["src/main.c", "startup/startup.c", "chip.ld"], in: folder)

        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(
            at: folder.appending(path: "escape_file.c"),
            withDestinationURL: outer.url.appending(path: "secret.c")
        )
        try fileManager.createSymbolicLink(
            at: folder.appending(path: "escape_dir"),
            withDestinationURL: outsideDir
        )
        try fileManager.createSymbolicLink(
            at: folder.appending(path: "startup/escape_startup.c"),
            withDestinationURL: outer.url.appending(path: "startup_secret.c")
        )

        let project = project(
            sources: [
                "src/main.c",
                "../secret.c",
                "src/../../secret.c",
                "/etc/passwd",
                "escape_file.c",
                "escape_dir/nested.c",
                "startup/startup.c",
                "../startup_secret.c",
                "startup/escape_startup.c"
            ],
            linkerScript: "chip.ld"
        )

        let groups = NavigatorSection.projectFiles(of: project, in: folder)

        #expect(groups.map(\.kind) == [.sources, .startup, .linkerScript])
        #expect(groups.map { $0.files.map(\.lastPathComponent) } == [["main.c"], ["startup.c"], ["chip.ld"]])
        #expect(groups[0].files == [folder.standardizedFileURL.appending(path: "src/main.c")])
    }

    @Test func excludesEscapingAndSymlinkedLinkerScripts() throws {
        let outer = try TemporaryDirectory()
        let folder = try outer.directory("project")
        try makeFiles(["outside.ld"], in: outer)
        try FileManager.default.createSymbolicLink(
            at: folder.appending(path: "escape.ld"),
            withDestinationURL: outer.url.appending(path: "outside.ld")
        )

        for unsafeScript in ["../outside.ld", "/etc/passwd", "escape.ld"] {
            let project = project(sources: [], linkerScript: unsafeScript)
            #expect(NavigatorSection.projectFiles(of: project, in: folder).isEmpty)
        }
    }
}
