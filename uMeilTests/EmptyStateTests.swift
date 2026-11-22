import AppKit
import Testing
@testable import uMeil

@MainActor
struct EmptyStateTests {
    private func emptyResult() -> BuildResult {
        BuildResult(succeeded: true, diagnostics: [], compiledSources: [], didLink: true, log: "")
    }

    @Test func theIssuesListAsksForABuildBeforeTheFirstOne() {
        let issues = IssuesViewController()
        issues.loadViewIfNeeded()

        #expect(!issues.emptyState.isHidden)
        #expect(issues.emptyState.titleLabel.stringValue == "No build yet")
    }

    @Test func aCleanBuildSaysNoIssuesWithACheckmark() {
        let issues = IssuesViewController()
        issues.loadViewIfNeeded()

        issues.show(emptyResult())

        #expect(!issues.emptyState.isHidden)
        #expect(issues.emptyState.titleLabel.stringValue == "No issues")
        #expect(issues.emptyState.imageView.image != nil)
    }

    @Test func theEmptyStateHidesWhileBuildingAndWhenThereAreMessages() {
        let issues = IssuesViewController()
        issues.loadViewIfNeeded()

        issues.showBuilding()
        #expect(issues.emptyState.isHidden)

        issues.show(failure: "No compiler")
        #expect(issues.emptyState.isHidden)

        issues.clear()
        #expect(!issues.emptyState.isHidden)
        #expect(issues.emptyState.titleLabel.stringValue == "No build yet")
    }

    @Test func theDebugConsoleExplainsItselfUntilOutputArrives() {
        let console = CommandViewController()
        console.loadViewIfNeeded()
        #expect(!console.emptyState.isHidden)
        #expect(console.emptyState.detailLabel.stringValue.contains("Start a debug session"))

        console.appendOutput("Open On-Chip Debugger\n")
        #expect(console.emptyState.isHidden)

        console.clear()
        #expect(!console.emptyState.isHidden)
    }

    @Test func theEmptyStateLetsClicksThrough() {
        let view = EmptyStateView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        #expect(view.hitTest(NSPoint(x: 100, y: 50)) == nil)
    }
}
