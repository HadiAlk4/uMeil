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
        cancelHover()
    }

    /// Cancels any pending hover evaluation and clears the editor's hover tooltip.
    func cancelHover() {
        hoverTask?.cancel()
        hoverTask = nil
        clearHoverValue()
    }

    /// While a debug session runs the code must match what is on the chip,
    /// so it cannot be edited.
    var isReadOnly: Bool {
        get { !textView.isEditable }
        set { textView.isEditable = !newValue }
    }

    /// Extracts the C identifier at `characterIndex` in the editor's text.
    func identifier(atCharacterIndex characterIndex: Int) -> String? {
        let text = textView.string as NSString
        guard characterIndex >= 0, characterIndex < text.length,
              Self.isIdentifierCodeUnit(text.character(at: characterIndex))
        else { return nil }

        let start = Self.identifierPrefixRange(in: textView.string, atUTF16Offset: characterIndex).location
        guard !(0x30...0x39).contains(text.character(at: start)) else { return nil }

        var end = characterIndex + 1
        while end < text.length, Self.isIdentifierCodeUnit(text.character(at: end)) {
            end += 1
        }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    /// Shows the value of whatever is under the mouse after it rests there
    /// briefly. Values are only found while the debugger is stopped.
    func hoverMoved(toCharacterIndex characterIndex: Int?) {
        hoverTask?.cancel()
        hoverTask = nil
        guard let characterIndex,
              let name = identifier(atCharacterIndex: characterIndex),
              onHoverIdentifier != nil
        else {
            clearHoverValue()
            return
        }
        // Still over the same name: keep its value showing.
        if textView.toolTip?.hasPrefix("\(name) = ") == true { return }
        clearHoverValue()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.showHoverValue(atCharacterIndex: characterIndex)
        }
    }

    /// Evaluates the identifier at `characterIndex` and puts `"name = value"`
    /// in the editor's tooltip.
    @discardableResult
    func showHoverValue(atCharacterIndex characterIndex: Int) async -> String? {
        guard let name = identifier(atCharacterIndex: characterIndex) else {
            clearHoverValue()
            return nil
        }
        let startURL = document?.url
        guard let value = await onHoverIdentifier?(name) else {
            if !Task.isCancelled, document?.url == startURL {
                clearHoverValue()
            }
            return nil
        }
        guard !Task.isCancelled,
              document?.url == startURL,
              identifier(atCharacterIndex: characterIndex) == name
        else {
            return nil
        }
        let tip = "\(name) = \(value)"
        textView.toolTip = tip
        return tip
    }

    private func clearHoverValue() {
        if textView.toolTip != nil {
            textView.toolTip = nil
        }
    }
}
