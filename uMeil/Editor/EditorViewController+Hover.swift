import AppKit

/// Hovering over a name shows what `clangd` knows about it: a function's
/// declaration and documentation, a variable's type, or a macro's value
/// (`GPIO_PIN_1` shows `0x00000002`).
@MainActor
extension EditorViewController {
    var hoverPanel: CodeInfoPanel { intelligence.hoverPanel }

    /// Asks `clangd` about the name at `characterIndex` and shows the answer
    /// under it. Returns the text shown, or `nil` when there was none.
    @discardableResult
    func showCodeHover(atCharacterIndex characterIndex: Int) async -> String? {
        guard intelligence.isEnabled,
              let url = document?.url,
              SourceLanguage(url: url) == .c,
              let onHoverRequested = intelligence.onHoverRequested,
              let wordRange = identifierRange(atCharacterIndex: characterIndex)
        else { return nil }

        let version = textVersion
        let position = lineIndex.lspPosition(atUTF16Offset: characterIndex)
        let hover = await onHoverRequested(url, textView.string, position)
        guard !Task.isCancelled,
              intelligence.isEnabled,
              version == textVersion,
              document?.url == url,
              intelligence.hoverRange.map({ NSLocationInRange(characterIndex, $0) }) ?? true,
              let hover
        else { return nil }

        let text = Self.hoverText(hover.contents)
        guard !text.isEmpty else { return nil }
        let word = textView.firstRect(forCharacterRange: wordRange, actualRange: nil)
        hoverPanel.show(Self.hoverAttributedText(text), near: word, placement: .below, parentWindow: view.window)
        intelligence.hoverRange = wordRange
        return text
    }

    func dismissCodeHover() {
        intelligence.hoverRange = nil
        hoverPanel.dismiss()
    }

    /// Tidies `clangd`'s plain-text hover: drops blank-line runs and the
    /// horizontal rules it puts between sections, and keeps it short.
    static func hoverText(_ contents: String) -> String {
        var lines: [String] = []
        for raw in contents.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.allSatisfy({ $0 == "-" || $0 == "_" || $0 == "*" }) && !line.isEmpty { continue }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(raw.replacingOccurrences(of: "\t", with: "    "))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.count > 18 {
            lines = Array(lines.prefix(18)) + ["…"]
        }
        return lines.joined(separator: "\n")
    }

    /// The first line (what the name is) in bold, code lines in the editor font.
    static func hoverAttributedText(_ text: String) -> NSAttributedString {
        let codeFont = EditorTheme.font.withSize(max(EditorTheme.font.pointSize - 1, 10))
        let result = NSMutableAttributedString()
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let isCode = line.hasPrefix("#define") || line.hasPrefix("//") || line.contains("(") || line.contains(";")
            let font: NSFont = if index == 0 {
                .boldSystemFont(ofSize: 12)
            } else if isCode {
                codeFont
            } else {
                .systemFont(ofSize: 11)
            }
            result.append(NSAttributedString(string: line, attributes: [
                .font: font,
                .foregroundColor: index == 0 ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]))
        }
        return result
    }
}
