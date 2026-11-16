import AppKit

/// What the debugger shows in the editor: breakpoints, lines that have
/// code, and where the program has stopped.
extension EditorViewController {
    /// Lines of the open file that have a breakpoint.
    var breakpointLines: Set<Int> {
        get { ruler?.breakpointLines ?? [] }
        set { ruler?.breakpointLines = newValue }
    }

    /// Lines of the open file that have machine code.
    var executableLines: Set<Int> {
        get { ruler?.executableLines ?? [] }
        set { ruler?.executableLines = newValue }
    }

    /// The line the stopped program will run next, if it is in this file.
    var executionLine: Int? { ruler?.programCounterLine }

    /// Called with a line number when the user clicks it in the gutter.
    var onClickGutterLine: ((Int) -> Void)? {
        get { ruler?.onClickLine }
        set {
            loadViewIfNeeded()
            ruler?.onClickLine = newValue
        }
    }

    /// The line the cursor is on, counting from 1.
    var cursorLine: Int {
        lineIndex.lineNumber(atOffset: textView.selectedRange().location)
    }

    /// Marks `line` as the one the stopped program will run next, with an
    /// arrow in the gutter and a green band behind the code, and scrolls to
    /// it. `nil` removes the mark.
    func showExecutionLine(_ line: Int?) {
        guard let layoutManager = textView.layoutManager else { return }
        let everything = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: everything)
        ruler?.programCounterLine = line

        guard let line, let range = lineIndex.range(ofLine: line) else { return }
        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: EditorTheme.executionLineColor,
            forCharacterRange: range
        )
        textView.scrollRangeToVisible(range)
    }

    /// Removes every debugger mark, as when another file is opened.
    func clearDebugMarks() {
        showExecutionLine(nil)
        breakpointLines = []
        executableLines = []
        textView.toolTip = nil
    }

    /// While a debug session runs the code must match what is on the chip,
    /// so it cannot be edited.
    var isReadOnly: Bool {
        get { !textView.isEditable }
        set { textView.isEditable = !newValue }
    }

    /// Extracts the C identifier at `characterIndex` in the editor's text.
    func identifier(atCharacterIndex characterIndex: Int) -> String? {
        let chars = Array(textView.string.utf16)
        guard chars.indices.contains(characterIndex),
              Self.isIdentifierChar(chars[characterIndex])
        else { return nil }

        var start = characterIndex
        while start > 0 && Self.isIdentifierChar(chars[start - 1]) {
            start -= 1
        }
        guard !Self.isDigitChar(chars[start]) else { return nil }

        var end = characterIndex + 1
        while end < chars.count && Self.isIdentifierChar(chars[end]) {
            end += 1
        }
        return String(utf16CodeUnits: Array(chars[start..<end]), count: end - start)
    }

    /// Evaluates the identifier at `characterIndex` and puts `"name = value"`
    /// in the editor's tooltip.
    @discardableResult
    func showHoverValue(atCharacterIndex characterIndex: Int) async -> String? {
        guard let name = identifier(atCharacterIndex: characterIndex),
              let value = await onHoverIdentifier?(name)
        else {
            textView.toolTip = nil
            return nil
        }
        let tip = "\(name) = \(value)"
        textView.toolTip = tip
        return tip
    }

    private static func isIdentifierChar(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x61 && unit <= 0x7A)
            || (unit >= 0x30 && unit <= 0x39)
            || unit == 0x5F
    }

    private static func isDigitChar(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }
}
