import AppKit

/// Parameter hints: after `(` or `,` in a call, the function's signature
/// shows above the line with the argument being typed in bold, so the order
/// of, say, `SysCtlClockFreqSet`'s arguments never needs looking up.
@MainActor
extension EditorViewController {
    var signaturePanel: CodeInfoPanel { intelligence.signaturePanel }

    /// Asks for a hint when `(` or `,` was just typed, and keeps a showing
    /// hint up to date as the cursor moves through the call.
    func handleTypingSignatureTrigger() {
        guard intelligence.isEnabled else { return }
        let cursor = textView.selectedRange().location
        let text = textView.string as NSString
        let typedTrigger = intelligence.lastEditWasSingleTypedCharacter && cursor >= 1 && cursor <= text.length
            && [UInt16(UInt8(ascii: "(")), UInt16(UInt8(ascii: ","))].contains(text.character(at: cursor - 1))
        if typedTrigger {
            requestSignatureHelp(delay: .zero)
        } else if signaturePanel.isVisible {
            requestSignatureHelp(delay: .milliseconds(60))
        }
    }

    /// Follows the cursor while a hint is showing: moving to another
    /// argument highlights it, and leaving the call hides the hint.
    func handleSelectionChangeForSignatureHelp() {
        guard signaturePanel.isVisible else { return }
        requestSignatureHelp(delay: .milliseconds(60))
    }

    func requestSignatureHelp(delay: Duration) {
        intelligence.signatureTask?.cancel()
        intelligence.signatureTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.performSignatureHelpRequest()
        }
    }

    /// Fetches and shows the hint for the call at the cursor, or hides it.
    func performSignatureHelpRequest() async {
        guard intelligence.isEnabled,
              let url = document?.url,
              SourceLanguage(url: url) == .c,
              let onSignatureHelpRequested = intelligence.onSignatureHelpRequested
        else {
            dismissSignatureHelp()
            return
        }
        let version = textVersion
        let cursor = textView.selectedRange().location
        let position = lineIndex.lspPosition(atUTF16Offset: cursor)
        let help = await onSignatureHelpRequested(url, textView.string, position)
        guard !Task.isCancelled,
              intelligence.isEnabled,
              version == textVersion,
              cursor == textView.selectedRange().location,
              document?.url == url
        else { return }

        guard let help, let signature = help.active else {
            dismissSignatureHelp()
            return
        }
        intelligence.signatureHelp = help
        let caret = textView.firstRect(forCharacterRange: NSRange(location: cursor, length: 0), actualRange: nil)
        signaturePanel.show(
            Self.signatureText(signature, activeParameter: help.activeParameterIndex),
            near: caret,
            placement: .above,
            parentWindow: view.window
        )
    }

    func dismissSignatureHelp() {
        intelligence.signatureTask?.cancel()
        intelligence.signatureTask = nil
        intelligence.signatureHelp = nil
        signaturePanel.dismiss()
    }

    /// `void GPIOPinWrite(uint32_t ui32Port, uint8_t ui8Pins, uint8_t ui8Val)`
    /// with the current argument in bold, and the first line of its
    /// documentation underneath.
    static func signatureText(_ signature: LSPSignatureHelp.Signature, activeParameter: Int) -> NSAttributedString {
        let codeFont = EditorTheme.font.withSize(max(EditorTheme.font.pointSize - 1, 10))
        let result = NSMutableAttributedString(string: signature.label, attributes: [
            .font: codeFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        if let range = signature.parameterRange(at: activeParameter) {
            let bold = NSFontManager.shared.convert(codeFont, toHaveTrait: .boldFontMask)
            result.addAttributes([.font: bold, .foregroundColor: NSColor.labelColor], range: range)
        }
        let summary = signature.documentation?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if !summary.isEmpty {
            result.append(NSAttributedString(string: "\n" + summary, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        return result
    }
}
