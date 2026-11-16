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
    }

    /// While a debug session runs the code must match what is on the chip,
    /// so it cannot be edited.
    var isReadOnly: Bool {
        get { !textView.isEditable }
        set { textView.isEditable = !newValue }
    }
}
