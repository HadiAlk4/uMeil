import AppKit

/// The run and step buttons that float over the editor during a session.
extension MainWindowController {
    /// How far below the top of the editor the bar floats.
    static let debugBarInset: CGFloat = 8

    /// Puts the bar over the top of the editor, hidden until a session starts.
    func installDebugBar() {
        let container = editor.view
        debugBar.translatesAutoresizingMaskIntoConstraints = false
        debugBar.isHidden = true
        debugBar.isActionEnabled = { [weak self] action in self?.isEnabled(action) ?? false }
        container.addSubview(debugBar)
        NSLayoutConstraint.activate([
            debugBar.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.debugBarInset),
            debugBar.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ])
    }

    /// Shows the bar during a session, with Stop or Run as fits `state`.
    func updateDebugBar(for state: DebugController.State) {
        debugBar.isHidden = state == .idle
        debugBar.show(isRunning: state == .running)
    }
}
