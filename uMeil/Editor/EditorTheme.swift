import AppKit

/// Fonts and spacing for the code editor.
@MainActor
enum EditorTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// How many spaces wide a tab character is drawn.
    static let tabWidth = 4

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        style.tabStops = []
        style.defaultTabInterval = spaceWidth * CGFloat(tabWidth)
        return style
    }()

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
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    nonisolated private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Underline colors for live diagnostics reported while typing.
    static let inlineErrorColor = NSColor.systemRed
    static let inlineWarningColor = NSColor.systemOrange

    /// Behind the line the stopped program will run next.
    static let executionLineColor = NSColor.systemGreen.withAlphaComponent(0.25)

    /// The attributes plain (unhighlighted) code is drawn with.
    static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle
        ]
    }
}
