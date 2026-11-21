import AppKit
import Testing
@testable import uMeil

@MainActor
struct ActivityTests {
    @Test func theOutcomeIsTheWorstMessage() {
        let warning = Diagnostic(severity: .warning, message: "unused variable")
        let error = Diagnostic(severity: .error, message: "undeclared")
        #expect(Activity.outcome(of: []) == .succeeded)
        #expect(Activity.outcome(of: [warning]) == .warning)
        #expect(Activity.outcome(of: [warning, error]) == .failed)
    }

    @Test func theViewStartsReady() {
        let view = ActivityView()
        #expect(view.activity == .idle)
        #expect(view.text == "Ready")
    }

    @Test func theViewShowsWhatItIsGiven() {
        let view = ActivityView()
        view.show(Activity(text: "Writing to the board", kind: .working(progress: 0.4)))
        #expect(view.text == "Writing to the board")

        view.show(Activity(text: "Flashed", kind: .succeeded))
        #expect(view.activity.kind == .succeeded)
        #expect(view.toolTip == "Flashed")
    }

    @Test func theIssuesPanelReportsBuildsToTheToolbar() {
        let issues = IssuesViewController()
        var seen: [Activity.Kind] = []
        issues.onActivity = { seen.append($0.kind) }

        issues.showBuilding()
        issues.show(failure: "No compiler")
        issues.clear()

        #expect(seen == [.working(progress: nil), .failed, .idle])
    }
}
