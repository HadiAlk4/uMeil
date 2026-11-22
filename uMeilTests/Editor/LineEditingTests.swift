import AppKit
import Testing
@testable import uMeil

@MainActor
struct LineEditingTests {
    private static var retainedHosts: [HostedEditor] = []

    // MARK: - Pure Move Line Up / Down

    @Test func moveLineUpSwapsWithLineAboveAndPreservesCaretOffset() throws {
        let text = "first\nsecond\nthird\n"
        // Caret between 'e' and 'c' in "second" (offset 6 + 2 = 8).
        let edit = try #require(LineEditing.moveLinesUp(in: text, selection: NSRange(location: 8, length: 0)))

        #expect(edit.applying(to: text) == "second\nfirst\nthird\n")
        #expect(edit.newSelection == NSRange(location: 2, length: 0))
    }

    @Test func moveLineDownSwapsWithLineBelowAndPreservesCaretOffset() throws {
        let text = "first\nsecond\nthird\n"
        // Caret between 'i' and 'r' in "first" (offset 2).
        let edit = try #require(LineEditing.moveLinesDown(in: text, selection: NSRange(location: 2, length: 0)))

        #expect(edit.applying(to: text) == "second\nfirst\nthird\n")
        #expect(edit.newSelection == NSRange(location: 9, length: 0))
    }

    @Test func moveLineAtTopOrBottomBoundaryIsNoOp() {
        #expect(LineEditing.moveLinesUp(in: "first\nsecond\n", selection: NSRange(location: 2, length: 0)) == nil)
        #expect(LineEditing.moveLinesDown(in: "first\nsecond", selection: NSRange(location: 8, length: 0)) == nil)
        #expect(LineEditing.moveLinesDown(in: "first\nsecond\n", selection: NSRange(location: 13, length: 0)) == nil)
    }

    @Test func moveLineInSingleLineAndEmptyFilesIsNoOp() {
        #expect(LineEditing.moveLinesUp(in: "only line", selection: NSRange(location: 3, length: 0)) == nil)
        #expect(LineEditing.moveLinesDown(in: "only line", selection: NSRange(location: 3, length: 0)) == nil)
        #expect(LineEditing.moveLinesUp(in: "", selection: NSRange(location: 0, length: 0)) == nil)
        #expect(LineEditing.moveLinesDown(in: "", selection: NSRange(location: 0, length: 0)) == nil)
    }

    @Test func moveLineHandlesLastLineWithoutTrailingNewline() throws {
        let text = "aaa\nbbb"

        let movedUp = try #require(LineEditing.moveLinesUp(in: text, selection: NSRange(location: 5, length: 0)))
        #expect(movedUp.applying(to: text) == "bbb\naaa")
        #expect(movedUp.newSelection == NSRange(location: 1, length: 0))

        let movedDown = try #require(LineEditing.moveLinesDown(in: text, selection: NSRange(location: 1, length: 0)))
        #expect(movedDown.applying(to: text) == "bbb\naaa")
        #expect(movedDown.newSelection == NSRange(location: 5, length: 0))
    }

    @Test func moveLineDownClampsTrailingNewlineSelectionAtEOFWithoutNewline() throws {
        let text = "aaa\nbbb"
        // Full-line selection including `\n` on line 1.
        let movedDown = try #require(LineEditing.moveLinesDown(in: text, selection: NSRange(location: 0, length: 4)))

        #expect(movedDown.applying(to: text) == "bbb\naaa")
        #expect(movedDown.newSelection == NSRange(location: 4, length: 3))
    }

    @Test func moveLineHandlesEmptyFinalLineAfterTrailingNewline() throws {
        let text = "aaa\nbbb\n"
        // Caret on line 3 (the empty final line at offset 8).
        #expect(LineEditing.moveLinesDown(in: text, selection: NSRange(location: 8, length: 0)) == nil)

        let moveEmptyUp = try #require(LineEditing.moveLinesUp(in: text, selection: NSRange(location: 8, length: 0)))
        let afterUp = moveEmptyUp.applying(to: text)
        #expect(afterUp == "aaa\n\nbbb")
        #expect(moveEmptyUp.newSelection == NSRange(location: 4, length: 0))

        // Round-trip: moving the empty line back down restores the original text.
        let moveEmptyDown = try #require(
            LineEditing.moveLinesDown(in: afterUp, selection: moveEmptyUp.newSelection)
        )
        #expect(moveEmptyDown.applying(to: afterUp) == text)
        #expect(moveEmptyDown.newSelection == NSRange(location: 8, length: 0))

        // Moving line 2 ("bbb") down into the empty final line and back up also round-trips.
        let moveBbbDown = try #require(LineEditing.moveLinesDown(in: text, selection: NSRange(location: 5, length: 0)))
        let afterBbbDown = moveBbbDown.applying(to: text)
        #expect(afterBbbDown == "aaa\n\nbbb")
        #expect(moveBbbDown.newSelection == NSRange(location: 6, length: 0))

