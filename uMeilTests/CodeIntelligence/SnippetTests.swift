import AppKit
import Testing
@testable import uMeil

struct LSPSnippetTests {
    @Test func turnsClangdPlaceholdersIntoShortArgumentNames() {
        let snippet = LSPSnippet(
            parsing: "GPIOPinWrite(${1:uint32_t ui32Port}, ${2:uint8_t ui8Pins}, ${3:uint8_t ui8Val})"
        )

        #expect(snippet.text == "GPIOPinWrite(ui32Port, ui8Pins, ui8Val)")
        let names = snippet.placeholders.map { (snippet.text as NSString).substring(with: $0) }
        #expect(names == ["ui32Port", "ui8Pins", "ui8Val"])
        #expect(snippet.finalOffset == nil)
    }

    @Test func keepsTabOrderFinalStopAndEscapes() {
        let snippet = LSPSnippet(parsing: "f(${2:b}, ${1:a})$0 \\$x \\}", shortenParameters: false)

        #expect(snippet.text == "f(b, a) $x }")
        let names = snippet.placeholders.map { (snippet.text as NSString).substring(with: $0) }
        #expect(names == ["a", "b"])
        #expect(snippet.finalOffset == 7)
    }

    @Test func handlesBareAndEmptyTabStops() {
        let snippet = LSPSnippet(parsing: "for ($1; ${2}; ) {$0}")
        #expect(snippet.text == "for (; ; ) {}")
        #expect(snippet.placeholders == [NSRange(location: 5, length: 0), NSRange(location: 7, length: 0)])
        #expect(snippet.finalOffset == 12)
    }

    @Test func leavesPlainDollarSignsAlone() {
        #expect(LSPSnippet(parsing: "cost $ 5 ${x}").text == "cost $ 5 ${x}")
    }

    @Test func shortensOnlyPlainTypedParameters() {
        #expect(LSPSnippet.shortParameterName("uint32_t ui32Port") == "ui32Port")
        #expect(LSPSnippet.shortParameterName("const char *pcString") == "pcString")
        #expect(LSPSnippet.shortParameterName("void (*pfnHandler)(void)") == "void (*pfnHandler)(void)")
        #expect(LSPSnippet.shortParameterName("...") == "...")
        #expect(LSPSnippet.shortParameterName("count") == "count")
    }

    @Test func completionItemsOnlyParseSnippetsWhenMarkedAsSnippets() {
        let plain = LSPCompletionItem(label: "x", insertText: "a$1")
        #expect(plain.snippet.text == "a$1")
        let snippet = LSPCompletionItem(label: "x", insertText: "a$1", insertTextFormat: 2)
        #expect(snippet.snippet.text == "a")
    }
}

struct SnippetPlaceholdersTests {
    private func makePlaceholders() throws -> SnippetPlaceholders {
        // "    GPIOPinWrite(ui32Port, ui8Pins, ui8Val)" inserted at offset 4.
        let snippet = LSPSnippet(
            parsing: "GPIOPinWrite(${1:uint32_t ui32Port}, ${2:uint8_t ui8Pins}, ${3:uint8_t ui8Val})"
        )
        return try #require(SnippetPlaceholders(snippet: snippet, insertedAt: 4))
    }

