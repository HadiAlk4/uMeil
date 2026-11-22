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

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func executionLineAccentAndBackgroundShareTheSameGreenAccent(appearance: NSAppearance.Name) throws {
        let accent = try #require(resolved(EditorTheme.executionLineAccentColor, in: appearance))
        let background = try #require(resolved(EditorTheme.executionLineColor, in: appearance))

        #expect(abs(accent.redComponent - background.redComponent) < 0.001)
        #expect(abs(accent.greenComponent - background.greenComponent) < 0.001)
        #expect(abs(accent.blueComponent - background.blueComponent) < 0.001)
        #expect(accent.alphaComponent == 1)
        #expect(background.alphaComponent > 0 && background.alphaComponent < 0.35)
        #expect(accent.greenComponent > accent.redComponent)
        #expect(accent.greenComponent > accent.blueComponent)
    }

    @Test func executionLineColorsAdaptToAppearance() {
        let lightAccent = resolved(EditorTheme.executionLineAccentColor, in: .aqua)
        let darkAccent = resolved(EditorTheme.executionLineAccentColor, in: .darkAqua)
        let lightBackground = resolved(EditorTheme.executionLineColor, in: .aqua)
        let darkBackground = resolved(EditorTheme.executionLineColor, in: .darkAqua)

        #expect(lightAccent != darkAccent)
        #expect(lightBackground != darkBackground)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func executableLineTickColorIsSubtleAndAdapts(appearance: NSAppearance.Name) throws {
        let tick = try #require(resolved(EditorTheme.executableLineTickColor, in: appearance))

        #expect(tick.alphaComponent > 0 && tick.alphaComponent <= 0.25)
        if appearance == .aqua {
            #expect(tick.redComponent < 0.2 && tick.greenComponent < 0.2 && tick.blueComponent < 0.2)
        } else {
            #expect(tick.redComponent > 0.8 && tick.greenComponent > 0.8 && tick.blueComponent > 0.8)
        }
    }
}
