import AppKit

// The mode that sends each key as it is typed in the console, like Tera
// Term, instead of a line at a time from the field below it.
extension SerialMonitorViewController {
    /// Whether keys typed in the console go straight to the board.
    var sendsEachKey: Bool {
        get { sendEachKeyCheckbox.state == .on }
        set {
            sendEachKeyCheckbox.state = newValue ? .on : .off
            updateKeyMode()
        }
    }

    func setUpKeyMode() {
        sendEachKeyCheckbox.toolTip = "Send each key as you type it in the console, like Tera Term, "
            + "including Escape and Control keys. Return sends the chosen line ending."
        keyModeHint.textColor = .secondaryLabelColor
        keyModeHint.lineBreakMode = .byTruncatingTail
        keyModeHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyModeHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        textView.keyHandler = { [weak self] event in self?.sendKey(event) ?? false }
        textView.pasteHandler = { [weak self] text in self?.sendPaste(text) ?? false }

        sendEachKeyCheckbox.state = defaults.bool(forKey: DefaultsKey.sendsEachKey) ? .on : .off
        updateKeyMode()
    }

    @objc func sendEachKeyToggled(_ sender: Any?) {
        defaults.set(sendsEachKey, forKey: DefaultsKey.sendsEachKey)
        updateKeyMode()
        focusInput()
    }

    /// Shows the line field or the hint, to match the mode.
    func updateKeyMode() {
        inputField.isHidden = sendsEachKey
        sendButton.isHidden = sendsEachKey
        keyModeHint.isHidden = !sendsEachKey
        keyModeHint.stringValue = isConnected
            ? "Type in the console above. Each key is sent as you press it."
            : "Connect, then type in the console above."
        lineEndingPopUp.toolTip = sendsEachKey
            ? "What Return sends"
            : "What is added to the end of each line you send"
    }

    /// Puts the keyboard where the user types for the current mode.
    func focusInput() {
        guard isConnected else { return }
        view.window?.makeFirstResponder(sendsEachKey ? textView : inputField)
    }

    /// Sends the bytes for a key typed in the console. Returns false, so the
    /// console handles the key itself, when the key is not for the board.
    private func sendKey(_ event: NSEvent) -> Bool {
        guard sendsEachKey, isConnected, let bytes = SerialKeys.bytes(for: event, returnKey: lineEnding) else {
            return false
        }
        write(Data(bytes))
        return true
    }

    /// Sends pasted text, with each line break as the chosen line ending.
    /// Returns false when nothing could be sent.
    private func sendPaste(_ text: String) -> Bool {
        guard sendsEachKey, isConnected else { return false }
        let ending = lineEnding == .none ? "\r" : lineEnding.text
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return write(Data(lines.replacingOccurrences(of: "\n", with: ending).utf8))
    }
}
