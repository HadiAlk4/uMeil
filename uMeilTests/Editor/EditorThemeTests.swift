import AppKit
import Testing
@testable import uMeil

@MainActor
struct EditorThemeTests {
    private func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor? {
        var result: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return result
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func everyKindHasItsOwnColor(appearance: NSAppearance.Name) {
        let colors = HighlightKind.allCases.compactMap { resolved(EditorTheme.color(for: $0), in: appearance) }
        #expect(colors.count == HighlightKind.allCases.count)
        #expect(Set(colors).count == colors.count)
    }

    @Test func colorsChangeWithTheAppearance() {
        for kind in HighlightKind.allCases {
            let light = resolved(EditorTheme.color(for: kind), in: .aqua)
            let dark = resolved(EditorTheme.color(for: kind), in: .darkAqua)
            #expect(light != dark, "\(kind) looks the same in light and dark mode")
        }
    }

    @Test func adaptiveColorUsesTheGivenValues() {
        let color = EditorTheme.adaptive(light: 0xFF0000, dark: 0x0000FF)
        #expect(resolved(color, in: .aqua)?.redComponent == 1)
        #expect(resolved(color, in: .darkAqua)?.blueComponent == 1)
    }
}
