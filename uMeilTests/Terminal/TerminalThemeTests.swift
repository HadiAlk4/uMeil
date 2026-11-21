import Testing
@testable import uMeil

struct TerminalThemeTests {
    @Test func hasSixteenColorsForEachAppearance() {
        #expect(TerminalTheme.ansiHex(isDark: false).count == 16)
        #expect(TerminalTheme.ansiHex(isDark: true).count == 16)
        #expect(TerminalTheme.ansiColors(isDark: true).count == 16)
    }

    @Test func sharesRedAndBlueWithTheEditorPalette() {
        // The editor's keyword and number colors.
        #expect(TerminalTheme.ansiHex(isDark: true)[1] == 0xFF7B72)
        #expect(TerminalTheme.ansiHex(isDark: false)[1] == 0xCF222E)
        #expect(TerminalTheme.ansiHex(isDark: true)[12] == 0x79C0FF)
    }
}
