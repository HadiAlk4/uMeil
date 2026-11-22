import AppKit
import Testing
@testable import uMeil

/// The serial monitor's mode that sends each key as it is typed, like Tera Term.
@MainActor
struct SerialMonitorKeyModeTests {
    let terminal: PseudoTerminal
    let defaults: UserDefaults
    let monitor: SerialMonitorViewController

    init() throws {
        let suite = "uMeilTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let terminal = try PseudoTerminal()
        self.terminal = terminal
        monitor = SerialMonitorViewController(listPorts: { [info = terminal.info] in [info] }, defaults: defaults)
        monitor.loadViewIfNeeded()
    }

    @Test func sendsALineAtATimeUntilAskedToSendEachKey() {
        #expect(!monitor.sendsEachKey)
        #expect(!monitor.inputField.isHidden)
        #expect(!monitor.sendButton.isHidden)
        #expect(monitor.keyModeHint.isHidden)
        monitor.connect()

        monitor.textView.keyDown(with: key("a"))
        monitor.send("x")

        // The key typed in the console was not sent; only the line was.
        #expect(terminal.receive(2) == Array("x\r".utf8))
    }

    @Test func sendsEachKeyAsItIsTypedInTheConsole() {
        monitor.connect()
        monitor.sendEachKeyCheckbox.performClick(nil)
        #expect(monitor.sendsEachKey)
        #expect(monitor.inputField.isHidden)
        #expect(monitor.sendButton.isHidden)
        #expect(!monitor.keyModeHint.isHidden)

        monitor.textView.keyDown(with: key("9"))
        monitor.textView.keyDown(with: key("a"))
        monitor.textView.keyDown(with: key("\u{1B}", keyCode: 53))
        monitor.textView.keyDown(with: key("\r", keyCode: 36))
        monitor.textView.keyDown(with: key("\u{3}", ignoringModifiers: "c", modifiers: .control))

        #expect(terminal.receive(5) == [0x39, 0x61, 0x1B, 0x0D, 0x03])
    }

    @Test func returnSendsTheChosenLineEndingInKeyMode() {
        monitor.connect()
        monitor.sendsEachKey = true
        monitor.lineEndingPopUp.selectItem(withTitle: "CR LF")

        monitor.textView.keyDown(with: key("\r", keyCode: 36))

        #expect(terminal.receive(2) == [0x0D, 0x0A])
    }

    @Test func pastingInKeyModeSendsTheTextWithLineBreaksAsReturn() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("12\n34\r\n", forType: .string)
        monitor.textView.pasteboard = pasteboard
        monitor.connect()
        monitor.sendsEachKey = true

        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(monitor.textView.validateUserInterfaceItem(paste))
        monitor.textView.paste(nil)

        #expect(terminal.receive(6) == Array("12\r34\r".utf8))
    }

    @Test func keysAreNotSentWhileDisconnected() {
        monitor.sendsEachKey = true
        #expect(monitor.keyModeHint.stringValue == "Connect, then type in the console above.")
        monitor.textView.keyDown(with: key("a"))

        monitor.connect()
        #expect(monitor.keyModeHint.stringValue == "Type in the console above. Each key is sent as you press it.")
        monitor.textView.keyDown(with: key("b"))

        #expect(terminal.receive(1) == Array("b".utf8))
    }

    @Test func remembersTheKeyMode() {
        monitor.sendEachKeyCheckbox.performClick(nil)

        let next = SerialMonitorViewController(listPorts: { [info = terminal.info] in [info] }, defaults: defaults)
        next.loadViewIfNeeded()

        #expect(next.sendsEachKey)
        #expect(next.inputField.isHidden)
    }

    private func key(
        _ characters: String,
        ignoringModifiers: String? = nil,
        keyCode: UInt16 = 0,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
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
        )!
    }
}