        let moveBbbUp = try #require(
            LineEditing.moveLinesUp(in: afterBbbDown, selection: moveBbbDown.newSelection)
        )
        #expect(moveBbbUp.applying(to: afterBbbDown) == text)
        #expect(moveBbbUp.newSelection == NSRange(location: 5, length: 0))
    }

    @Test func moveMultiLineSelectionMovesAllTouchedLines() throws {
        let text = "one\ntwo\nthree\nfour"
        // Select "wo\nthr" spanning lines 2 and 3 (offsets 5..<11).
        let selection = NSRange(location: 5, length: 6)

        let upEdit = try #require(LineEditing.moveLinesUp(in: text, selection: selection))
        let movedUp = upEdit.applying(to: text)
        #expect(movedUp == "two\nthree\none\nfour")
        #expect((movedUp as NSString).substring(with: upEdit.newSelection) == "wo\nthr")

        let downEdit = try #require(LineEditing.moveLinesDown(in: text, selection: selection))
        let movedDown = downEdit.applying(to: text)
        #expect(movedDown == "one\nfour\ntwo\nthree")
        #expect((movedDown as NSString).substring(with: downEdit.newSelection) == "wo\nthr")
    }

    @Test func selectionEndingAtNextLineStartDoesNotIncludeNextLine() throws {
        let text = "aaa\nbbb\nccc\n"
        // Selection is exactly "bbb\n" (offsets 4..<8); must move only line 2, not line 3.
        let edit = try #require(LineEditing.moveLinesUp(in: text, selection: NSRange(location: 4, length: 4)))

        #expect(edit.applying(to: text) == "bbb\naaa\nccc\n")
        #expect(edit.newSelection == NSRange(location: 0, length: 4))
    }

    @Test func moveLinesPreservesCRLFAndUTF16Offsets() throws {
        let crlf = "a😀\r\nbé"
        // Offset 0='a', 1..2='😀', 3='\r', 4='\n', 5='b', 6='é'. Caret after 'b' = 6.
        let edit = try #require(LineEditing.moveLinesUp(in: crlf, selection: NSRange(location: 6, length: 0)))

        #expect(edit.applying(to: crlf) == "bé\r\na😀")
        #expect(edit.newSelection == NSRange(location: 1, length: 0))
    }

    // MARK: - Pure Duplicate Line Down

    @Test func duplicateLineDownCopiesCurrentLineAndMovesCursor() {
        let text = "int a = 1;\nint b = 2;\n"
        let edit = LineEditing.duplicateLinesDown(in: text, selection: NSRange(location: 4, length: 0))

        #expect(edit.applying(to: text) == "int a = 1;\nint a = 1;\nint b = 2;\n")
        #expect(edit.newSelection == NSRange(location: 15, length: 0))
    }

    @Test func duplicateLineDownHandlesMissingTrailingNewlineAndSingleLine() {
        let twoLines = "aaa\nbbb"
        let editLast = LineEditing.duplicateLinesDown(in: twoLines, selection: NSRange(location: 5, length: 0))
        #expect(editLast.applying(to: twoLines) == "aaa\nbbb\nbbb")
        #expect(editLast.newSelection == NSRange(location: 9, length: 0))

        let singleLine = "hello"
        let editSingle = LineEditing.duplicateLinesDown(in: singleLine, selection: NSRange(location: 1, length: 3))
        let resultSingle = editSingle.applying(to: singleLine)
        #expect(resultSingle == "hello\nhello")
        #expect(editSingle.newSelection == NSRange(location: 7, length: 3))
        #expect((resultSingle as NSString).substring(with: editSingle.newSelection) == "ell")
    }

    @Test func duplicateLineDownHandlesEmptyDocumentAndEmptyFinalLine() {
        let emptyEdit = LineEditing.duplicateLinesDown(in: "", selection: NSRange(location: 0, length: 0))
        #expect(emptyEdit.applying(to: "") == "\n")
        #expect(emptyEdit.newSelection == NSRange(location: 1, length: 0))

        let trailingNewline = "aaa\nbbb\n"
        let finalLineEdit = LineEditing.duplicateLinesDown(
            in: trailingNewline,
            selection: NSRange(location: 8, length: 0)
        )
        #expect(finalLineEdit.applying(to: trailingNewline) == "aaa\nbbb\n\n")
        #expect(finalLineEdit.newSelection == NSRange(location: 9, length: 0))
    }

    @Test func duplicateMultiLineSelectionDuplicatesAllTouchedLines() {
        let text = "aaa\nbbb\nccc"
        let selection = NSRange(location: 5, length: 5) // "bb\ncc"
        let edit = LineEditing.duplicateLinesDown(in: text, selection: selection)
        let result = edit.applying(to: text)

        #expect(result == "aaa\nbbb\nccc\nbbb\nccc")
        #expect(edit.newSelection == NSRange(location: 13, length: 5))
        #expect((result as NSString).substring(with: edit.newSelection) == "bb\ncc")
    }
}

// MARK: - EditorTextView Keyboard, Undo, and Menu Wiring

extension LineEditingTests {
    private struct HostedEditor {
        let window: NSWindow
        let editor: EditorViewController
        let textView: EditorTextView
    }

