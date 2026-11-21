import AppKit

extension MainWindowController {
    /// Builds, as Product > Build does, and says so over the editor when the
    /// build worked. Builds that come before a flash or a debug session do
    /// not, since those say how they went themselves.
    @discardableResult
    func buildShowingNotice() async -> BuildResult? {
        let result = await build()
        if let result {
            showNotice(NoticeText.build(result))
        }
        return result
    }

    /// Floats `message` over the editor for a moment. Does nothing for `nil`.
    func showNotice(_ message: NoticeView.Message?) {
        guard let message else { return }
        if notice.superview == nil {
            notice.install(in: editor.view)
        }
        notice.show(message)
    }
}
