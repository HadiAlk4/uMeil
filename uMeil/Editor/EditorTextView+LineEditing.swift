import AppKit

/// Per-text-view state for `⌘D` multi-occurrence selection and synchronized renaming.
final class MultiOccurrenceState {
    var session: MultiOccurrenceSession?
    var isUpdatingSelection = false
    var isApplyingEdit = false
}

/// Line-editing (`⌥↑`, `⌥↓`, `⇧⌥↓`) and select-next-occurrence (`⌘D`) actions for `EditorTextView`.
extension EditorTextView {
    private static let relevantShortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    private static let escapeKeyCode: UInt16 = 53

    var multiOccurrenceRanges: [NSRange] { multiOccurrence.session?.ranges ?? [] }
    var isMultiOccurrenceActive: Bool { multiOccurrence.session != nil }
    private var isMultiCursorEditingActive: Bool { (multiOccurrence.session?.ranges.count ?? 0) > 1 }

    // MARK: - Menu and keyboard actions

    @objc func moveLineUp(_ sender: Any?) {
        endMultiOccurrenceSession()
        guard isEditable, let edit = LineEditing.moveLinesUp(in: string, selection: selectedRange()) else { return }
        applyLineEdit(edit)
    }

    @objc func moveLineDown(_ sender: Any?) {
        endMultiOccurrenceSession()
        guard isEditable, let edit = LineEditing.moveLinesDown(in: string, selection: selectedRange()) else { return }
        applyLineEdit(edit)
    }

    @objc func duplicateLineDown(_ sender: Any?) {
        endMultiOccurrenceSession()
        guard isEditable else { return }
        applyLineEdit(LineEditing.duplicateLinesDown(in: string, selection: selectedRange()))
    }

    @objc func selectNextOccurrence(_ sender: Any?) {
        guard isSelectable,
              let nextSession = LineEditing.selectNextOccurrence(
                  in: string,
                  currentSelection: selectedRange(),
                  session: multiOccurrence.session
              )
        else { return }
        applyMultiOccurrenceSession(nextSession)
    }

    func handleLineEditingKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(Self.relevantShortcutModifiers)
        let isUpArrow = event.keyCode == Self.upArrowKeyCode || event.specialKey == .upArrow
        let isDownArrow = event.keyCode == Self.downArrowKeyCode || event.specialKey == .downArrow

