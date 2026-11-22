import AppKit

/// `NSTextView` subclass adding Cmd+Click definition jumps, context menu jump,
/// and keyboard routing for the non-activating completion popup.
final class EditorTextView: NSTextView {
    /// Called with the UTF-16 character index when the user Cmd+Clicks on text
    /// or picks Jump to Definition from the context menu over it.
    var onCommandClick: ((Int) -> Void)?
    /// Called with the UTF-16 character index under the mouse as it moves over
    /// the text, or `nil` when it is over no character or leaves the view.
    var onHoverCharacter: ((Int?) -> Void)?
    /// Called when the user invokes autocomplete (`Ctrl+Space` or `Esc`/`F5` `complete(_:)`).
    var onRequestCompletion: (() -> Void)?
    /// Called when the user presses F2 to rename the symbol at the cursor.
    var onRequestRename: (() -> Void)?
    /// Called first on `keyDown` so an open completion popup can intercept arrows, Return, Tab, and Esc.
    var completionKeyHandler: ((NSEvent) -> Bool)?
    /// Called when the user clicks an inline diagnostic quick-fix badge.
    var onQuickFixClick: ((LSPCodeAction) -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    /// The last build's messages, drawn at the ends of their lines.
    var inlineMessages: [InlineMessage] = [] {
        didSet {
            if inlineMessages != oldValue { needsDisplay = true }
        }
    }

    /// Live diagnostics with one-click fixes, drawn as interactive capsules.
    var inlineQuickFixes: [InlineQuickFix] = [] {
        didSet {
            if inlineQuickFixes != oldValue { needsDisplay = true }
        }
    }

    /// Values drawn after the ends of lines while debugging, such as `count = 4`.
    var inlineAnnotations: [InlineAnnotation] = [] {
        didSet {
            if inlineAnnotations != oldValue { needsDisplay = true }
        }
    }

    /// Editor visual highlight state (current line, etc.), drawn behind the text.
    var highlightState = HighlightState()

    /// UTF-16 offset where the stopped execution line begins, or `nil` when not stopped here.
    var executionLineStart: Int? {
        didSet {
            if executionLineStart != oldValue { needsDisplay = true }
        }
    }

    /// Snippet placeholders still to be filled in, shaded behind the text.
    var placeholderRanges: [NSRange] = [] {
        didSet {
            if placeholderRanges != oldValue { needsDisplay = true }
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawExecutionLine(in: rect)
        drawEditorHighlights(in: rect)
        drawPlaceholders(in: rect)
        drawInlineMessages(in: rect)
        drawInlineQuickFixes(in: rect)
        drawInlineAnnotations(in: rect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.isEmpty, handleQuickFixClick(with: event) {
            return
        }
        if modifiers == .command, let offset = characterOffset(for: event) {
            onCommandClick?(offset)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if completionKeyHandler?(event) == true {
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .control, event.charactersIgnoringModifiers == " " {
            onRequestCompletion?()
            return
        }
        if event.specialKey == .f2, modifiers.subtracting([.function, .numericPad]).isEmpty {
            onRequestRename?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Typing aids

    /// Closing brackets and quotes the editor typed, which typing steps over.
    var autoClosedPairs = AutoClosedPairs()

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if let replacementString {
            let length = (replacementString as NSString).length
            autoClosedPairs.textChanged(in: affectedCharRange, replacementLength: length)
        }
        return true
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let selection = selectedRange()
        if ranges.count == 1, selection.length == 0, selection.location <= currentText.length {
            let lineEnd = CodeEditing.lineEnd(in: currentText, at: selection.location)
            autoClosedPairs.cursorMoved(to: selection.location, lineEnd: lineEnd)
        } else {
            autoClosedPairs.removeAll()
        }
    }

    /// What one level of indentation is. Settings decides, unless a test does.
    var indentStyleOverride: IndentStyle?
    var indentStyle: IndentStyle {
        indentStyleOverride ?? AppearanceSettings.shared.indentStyle
    }

    override func insertNewline(_ sender: Any?) {
        if !handleNewline() {
            super.insertNewline(sender)
        }
    }

    /// Typed characters arrive here with no replacement range; text put in by
    /// code, such as an accepted completion, comes with one and is left alone.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        if replacementRange.location == NSNotFound, let typed, handleTyped(typed) {
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertTab(_ sender: Any?) {
        if !handleTab() {
            super.insertTab(sender)
        }
    }

    /// Shift+Tab: every selected line, or the cursor's, moves a level left.
    override func insertBacktab(_ sender: Any?) {
        shiftSelectedLines(.left)
    }

    /// What starts a line comment in the file being edited, such as `//`,
    /// or `nil` for files the editor does not know how to comment.
    var lineCommentPrefix: String?

    /// Edit > Comment Selection (⌘/).
    @objc func toggleComment(_ sender: Any?) {
        guard isEditable, let lineCommentPrefix,
              let edit = CodeEditing.toggleLineComment(
                in: currentText,
                selection: selectedRange(),
                prefix: lineCommentPrefix
              )
        else { return }
        apply(edit)
    }

    /// Edit > Shift Right (⌘]).
    @objc func shiftRight(_ sender: Any?) {
        shiftSelectedLines(.right)
    }

    /// Edit > Shift Left (⌘[).
    @objc func shiftLeft(_ sender: Any?) {
        shiftSelectedLines(.left)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(shiftRight(_:)), #selector(shiftLeft(_:)):
            return isEditable
        case #selector(toggleComment(_:)):
            return isEditable && lineCommentPrefix != nil
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        if !handleDeleteBackward() {
            super.deleteBackward(sender)
        }
    }

    override func complete(_ sender: Any?) {
        onRequestCompletion?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateQuickFixHover(with: event)
        onHoverCharacter?(characterOffset(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearQuickFixHover()
        onHoverCharacter?(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let contextMenu = super.menu(for: event) ?? NSMenu()
        let jumpItem: NSMenuItem
        if let offset = characterOffset(for: event) {
            // Right-clicking does not move the cursor, so jump from the
            // symbol that was clicked rather than the one at the cursor.
            jumpItem = NSMenuItem(
                title: "Jump to Definition",
                action: #selector(jumpToClickedDefinition(_:)),
                keyEquivalent: ""
            )
            jumpItem.target = self
            jumpItem.representedObject = offset
        } else {
            jumpItem = NSMenuItem(
                title: "Jump to Definition",
                action: #selector(MainWindowController.jumpToDefinitionMenuAction(_:)),
                keyEquivalent: ""
            )
        }
        contextMenu.insertItem(jumpItem, at: 0)
        contextMenu.insertItem(.separator(), at: 1)
        return contextMenu
    }

    @objc private func jumpToClickedDefinition(_ sender: NSMenuItem) {
        guard let offset = sender.representedObject as? Int else { return }
        onCommandClick?(offset)
    }

    private func drawExecutionLine(in dirtyRect: NSRect) {
        guard let lineStart = executionLineStart,
              let layoutManager,
              let storage = textStorage,
              lineStart >= 0,
              lineStart <= storage.length
        else { return }

        var lineRect: NSRect
        if lineStart < storage.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: lineStart)
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            lineRect = layoutManager.extraLineFragmentRect
        }
        guard lineRect.height > 0 else { return }

        lineRect = lineRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let band = NSRect(x: bounds.minX, y: lineRect.minY, width: bounds.width, height: lineRect.height)
        guard band.intersects(dirtyRect) else { return }

        EditorTheme.executionLineColor.setFill()
        band.fill(using: .sourceOver)
    }

    private func drawPlaceholders(in rect: NSRect) {
        guard !placeholderRanges.isEmpty, let layoutManager, let textContainer, let storage = textStorage else {
            return
        }
        EditorTheme.placeholderBackgroundColor.setFill()
        for range in placeholderRanges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            guard clamped.length > 0 || range.length == 0 else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
            var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            box.origin.x += textContainerOrigin.x
            box.origin.y += textContainerOrigin.y
            if clamped.length == 0 { box.size.width = 2 }
            guard box.intersects(rect) else { continue }
            NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
    }

    private func characterOffset(for event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else {
            return nil
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard lineRect.insetBy(dx: -4, dy: -2).contains(containerPoint) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return charIndex < storage.length ? charIndex : nil
    }
}
