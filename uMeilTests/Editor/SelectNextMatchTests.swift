import AppKit
import Testing
@testable import uMeil

@MainActor
struct SelectNextMatchTests {
    private static var retainedHosts: [HostedEditor] = []

    // MARK: - Pure Word Detection and Match Selection

    @Test func firstCommandDOnEmptySelectionSelectsWordAtOrAdjacentToCaret() throws {
        let text = "int counter_1 = counter_1 + 42;"

        let inside = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: NSRange(location: 7, length: 0), session: nil)
        )
        #expect(inside.ranges == [NSRange(location: 4, length: 9)])
        #expect(inside.searchQuery == "counter_1")
        #expect(inside.wholeWord)

        let trailing = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: NSRange(location: 13, length: 0), session: nil)
        )
        #expect(trailing.ranges == [NSRange(location: 4, length: 9)])

        let opText = "a == b && c == d"
        let opSelection = NSRange(location: 2, length: 0)
        let operatorSession = try #require(
            LineEditing.selectNextOccurrence(in: opText, currentSelection: opSelection, session: nil)
        )
        #expect(operatorSession.ranges == [NSRange(location: 2, length: 2)])
        #expect(operatorSession.searchQuery == "==")

        #expect(
            LineEditing.selectNextOccurrence(in: "   ", currentSelection: NSRange(location: 1, length: 0), session: nil)
                == nil
        )
    }

    @Test func wholeWordSessionSkipsPartialMatchesAndWrapsAround() throws {
        let text = "foo foobar _foo foo foo1 foo"

        let first = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: NSRange(location: 17, length: 0), session: nil)
        )
        #expect(first.ranges == [NSRange(location: 16, length: 3)])
        #expect(first.wholeWord)

        let second = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: first.primaryRange, session: first)
        )
        #expect(second.ranges == [NSRange(location: 16, length: 3), NSRange(location: 25, length: 3)])

        let third = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: second.primaryRange, session: second)
        )
        #expect(
            third.ranges == [
                NSRange(location: 0, length: 3),
                NSRange(location: 16, length: 3),
                NSRange(location: 25, length: 3)
            ]
        )

        let fourth = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: third.primaryRange, session: third)
        )
        #expect(fourth == third)
    }

    @Test func manualNonEmptySelectionUsesSubstringMatchingAndAddsNextMatchImmediately() throws {
        let text = "foo + foobar + oo"

        let first = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: NSRange(location: 1, length: 2), session: nil)
        )
        #expect(!first.wholeWord)
        #expect(first.ranges == [NSRange(location: 1, length: 2), NSRange(location: 7, length: 2)])

        let second = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: first.primaryRange, session: first)
        )
        #expect(
            second.ranges == [
                NSRange(location: 1, length: 2),
                NSRange(location: 7, length: 2),
                NSRange(location: 15, length: 2)
            ]
        )
    }

    @Test func multiOccurrenceTransformationsKeepRangesSynchronizedAcrossEdits() throws {
        let text = "int val = val + val;"
        var session = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: NSRange(location: 4, length: 0), session: nil)
        )
        session = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: session.primaryRange, session: session)
        )
        session = try #require(
            LineEditing.selectNextOccurrence(in: text, currentSelection: session.primaryRange, session: session)
        )
        #expect(
            session.ranges == [
                NSRange(location: 4, length: 3),
                NSRange(location: 10, length: 3),
                NSRange(location: 16, length: 3)
            ]
        )

        let typeX = LineEditing.applyInsertText("x", in: text, session: session)
        let afterX = typeX.applying(to: text)
        #expect(afterX == "int x = x + x;")
        #expect(
            typeX.updatedSession.ranges == [
                NSRange(location: 5, length: 0),
                NSRange(location: 9, length: 0),
                NSRange(location: 13, length: 0)
            ]
        )

        let type1 = LineEditing.applyInsertText("1", in: afterX, session: typeX.updatedSession)
        let afterX1 = type1.applying(to: afterX)
        #expect(afterX1 == "int x1 = x1 + x1;")
        #expect(
            type1.updatedSession.ranges == [
                NSRange(location: 6, length: 0),
                NSRange(location: 11, length: 0),
                NSRange(location: 16, length: 0)
            ]
        )

        let backspace = try #require(LineEditing.applyDeleteBackward(in: afterX1, session: type1.updatedSession))
        #expect(backspace.applying(to: afterX1) == "int x = x + x;")
        #expect(
            backspace.updatedSession.ranges == [
                NSRange(location: 5, length: 0),
                NSRange(location: 9, length: 0),
                NSRange(location: 13, length: 0)
            ]
        )
    }
}

// MARK: - EditorTextView Integration, Rename, Escape, Undo, and Menu Wiring

