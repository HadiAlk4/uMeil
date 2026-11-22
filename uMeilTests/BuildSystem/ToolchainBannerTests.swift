import AppKit
import Testing
@testable import uMeil

@MainActor
struct ToolchainBannerTests {
    @Test func aMissingToolShowsTheBannerInsteadOfAnErrorLine() {
        let issues = IssuesViewController()
        issues.loadViewIfNeeded()
        #expect(issues.toolchainBanner.isHidden)

        issues.show(failure: BuildError.compilerNotFound)

        #expect(!issues.toolchainBanner.isHidden)
        #expect(issues.toolchainBanner.messageLabel.stringValue == Tool.compiler.missingMessage)
        #expect(issues.diagnostics.isEmpty)
    }

    @Test func otherFailuresStillListAnError() {
        let issues = IssuesViewController()

        issues.show(failure: BuildError.unsafeProjectSetting("a flag"))

        #expect(issues.toolchainBanner.isHidden)
        #expect(issues.diagnostics.map(\.severity) == [.error])
    }

    @Test func aFlashWithoutOpenOCDKeepsTheBuildsWarnings() {
        let issues = IssuesViewController()
        let warning = Diagnostic(severity: .warning, message: "unused variable")
        issues.show(BuildResult(succeeded: true, diagnostics: [warning], compiledSources: [], didLink: true, log: ""))

        issues.show(FlashResult(failure: .openOCDNotFound, log: ""))

        #expect(issues.toolchainBanner.tools == [.openOCD])
        #expect(issues.diagnostics == [warning])
        #expect(issues.statusLabel.stringValue == "Flash failed")
    }

    @Test func installAsksForTheMissingToolsAndDismissHides() throws {
        let issues = IssuesViewController()
        issues.loadViewIfNeeded()
        var asked: [[Tool]] = []
        issues.onInstallTools = { asked.append($0) }
        issues.show(missingTool: .debugger, status: "Debug session failed to start")

        issues.toolchainBanner.installButton.performClick(nil)
        #expect(asked == [[.debugger]])

        issues.toolchainBanner.dismissButton.performClick(nil)
        #expect(issues.toolchainBanner.isHidden)
    }

    @Test func theNextBuildHidesTheBanner() {
        let issues = IssuesViewController()
        issues.show(missingTool: .compiler, status: "Build failed")

        issues.showBuilding()

        #expect(issues.toolchainBanner.isHidden)
    }

    @Test func errorsKnowWhichToolIsMissing() {
        #expect(BuildError.compilerNotFound.missingTool == .compiler)
        #expect(FlashFailure.openOCDNotFound.missingTool == .openOCD)
        #expect(ToolNotInstalled(tool: .debugger).missingTool == .debugger)
        #expect(FlashFailure.boardNotConnected.missingTool == nil)
        #expect(ToolNotInstalled(tool: .debugger).localizedDescription.contains("Toolchain Status"))
    }
}
