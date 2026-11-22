import AppKit

/// The serial monitor's console. It shows what the board prints and, when
/// asked to, hands key presses and pastes to the monitor to send instead of
/// handling them itself.
final class SerialConsoleTextView: NSTextView {
    /// Called for each key press. Returns true if it took the key.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called with the text of a paste. Returns true if it took the text;
    /// while nil, Paste is unavailable, as in any read-only text view.
    var pasteHandler: ((String) -> Bool)?
    /// Where Paste reads from. Tests use one of their own.
    var pasteboard = NSPasteboard.general

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard let pasteHandler, let text = pasteboard.string(forType: .string) else {
            super.paste(sender)
            return
        }
        if !pasteHandler(text) {
            NSSound.beep()
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) && pasteHandler != nil {
            return pasteboard.string(forType: .string) != nil
        }
        return super.validateUserInterfaceItem(item)
    }
}
