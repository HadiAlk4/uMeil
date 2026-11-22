import AppKit

extension IssuesViewController {
    /// Shows a checkmark and "No issues" when the last build or flash had
    /// nothing to report, and a hint to build before anything has run.
    func updateEmptyState() {
        emptyState.isHidden = !diagnostics.isEmpty || isBusy
        if hasOutcome {
            emptyState.show(symbol: "checkmark.circle", title: "No issues", tint: .systemGreen)
        } else {
            emptyState.show(
                symbol: "hammer",
                title: "No build yet",
                detail: "Build the project (⌘B) to see its errors and warnings here."
            )
        }
    }
}