    @Test func typingIntoAPlaceholderGrowsItAndShiftsTheRest() throws {
        var placeholders = try makePlaceholders()
        #expect(placeholders.currentRange == NSRange(location: 17, length: 8))

        // Replace "ui32Port" with "GPIO_PORTN_BASE" (15 characters).
        let applied = placeholders.apply(edit: NSRange(location: 17, length: 8), replacementLength: 15)
        #expect(applied)
        #expect(placeholders.ranges == [
            NSRange(location: 17, length: 15),
            NSRange(location: 34, length: 7),
            NSRange(location: 43, length: 6)
        ])
        #expect(placeholders.finalOffset == 50)
    }

    @Test func tabWalksForwardThenEnds() throws {
        var placeholders = try makePlaceholders()
        let second = placeholders.next()
        let third = placeholders.next()
        let pastTheEnd = placeholders.next()
        let back = placeholders.previous()
        #expect(second == NSRange(location: 27, length: 7))
        #expect(third == NSRange(location: 36, length: 6))
        #expect(pastTheEnd == nil)
        #expect(back == NSRange(location: 27, length: 7))
    }

    @Test func editsBeforeTheSnippetShiftEverything() throws {
        var placeholders = try makePlaceholders()
        let applied = placeholders.apply(edit: NSRange(location: 0, length: 0), replacementLength: 2)
        #expect(applied)
        #expect(placeholders.ranges.first == NSRange(location: 19, length: 8))
        #expect(placeholders.finalOffset == 45)
    }

    @Test func anEditAcrossAPlaceholderEdgeEndsTheSession() throws {
        var placeholders = try makePlaceholders()
        let applied = placeholders.apply(edit: NSRange(location: 15, length: 5), replacementLength: 0)
        #expect(!applied)
    }

    @Test func noPlaceholdersMeansNoSession() {
        #expect(SnippetPlaceholders(snippet: LSPSnippet(parsing: "SysCtlReset()"), insertedAt: 0) == nil)
    }
}

@MainActor
struct SnippetInEditorTests {
    private func tab(shift: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
    }

    @Test func acceptingAFunctionSelectsEachArgumentInTurn() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("void f(void) {\n    GPIOPin\n}\n".utf8).write(to: file)

        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        try editor.open(file)
        let text = { editor.textView.string as NSString }

        let end = text().range(of: "GPIOPin\n").location + "GPIOPin".utf16.count
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        editor.intelligence.completionAnchorOffset = end - "GPIOPin".utf16.count
        editor.acceptCompletion(LSPCompletionItem(
            label: " GPIOPinWrite(uint32_t ui32Port, uint8_t ui8Pins, uint8_t ui8Val)",
            kind: .function,
            insertText: "GPIOPinWrite(${1:uint32_t ui32Port}, ${2:uint8_t ui8Pins}, ${3:uint8_t ui8Val})",
            insertTextFormat: 2
        ))

        #expect(editor.textView.string == "void f(void) {\n    GPIOPinWrite(ui32Port, ui8Pins, ui8Val)\n}\n")
        #expect(text().substring(with: editor.textView.selectedRange()) == "ui32Port")

        editor.textView.insertText("GPIO_PORTN_BASE", replacementRange: editor.textView.selectedRange())
        #expect(editor.handlePlaceholderKey(try tab()))
        #expect(text().substring(with: editor.textView.selectedRange()) == "ui8Pins")

        editor.textView.insertText("GPIO_PIN_1", replacementRange: editor.textView.selectedRange())
        #expect(editor.handlePlaceholderKey(try tab()))
        #expect(text().substring(with: editor.textView.selectedRange()) == "ui8Val")
        #expect(editor.handlePlaceholderKey(try tab(shift: true)))
        #expect(text().substring(with: editor.textView.selectedRange()) == "GPIO_PIN_1")
        #expect(editor.handlePlaceholderKey(try tab()))

        editor.textView.insertText("0", replacementRange: editor.textView.selectedRange())
        #expect(editor.handlePlaceholderKey(try tab()))
        #expect(editor.snippetPlaceholders == nil)
        #expect(editor.textView.string
            == "void f(void) {\n    GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0)\n}\n")
        // The cursor lands after the closing parenthesis, ready for the ';'.
        #expect(editor.textView.selectedRange().location == text().range(of: "0)").location + 2)
        // With no placeholders left, Tab goes back to inserting a tab.
        #expect(!editor.handlePlaceholderKey(try tab()))
    }

    @Test func movingTheCursorAwayEndsThePlaceholders() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("void f(void) {\n    \n}\n".utf8).write(to: file)

        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        try editor.open(file)
        editor.insertSnippet(LSPSnippet(parsing: "SysCtlDelay(${1:uint32_t ui32Count})"),
                             replacing: NSRange(location: 19, length: 0))
        #expect(editor.snippetPlaceholders != nil)

        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(editor.snippetPlaceholders == nil)
    }
}
