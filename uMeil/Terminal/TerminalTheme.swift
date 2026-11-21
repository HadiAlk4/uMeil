import AppKit
import SwiftTerm

/// The terminal's colors, from the same family as the editor's syntax
/// colors, so `ls`, `git` and compiler output look at home under the code.
enum TerminalTheme {
    /// The 16 ANSI colors as RGB values: black, red, green, yellow, blue,
    /// magenta, cyan and white, then the bright version of each.
    static func ansiHex(isDark: Bool) -> [UInt32] {
        isDark ? dark : light
    }

    private static let light: [UInt32] = [
        0x24292F, 0xCF222E, 0x116329, 0x9A6700, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F
    ]

    private static let dark: [UInt32] = [
        0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF
    ]

    static func ansiColors(isDark: Bool) -> [SwiftTerm.Color] {
        ansiHex(isDark: isDark).map { hex in
            // SwiftTerm takes 16-bit channels; 0xAB becomes 0xABAB.
            func channel(_ shift: UInt32) -> UInt16 { UInt16((hex >> shift) & 0xFF) * 0x101 }
            return SwiftTerm.Color(red: channel(16), green: channel(8), blue: channel(0))
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
