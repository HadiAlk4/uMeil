import AppKit
import Testing
@testable import uMeil

/// What each key sends in the serial monitor's per-key mode.
@MainActor
struct SerialKeysTests {
    @Test func lettersAndSymbolsSendThemselves() {
        #expect(bytes("a") == Array("a".utf8))
        #expect(bytes("A", modifiers: .shift) == Array("A".utf8))
        #expect(bytes("7") == Array("7".utf8))
        #expect(bytes(" ") == [0x20])
        #expect(bytes("é", ignoringModifiers: "e", modifiers: .option) == Array("é".utf8))
    }

    @Test func escapeSendsEsc() {
        #expect(bytes("\u{1B}", keyCode: 53) == [0x1B])
    }

    @Test func returnSendsTheChosenLineEnding() {
        #expect(bytes("\r", keyCode: 36) == [0x0D])
        #expect(bytes("\r", keyCode: 36, returnKey: .both) == [0x0D, 0x0A])
        #expect(bytes("\r", keyCode: 36, returnKey: .lineFeed) == [0x0A])
        #expect(bytes("\u{3}", keyCode: 76) == [0x0D], "keypad Enter")
    }

    @Test func returnStillSendsACarriageReturnWithNoLineEndingChosen() {
        #expect(bytes("\r", keyCode: 36, returnKey: .none) == [0x0D])
    }

    @Test func editingKeysSendWhatTeraTermSends() {
        #expect(bytes("\u{7F}", keyCode: 51) == [0x08], "Delete sends backspace")
        #expect(bytes("\u{F728}", keyCode: 117) == [0x7F], "forward delete sends DEL")
        #expect(bytes("\t", keyCode: 48) == [0x09])
    }

    @Test func arrowKeysSendVT100Sequences() {
        #expect(bytes("\u{F700}", keyCode: 126) == Array("\u{1B}[A".utf8))
        #expect(bytes("\u{F701}", keyCode: 125) == Array("\u{1B}[B".utf8))
        #expect(bytes("\u{F703}", keyCode: 124) == Array("\u{1B}[C".utf8))
        #expect(bytes("\u{F702}", keyCode: 123) == Array("\u{1B}[D".utf8))
    }

    @Test func controlLettersSendControlCodes() {
        #expect(bytes("\u{3}", ignoringModifiers: "c", modifiers: .control) == [0x03])
        #expect(bytes("\u{1A}", ignoringModifiers: "z", modifiers: .control) == [0x1A])
        #expect(bytes("\u{1}", ignoringModifiers: "A", modifiers: [.control, .shift]) == [0x01])
    }

    @Test func commandShortcutsAndFunctionKeysSendNothing() {
        #expect(bytes("c", modifiers: .command) == nil, "Copy stays a menu shortcut")
        #expect(bytes("\u{F704}", keyCode: 122) == nil, "F1")
        #expect(bytes("") == nil)
    }

    private func bytes(
        _ characters: String,
        ignoringModifiers: String? = nil,
        keyCode: UInt16 = 0,
        modifiers: NSEvent.ModifierFlags = [],
        returnKey: SerialLineEnding = .carriageReturn
    ) -> [UInt8]? {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: false,
            keyCode: keyCode
        )
        return event.flatMap { SerialKeys.bytes(for: $0, returnKey: returnKey) }
    }
}
