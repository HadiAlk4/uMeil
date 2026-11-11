import Foundation
import Testing
@testable import uMeil

struct BuildSummaryTests {
    private let main = URL(filePath: "/p/src/main.c")
    private let other = URL(filePath: "/p/src/uart.c")

    private func diagnostic(
        _ severity: Diagnostic.Severity,
        _ file: URL?,
        line: Int?,
        _ message: String = "message"
    ) -> Diagnostic {
        Diagnostic(severity: severity, message: message, file: file, line: line, column: 1)
    }

    private func result(
        succeeded: Bool,
        _ diagnostics: [Diagnostic] = [],
        size: ProgramSize? = nil
    ) -> BuildResult {
        BuildResult(
            succeeded: succeeded,
            diagnostics: diagnostics,
            compiledSources: [],
            didLink: false,
            size: size,
            log: ""
        )
    }

    // MARK: - Gutter markers

    @Test func marksTheLinesOfTheOpenFileOnly() {
        let markers = BuildSummary.markers(for: main, in: [
            diagnostic(.error, main, line: 12),
            diagnostic(.warning, main, line: 30),
            diagnostic(.error, other, line: 5),
            diagnostic(.error, nil, line: nil)
        ])

        #expect(markers == [12: .error, 30: .warning])
    }

    @Test func anErrorOutranksAWarningOnTheSameLine() {
        let warningFirst = BuildSummary.markers(for: main, in: [
            diagnostic(.warning, main, line: 7),
            diagnostic(.error, main, line: 7)
        ])
        let errorFirst = BuildSummary.markers(for: main, in: [
            diagnostic(.error, main, line: 7),
            diagnostic(.warning, main, line: 7)
        ])

        #expect(warningFirst == [7: .error])
        #expect(errorFirst == [7: .error])
    }

    @Test func notesDoNotGetAMarker() {
        let markers = BuildSummary.markers(for: main, in: [diagnostic(.note, main, line: 3)])

        #expect(markers.isEmpty)
    }

    @Test func matchesTheSameFileReachedThroughADifferentPath() throws {
        // The temporary folder is /var/... and also /private/var/...; the
        // compiler may report one while the editor has the other.
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "main.c")
        try Data().write(to: file)

        let markers = BuildSummary.markers(for: file, in: [
            diagnostic(.error, file.resolvingSymlinksInPath(), line: 2)
        ])

        #expect(markers == [2: .error])
    }

    // MARK: - Status line

    @Test func describesASuccessfulBuildWithItsSize() {
        let size = ProgramSize(text: 1396, data: 8, bss: 16)

        let text = BuildSummary.statusText(for: result(succeeded: true, size: size))

        #expect(text.hasPrefix("Build succeeded: "))
        #expect(text.contains("flash"))
        #expect(text.hasSuffix("RAM"))
    }

    @Test func mentionsWarningsOnASuccessfulBuild() {
        let text = BuildSummary.statusText(for: result(succeeded: true, [
            diagnostic(.warning, main, line: 1),
            diagnostic(.warning, main, line: 2)
        ]))

        #expect(text == "Build succeeded: 2 warnings")
    }

    @Test func countsErrorsAndWarningsOnAFailedBuild() {
        let text = BuildSummary.statusText(for: result(succeeded: false, [
            diagnostic(.error, main, line: 1),
            diagnostic(.warning, main, line: 2),
            diagnostic(.note, main, line: 2)
        ]))

        #expect(text == "Build failed: 1 error, 1 warning")
        #expect(BuildSummary.statusText(for: result(succeeded: false)) == "Build failed")
        #expect(BuildSummary.statusText(for: result(succeeded: true)) == "Build succeeded")
    }

    // MARK: - Issue locations

    @Test func describesWhereAMessagePoints() {
        #expect(BuildSummary.locationText(for: diagnostic(.error, main, line: 12)) == "main.c:12")
        #expect(BuildSummary.locationText(for: diagnostic(.error, main, line: nil)) == "main.c")
        #expect(BuildSummary.locationText(for: diagnostic(.error, nil, line: nil)).isEmpty)
    }

    // MARK: - Finding the project file

    @Test func findsTheProjectFileInAFolder() throws {
        let folder = try TemporaryFolder()
        try Data().write(to: folder.url.appending(path: "README.md"))
        #expect(BuildSummary.projectFile(in: folder.url) == nil)

        try Data().write(to: folder.url.appending(path: "Blinky.umeil"))
        #expect(BuildSummary.projectFile(in: folder.url)?.lastPathComponent == "Blinky.umeil")
    }
}
