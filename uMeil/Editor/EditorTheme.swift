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

    /// The color for each kind of highlighted code. These are system colors,
    /// so they adapt to light and dark mode on their own.
    static func color(for kind: HighlightKind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .preprocessor: .systemOrange
        case .type: .systemTeal
        case .string: .systemRed
        case .number: .systemPurple
        case .constant: .systemIndigo
        case .function: .systemBlue
        case .comment: .secondaryLabelColor
        }
    }

    /// The attributes plain (unhighlighted) code is drawn with.
    static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle
        ]
    }
}
