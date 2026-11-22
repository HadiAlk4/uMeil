import AppKit

/// What a terminal such as Tera Term sends for each key, for the serial
/// monitor's mode that sends keys as they are typed.
enum SerialKeys {
    /// Key codes for Return and keypad Enter, which send the line ending.
    private static let returnKeys: Set<UInt16> = [36, 76]

    /// What the keys that do not send their own character send, by key code.
    private static let fixedKeys: [UInt16: [UInt8]] = [
        53: [0x1B], // Escape
        48: [0x09], // Tab
        // Tera Term's default: Delete sends backspace, forward delete sends DEL.
        51: [0x08],
        117: [0x7F],
        // VT100 cursor keys: up, down, right, left.
        126: Array("\u{1B}[A".utf8),
        125: Array("\u{1B}[B".utf8),
        124: Array("\u{1B}[C".utf8),
        123: Array("\u{1B}[D".utf8)
    ]

    /// The bytes to send for `event`, or nil if the key sends nothing, such
    /// as a Command shortcut or a function key.
    ///
    /// - Parameter returnKey: What Return sends. With no line ending chosen
    ///   it sends a carriage return, as Tera Term does.
    static func bytes(for event: NSEvent, returnKey: SerialLineEnding) -> [UInt8]? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command) else { return nil }

        if returnKeys.contains(event.keyCode) {
            return Array((returnKey == .none ? "\r" : returnKey.text).utf8)
        }
        if let fixed = fixedKeys[event.keyCode] {
            return fixed
        }
        if modifiers.contains(.control), let control = controlCode(for: event) {
            return [control]
        }
        guard let characters = event.characters, !characters.isEmpty,
              !characters.unicodeScalars.contains(where: isFunctionKey) else { return nil }
        return Array(characters.utf8)
    }

    /// Control-A to Control-Z send 1 to 26, as on any terminal.
    private static func controlCode(for event: NSEvent) -> UInt8? {
        guard let key = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
              ("a"..."z").contains(key) else { return nil }
        return UInt8(key.value - 0x60)
    }

    /// AppKit puts function, arrow and other special keys in this range.
    private static func isFunctionKey(_ scalar: Unicode.Scalar) -> Bool {
        (0xF700...0xF8FF).contains(scalar.value)
    }
}