        if isUpArrow && modifiers == .option {
            moveLineUp(nil)
            return true
        }
        if isDownArrow && modifiers == .option {
            moveLineDown(nil)
            return true
        }
        if isDownArrow && modifiers == [.option, .shift] {
            duplicateLineDown(nil)
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            selectNextOccurrence(nil)
            return true
        }
        if event.keyCode == Self.escapeKeyCode && modifiers.isEmpty && isMultiOccurrenceActive {
            endMultiOccurrenceSession()
            return true
        }
        if isMultiOccurrenceActive, isNavigationKeyEvent(event) {
            endMultiOccurrenceSession()
        }
        return false
    }

    func validateLineEditingUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        switch item.action {
        case #selector(moveLineUp(_:)), #selector(moveLineDown(_:)), #selector(duplicateLineDown(_:)):
            return isEditable
        case #selector(selectNextOccurrence(_:)):
            return isSelectable && !(textStorage?.string.isEmpty ?? true)
        default:
            return nil
        }
    }

    // MARK: - Multi-occurrence editing interception

    func handleMultiOccurrenceInsertText(_ insertString: Any, replacementRange: NSRange) -> Bool {
        guard isEditable, isMultiCursorEditingActive, let session = multiOccurrence.session else { return false }
        if replacementRange.location != NSNotFound, replacementRange != selectedRange() {
            endMultiOccurrenceSession()
            return false
        }
        let plainText: String? = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        guard let plainText else { return false }
        applyMultiOccurrenceEdit(LineEditing.applyInsertText(plainText, in: string, session: session))
        return true
    }

    func handleMultiOccurrenceDeleteBackward() -> Bool {
        guard isEditable, isMultiCursorEditingActive, let session = multiOccurrence.session else { return false }
        if let edit = LineEditing.applyDeleteBackward(in: string, session: session) {
            applyMultiOccurrenceEdit(edit)
        }
        return true
    }

    func handleMultiOccurrenceDeleteForward() -> Bool {
        guard isEditable, isMultiCursorEditingActive, let session = multiOccurrence.session else { return false }
        if let edit = LineEditing.applyDeleteForward(in: string, session: session) {
            applyMultiOccurrenceEdit(edit)
        }
        return true
    }

    func handleMultiOccurrencePaste() -> Bool {
        guard isEditable, isMultiCursorEditingActive, let session = multiOccurrence.session else { return false }
        if let pasted = NSPasteboard.general.string(forType: .string) {
            applyMultiOccurrenceEdit(LineEditing.applyInsertText(pasted, in: string, session: session))
        }
        return true
    }

    func handleMultiOccurrenceCancelOperation() -> Bool {
        guard isMultiOccurrenceActive else { return false }
        endMultiOccurrenceSession()
        return true
    }

    /// Moving the cursor, Return, or Tab goes back to a single cursor first.
    func endMultiOccurrenceSessionBefore(_ selector: Selector) {
        if isMultiOccurrenceActive, isExitCommandSelector(selector) {
            endMultiOccurrenceSession()
        }
    }

    func handleSelectionDidChangeForMultiOccurrence() {
        guard !multiOccurrence.isUpdatingSelection,
              !multiOccurrence.isApplyingEdit,
              isMultiOccurrenceActive
        else { return }
        multiOccurrence.session = nil
        needsDisplay = true
    }

    func handleTextDidChangeForMultiOccurrence() {
        guard !multiOccurrence.isApplyingEdit, isMultiOccurrenceActive else { return }
        multiOccurrence.session = nil
        needsDisplay = true
    }

    func endMultiOccurrenceSession() {
        guard let session = multiOccurrence.session else { return }
        let primary = LineEditing.clamp(session.primaryRange, length: (string as NSString).length)
        multiOccurrence.session = nil
        multiOccurrence.isUpdatingSelection = true
        defer { multiOccurrence.isUpdatingSelection = false }
        if selectedRanges.count > 1 || selectedRange() != primary {
            setSelectedRange(primary)
        }
        needsDisplay = true
    }

    // MARK: - Visual highlight for multi-occurrence carets and ranges

    func drawMultiOccurrenceHighlights(in dirtyRect: NSRect) {
        guard let session = multiOccurrence.session,
              session.ranges.count > 1,
              let layoutManager,
              let textContainer,
              let storage = textStorage
        else { return }

        let accent = NSColor.controlAccentColor
        for range in session.ranges {
            let clamped = LineEditing.clamp(range, length: storage.length)
            if clamped.length == 0 {
                guard let caret = caretRect(atUTF16Offset: clamped.location, storage: storage),
                      caret.insetBy(dx: -3, dy: -1).intersects(dirtyRect)
                else { continue }
                accent.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: caret.insetBy(dx: -2, dy: 0), xRadius: 2, yRadius: 2).fill()
                accent.withAlphaComponent(0.95).setFill()
                caret.fill()
            } else {
                let glyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
                var box = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                box.origin.x += textContainerOrigin.x
                box.origin.y += textContainerOrigin.y
                guard box.intersects(dirtyRect) else { continue }
                accent.withAlphaComponent(0.18).setFill()
                let rounded = NSBezierPath(roundedRect: box.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3)
                rounded.fill()
                accent.withAlphaComponent(0.55).setStroke()
                rounded.lineWidth = 1
                rounded.stroke()
            }
        }
    }

    // MARK: - Private helpers

    private func applyMultiOccurrenceSession(_ session: MultiOccurrenceSession) {
        multiOccurrence.session = session
        multiOccurrence.isUpdatingSelection = true
        defer { multiOccurrence.isUpdatingSelection = false }

        if session.ranges.allSatisfy({ $0.length > 0 }) {
            setSelectedRanges(session.ranges.map(NSValue.init(range:)), affinity: .downstream, stillSelecting: false)
        } else {
            setSelectedRange(session.primaryRange)
        }
        scrollRangeToVisible(session.lastAddedRange)
        needsDisplay = true
    }

    private func applyMultiOccurrenceEdit(_ edit: MultiOccurrenceEdit) {
        guard isEditable, let storage = textStorage, !edit.replacements.isEmpty else { return }
        let previousSelection = selectedRange()
        multiOccurrence.isApplyingEdit = true
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
            multiOccurrence.isApplyingEdit = false
        }
        undoManager?.registerUndo(withTarget: self) { target in
            target.setSelectedRange(previousSelection)
        }

        for item in edit.replacements.reversed() {
            breakUndoCoalescing()
            guard shouldChangeText(in: item.range, replacementString: item.text) else { return }
            replaceStorageCharacters(in: item.range, with: item.text, storage: storage)
        }
        didChangeText()

        if edit.updatedSession.ranges.count > 1 {
            applyMultiOccurrenceSession(edit.updatedSession)
        } else {
            multiOccurrence.session = nil
            if let single = edit.updatedSession.ranges.first { setSelectedRange(single) }
            needsDisplay = true
        }
    }

    private func applyLineEdit(_ edit: LineEditResult) {
        guard isEditable, let storage = textStorage else { return }
        let previousSelection = selectedRange()
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
        }
        undoManager?.registerUndo(withTarget: self) { target in
            target.setSelectedRange(previousSelection)
        }
        guard shouldChangeText(in: edit.affectedRange, replacementString: edit.replacement) else { return }
        replaceStorageCharacters(in: edit.affectedRange, with: edit.replacement, storage: storage)
        didChangeText()
        setSelectedRange(edit.newSelection)
        scrollRangeToVisible(edit.newSelection)
    }

    private func replaceStorageCharacters(in range: NSRange, with replacement: String, storage: NSTextStorage) {
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        let insertedLength = (replacement as NSString).length
        if insertedLength > 0, !typingAttributes.isEmpty {
            storage.setAttributes(typingAttributes, range: NSRange(location: range.location, length: insertedLength))
        }
        storage.endEditing()
    }

    private func caretRect(atUTF16Offset offset: Int, storage: NSTextStorage) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let clamped = min(max(offset, 0), storage.length)
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding

        if storage.length == 0 {
            let lineHeight = layoutManager.defaultLineHeight(for: font ?? EditorTheme.font)
            return NSRect(x: origin.x + padding, y: origin.y, width: 2, height: lineHeight)
        }
        if clamped == storage.length {
            let lastChar = (storage.string as NSString).character(at: storage.length - 1)
            if lastChar == 0x0A, !layoutManager.extraLineFragmentRect.isEmpty {
                let extra = layoutManager.extraLineFragmentRect
                let caretX = origin.x + extra.minX + padding
                return NSRect(x: caretX, y: origin.y + extra.minY, width: 2, height: extra.height)
            }
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: storage.length - 1)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            return NSRect(x: origin.x + usedRect.maxX, y: origin.y + lineRect.minY, width: 2, height: lineRect.height)
        }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clamped)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphIndex)
        let caretX = origin.x + lineRect.minX + location.x
        return NSRect(x: caretX, y: origin.y + lineRect.minY, width: 2, height: lineRect.height)
    }

    private func isNavigationKeyEvent(_ event: NSEvent) -> Bool {
        let arrowCodes: Set<UInt16> = [
            Self.leftArrowKeyCode, Self.rightArrowKeyCode, Self.upArrowKeyCode, Self.downArrowKeyCode
        ]
        if arrowCodes.contains(event.keyCode) { return true }
        switch event.specialKey {
        case .leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end, .pageUp, .pageDown: return true
        default: return false
        }
    }

    private func isExitCommandSelector(_ selector: Selector) -> Bool {
        let name = NSStringFromSelector(selector)
        return name.hasPrefix("move")
            || name.hasPrefix("page")
            || name.hasPrefix("scroll")
            || selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.insertTab(_:))
            || selector == #selector(NSResponder.insertBacktab(_:))
    }
}