extension SelectNextMatchTests {
    @MainActor
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
        window.makeFirstResponder(textView)
        textView.string = text
        textView.undoManager?.removeAllActions()
        let hosted = HostedEditor(window: window, editor: editor, textView: textView)
        Self.retainedHosts.append(hosted)
        return hosted
    }

    @MainActor
    @Test func commandDSelectsOccurrencesAndTypingBackspacePasteRenameAllTogether() throws {
        let hosted = try makeHostedEditor(text: "int pin = pin + pin;\n")
        let textView = hosted.textView
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        textView.selectNextOccurrence(nil)
        #expect(textView.selectedRanges.map(\.rangeValue) == [NSRange(location: 4, length: 3)])
        #expect(textView.multiOccurrenceRanges == [NSRange(location: 4, length: 3)])

        textView.selectNextOccurrence(nil)
        textView.selectNextOccurrence(nil)
        let expectedThree = [
            NSRange(location: 4, length: 3),
            NSRange(location: 10, length: 3),
            NSRange(location: 16, length: 3)
        ]
        #expect(textView.selectedRanges.map(\.rangeValue) == expectedThree)
        #expect(textView.multiOccurrenceRanges == expectedThree)

        textView.deleteBackward(nil)
        #expect(textView.string == "int  =  + ;\n")
        #expect(textView.isMultiOccurrenceActive)
        #expect(
            textView.multiOccurrenceRanges == [
                NSRange(location: 4, length: 0),
                NSRange(location: 7, length: 0),
                NSRange(location: 10, length: 0)
            ]
        )

        // Drawing the extra carets must not crash.
        let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        textView.insertText("led", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "int ledz = ledz + ledz;\n")

        textView.deleteBackward(nil)
        #expect(textView.string == "int led = led + led;\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("_0", forType: .string)
        textView.paste(nil)
        #expect(textView.string == "int led_0 = led_0 + led_0;\n")
    }

    @MainActor
    @Test func deleteForwardUpdatesAllOccurrencesInMultiOccurrenceSession() throws {
        let hosted = try makeHostedEditor(text: "ab + ab")
        let textView = hosted.textView
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        textView.selectNextOccurrence(nil)
        #expect(textView.multiOccurrenceRanges == [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1)])

        textView.deleteForward(nil)
        #expect(textView.string == "b + b")
        #expect(textView.multiOccurrenceRanges == [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)])

        textView.deleteForward(nil)
        #expect(textView.string == " + ")
        #expect(textView.multiOccurrenceRanges == [NSRange(location: 0, length: 0), NSRange(location: 3, length: 0)])
    }

    @MainActor
    @Test func multiOccurrenceEditsAreGroupedIntoSingleUndoSteps() throws {
        let hosted = try makeHostedEditor(text: "foo = foo;")
        let textView = hosted.textView
        let undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.selectNextOccurrence(nil)
        textView.selectNextOccurrence(nil)
        #expect(textView.multiOccurrenceRanges.count == 2)

        textView.insertText("bar", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "bar = bar;")

        textView.insertText("2", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "bar2 = bar2;")

        undoManager.undo()
        #expect(textView.string == "bar = bar;")

        undoManager.undo()
        #expect(textView.string == "foo = foo;")
    }

    @MainActor
    @Test func escapeNavigationMouseClickAndFocusLossExitMultiOccurrenceMode() throws {
        let hosted = try makeHostedEditor(text: "foo + foo + foo")
        let textView = hosted.textView

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.selectNextOccurrence(nil)
        textView.selectNextOccurrence(nil)
        #expect(textView.multiOccurrenceRanges.count == 2)

        textView.cancelOperation(nil)
        #expect(!textView.isMultiOccurrenceActive)
        #expect(textView.selectedRanges.count == 1)

        textView.insertText("bar", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "bar + foo + foo")

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.selectNextOccurrence(nil)
        textView.selectNextOccurrence(nil)
        #expect(textView.multiOccurrenceRanges.count == 2)

        textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(!textView.isMultiOccurrenceActive)
        #expect(textView.selectedRanges.count == 1)

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.selectNextOccurrence(nil)
        textView.selectNextOccurrence(nil)
        #expect(textView.isMultiOccurrenceActive)

        _ = hosted.window.makeFirstResponder(nil)
        #expect(!textView.isMultiOccurrenceActive)
    }

    @MainActor
    @Test func editMenuWiresSelectNextOccurrenceToCommandD() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let edit = try #require(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let item = try #require(edit.items.first { $0.title == "Select Next Occurrence" })

        #expect(item.action == #selector(EditorTextView.selectNextOccurrence(_:)))
        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == [.command])
    }
}
