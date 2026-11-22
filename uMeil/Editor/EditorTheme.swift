import AppKit

/// Fonts and spacing for the code editor. The font is the one picked in
/// Settings, at the size ⌘+ and ⌘− last left it.
@MainActor
enum EditorTheme {
    static var font: NSFont { AppearanceSettings.shared.font }

    /// Two points smaller than the code, so the gutter stays narrow.
    static var lineNumberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: max(font.pointSize - 2, 8), weight: .regular)
    }

    /// How many spaces wide a tab character is drawn.
    static let tabWidth = 4

    /// Tab stops a fixed number of spaces apart in the current font.
    static var paragraphStyle: NSParagraphStyle {
        let current = font
        if let cached = paragraphStyleCache, cached.font == current { return cached.style }
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: current]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * CGFloat(tabWidth)
        paragraphStyleCache = (current, style)
        return style
    }

    private static var paragraphStyleCache: (font: NSFont, style: NSParagraphStyle)?

    /// The color for each kind of highlighted code. Each color has a light
    /// and a dark version, picked to stay readable and calm on the editor's
    /// background. Strings are blue rather than red, so they never look like
    /// errors.
    static func color(for kind: HighlightKind) -> NSColor {
        switch kind {
        case .keyword: Palette.keyword
        case .preprocessor: Palette.preprocessor
        case .type: Palette.type
        case .string: Palette.string
        case .number: Palette.number
        case .constant: Palette.constant
        case .function: Palette.function
        case .comment: Palette.comment
        }
    }

    /// The syntax colors, made once so every token shares the same objects.
    nonisolated private enum Palette {
        static let keyword = adaptive(light: 0xCF222E, dark: 0xFF7B72)
        static let preprocessor = adaptive(light: 0x9A6700, dark: 0xE3B341)
        static let type = adaptive(light: 0x953800, dark: 0xFFA657)
        static let string = adaptive(light: 0x0A3069, dark: 0xA5D6FF)
        static let number = adaptive(light: 0x0550AE, dark: 0x79C0FF)
        static let constant = adaptive(light: 0x116329, dark: 0x7EE787)
        static let function = adaptive(light: 0x8250DF, dark: 0xD2A8FF)
        static let comment = adaptive(light: 0x6E7781, dark: 0x8B949E)
    }

    /// A color that switches between two RGB values with the appearance.
    nonisolated static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        adaptive(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
    }

    nonisolated private static func adaptive(
        light: UInt32,
        lightAlpha: CGFloat,
        dark: UInt32,
        darkAlpha: CGFloat
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    nonisolated private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Faint tint drawn behind the line the cursor is currently on.
    static let currentLineColor = adaptive(
        light: 0x1F2937,
        lightAlpha: 0.05,
        dark: 0xE6EDF3,
        darkAlpha: 0.06
    )

    /// Underline colors for live diagnostics reported while typing.
    /// The shading behind a snippet placeholder still waiting to be filled in.
    static let placeholderBackgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18)

    static let inlineErrorColor = NSColor.systemRed
    static let inlineWarningColor = NSColor.systemOrange

    /// Shared Xcode-style green accent used by both the program-counter gutter
    /// pointer and the execution-line background highlight.
    nonisolated private enum ExecutionAccent {
        static let light: UInt32 = 0x249A3E
        static let dark: UInt32 = 0x30D158
    }

    /// Solid accent color for the program-counter arrow in the editor gutter.
    static let executionLineAccentColor = adaptive(
        light: ExecutionAccent.light,
        dark: ExecutionAccent.dark
    )

    /// Behind the line the stopped program will run next, matched to
    /// `executionLineAccentColor`.
    static let executionLineColor = adaptive(
        light: ExecutionAccent.light,
        lightAlpha: 0.18,
        dark: ExecutionAccent.dark,
        darkAlpha: 0.22
    )

    /// Faint tick shown in the gutter on executable lines while hovering.
    static let executableLineTickColor = adaptive(
        light: 0x000000,
        lightAlpha: 0.18,
        dark: 0xFFFFFF,
        darkAlpha: 0.22
    )

    /// The attributes plain (unhighlighted) code is drawn with.
    static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle
        ]
    }
}
