import AppKit

/// The run and step buttons and debug status that float over the editor during a session.
extension MainWindowController {
    /// How far below the editor's tab bar (and away from its sides) the bar floats.
    static let debugBarInset: CGFloat = 8

    /// Puts the bar over the top of the editor, hidden until a session starts.
    func installDebugBar() {
        let container = editor.view
        debugBar.translatesAutoresizingMaskIntoConstraints = false
        debugBar.isHidden = true
        debugBar.isActionEnabled = { [weak self] action in self?.isEnabled(action) ?? false }
        // Sent straight here, so a click is not lost when another window is key.
        debugBar.buttons.forEach { $0.target = self }
        container.addSubview(debugBar)
        let leading = debugBar.leadingAnchor.constraint(
            greaterThanOrEqualTo: container.leadingAnchor,
            constant: Self.debugBarInset
        )
        let trailing = debugBar.trailingAnchor.constraint(
            lessThanOrEqualTo: container.trailingAnchor,
            constant: -Self.debugBarInset
        )
        // Below required so a zero-width container before layout never logs a conflict,
        // while beating the status label's low compression resistance so long text truncates cleanly.
        leading.priority = NSLayoutConstraint.Priority(900)
        trailing.priority = NSLayoutConstraint.Priority(900)
        NSLayoutConstraint.activate([
            debugBar.topAnchor.constraint(equalTo: editor.tabBar.bottomAnchor, constant: Self.debugBarInset),
            debugBar.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            leading,
            trailing
        ])
    }

    /// Shows the bar during a session, with Stop or Run and the status text that fit `state`.
    func updateDebugBar(
        for state: DebugController.State,
        status: String? = nil,
        reason: StopReason? = nil
    ) {
        debugBar.isHidden = state == .idle
        debugBar.show(isRunning: state == .running)
        if state == .idle {
            debugBar.showStatus("")
        } else {
            let text = status ?? DebugSummary.statusText(for: state, reason: reason)
            debugBar.showStatus(text, kind: Self.debugBarStatusKind(for: state, reason: reason))
        }
    }

    private static func debugBarStatusKind(
        for state: DebugController.State,
        reason: StopReason?
    ) -> DebugBarView.StatusKind {
        switch state {
        case .idle, .starting:
            return .starting
        case .running:
            return .running
        case .stopped:
            return DebugSummary.isFault(reason: reason) ? .error : .stopped
        }
    }
}