    @MainActor
    private func makeHostedEditor(text: String) throws -> HostedEditor {
        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = editor
        let textView = try #require(editor.textView as? EditorTextView)
        textView.string = text
        textView.undoManager?.removeAllActions()
        let hosted = HostedEditor(window: window, editor: editor, textView: textView)
        Self.retainedHosts.append(hosted)
        return hosted
    }

    @MainActor
    private func arrowKeyEvent(
        keyCode: UInt16,
        scalar: Int,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        let chars = try String(#require(UnicodeScalar(scalar)))
        return try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers.union([.numericPad, .function]),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @MainActor
    @Test func optionArrowKeysMoveAndDuplicateLinesInsteadOfParagraphMovement() throws {
        let hosted = try makeHostedEditor(text: "first\nsecond\nthird\n")
        let textView = hosted.textView
        textView.setSelectedRange(NSRange(location: 8, length: 0)) // "se|cond"

        let optionUp = try arrowKeyEvent(keyCode: 126, scalar: NSUpArrowFunctionKey, modifiers: [.option])
        textView.keyDown(with: optionUp)
        #expect(textView.string == "second\nfirst\nthird\n")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))

        let optionDown = try arrowKeyEvent(keyCode: 125, scalar: NSDownArrowFunctionKey, modifiers: [.option])
        textView.keyDown(with: optionDown)
        #expect(textView.string == "first\nsecond\nthird\n")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))

        let shiftOptionDown = try arrowKeyEvent(
            keyCode: 125,
            scalar: NSDownArrowFunctionKey,
            modifiers: [.option, .shift]
        )
        textView.keyDown(with: shiftOptionDown)
        #expect(textView.string == "first\nsecond\nsecond\nthird\n")
        #expect(textView.selectedRange() == NSRange(location: 15, length: 0))
    }

    @MainActor
    @Test func moveAndDuplicateAreSingleUndoableEdits() throws {
        let hosted = try makeHostedEditor(text: "alpha\nbeta\ngamma\n")
        let textView = hosted.textView
        let undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
        textView.setSelectedRange(NSRange(location: 7, length: 0)) // "b|eta"

        textView.moveLineUp(nil)
        #expect(textView.string == "beta\nalpha\ngamma\n")
        #expect(hosted.editor.isModified)

        textView.duplicateLineDown(nil)
        #expect(textView.string == "beta\nbeta\nalpha\ngamma\n")

        // First undo removes only the duplicate.
        undoManager.undo()
        #expect(textView.string == "beta\nalpha\ngamma\n")

        // Second undo reverses the move.
        undoManager.undo()
        #expect(textView.string == "alpha\nbeta\ngamma\n")
        #expect(textView.selectedRange() == NSRange(location: 7, length: 0))

        // Redo restores step by step.
        undoManager.redo()
        #expect(textView.string == "beta\nalpha\ngamma\n")
    }

    @MainActor
    @Test func readOnlyTextViewDisablesAndIgnoresLineEditingActions() throws {
        let hosted = try makeHostedEditor(text: "one\ntwo\n")
        let textView = hosted.textView
        textView.isEditable = false
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        let moveUpItem = NSMenuItem(
            title: "Move Line Up",
            action: #selector(EditorTextView.moveLineUp(_:)),
            keyEquivalent: ""
        )
        let duplicateItem = NSMenuItem(
            title: "Duplicate Line",
            action: #selector(EditorTextView.duplicateLineDown(_:)),
            keyEquivalent: ""
        )
        #expect(!textView.validateUserInterfaceItem(moveUpItem))
        #expect(!textView.validateUserInterfaceItem(duplicateItem))

        textView.moveLineUp(nil)
        textView.duplicateLineDown(nil)
        #expect(textView.string == "one\ntwo\n")
    }

    @MainActor
    @Test func editMenuWiresMoveAndDuplicateLineShortcuts() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let edit = try #require(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let upKey = try String(#require(UnicodeScalar(NSUpArrowFunctionKey)))
        let downKey = try String(#require(UnicodeScalar(NSDownArrowFunctionKey)))

        let moveUp = try #require(edit.items.first { $0.title == "Move Line Up" })
        #expect(moveUp.action == #selector(EditorTextView.moveLineUp(_:)))
        #expect(moveUp.keyEquivalent == upKey)
        #expect(moveUp.keyEquivalentModifierMask == [.option])

        let moveDown = try #require(edit.items.first { $0.title == "Move Line Down" })
        #expect(moveDown.action == #selector(EditorTextView.moveLineDown(_:)))
        #expect(moveDown.keyEquivalent == downKey)
        #expect(moveDown.keyEquivalentModifierMask == [.option])

        let duplicate = try #require(edit.items.first { $0.title == "Duplicate Line" })
        #expect(duplicate.action == #selector(EditorTextView.duplicateLineDown(_:)))
        #expect(duplicate.keyEquivalent == downKey)
        #expect(duplicate.keyEquivalentModifierMask == [.option, .shift])
    }
}
