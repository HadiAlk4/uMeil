import AppKit

// Sending what the user types to the board.
extension SerialMonitorViewController {
    var lineEnding: SerialLineEnding {
        (lineEndingPopUp.selectedItem?.representedObject as? String).flatMap(SerialLineEnding.init(rawValue:))
            ?? .standard
    }

    func select(_ ending: SerialLineEnding) {
        lineEndingPopUp.selectItem(at: SerialLineEnding.allCases.firstIndex(of: ending) ?? 0)
    }

    @objc func lineEndingChosen(_ sender: Any?) {
        defaults.set(lineEnding.rawValue, forKey: DefaultsKey.lineEnding)
    }

    @objc func sendInput(_ sender: Any?) {
        guard isConnected else { return }
        if send(inputField.stringValue) {
            inputField.stringValue = ""
        }
    }

    /// Sends `line` to the board, followed by the chosen line ending.
    /// Returns false, after showing why, if it could not be sent.
    @discardableResult
    func send(_ line: String) -> Bool {
        guard let port else { return false }
        do {
            try port.write(Data((line + lineEnding.text).utf8))
            return true
        } catch {
            show(status: error.localizedDescription, isError: true)
            return false
        }
    }
}
