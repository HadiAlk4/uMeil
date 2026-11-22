import AppKit

extension EditorTextView {
    /// A build message drawn at the end of a line.
    struct InlineMessage: Equatable {
        /// Where the line starts in the text, in UTF-16 units.
        var lineStart: Int
        var message: BuildSummary.LineMessage
    }

    /// The gap between the end of the code and the message.
    static let inlineMessageGap: CGFloat = 24
    /// Messages narrower than this are left out rather than squeezed.
    static let inlineMessageMinimumWidth: CGFloat = 70

    static let inlineMessageFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    static func inlineColor(for severity: Diagnostic.Severity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemOrange
        case .note: .secondaryLabelColor
        }
    }

    static func inlineText(for message: BuildSummary.LineMessage) -> String {
        message.moreCount > 0 ? "\(message.text)  (+\(message.moreCount) more)" : message.text
    }

    /// Draws each message behind the text: a faint tint across its line and
    /// a capsule with an icon and the message after the line's last character.
    func drawInlineMessages(in dirtyRect: NSRect) {
        guard !inlineMessages.isEmpty, let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0
        else { return }
        let origin = textContainerOrigin

        for item in inlineMessages where item.lineStart <= storage.length {
            let characterIndex = min(item.lineStart, storage.length - 1)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            var lineGlyphs = NSRange()
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphs)
            // A long line wraps into several fragments only if wrapping is on;
            // it is off, so this one fragment is the whole line.
            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect = lineRect.offsetBy(dx: origin.x, dy: origin.y)
            guard lineRect.intersects(dirtyRect) else { continue }

            let color = Self.inlineColor(for: item.message.severity)
            color.withAlphaComponent(0.07).setFill()
            NSRect(x: bounds.minX, y: lineRect.minY, width: bounds.width, height: lineRect.height).fill()

            let start = origin.x + usedRect.maxX + Self.inlineMessageGap
            drawCapsule(for: item.message, color: color, startingAt: start, in: lineRect)
        }
    }

    private func drawCapsule(
        for message: BuildSummary.LineMessage,
        color: NSColor,
        startingAt start: CGFloat,
        in lineRect: NSRect
    ) {
        let text = Self.inlineText(for: message) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.inlineMessageFont,
            .foregroundColor: NSColor.labelColor
        ]
        let iconSize: CGFloat = 11, padding: CGFloat = 7, spacing: CGFloat = 5
        let textWidth = ceil(text.size(withAttributes: attributes).width)
        let available = bounds.maxX - start - 8
        let width = min(padding + iconSize + spacing + textWidth + padding, available)
        guard width >= Self.inlineMessageMinimumWidth else { return }

        let height = min(lineRect.height - 2, 17)
        let capsule = NSRect(x: start, y: lineRect.midY - height / 2, width: width, height: height)
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: height / 2, yRadius: height / 2).fill()

        let symbol = message.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(.init(paletteColors: [color]))
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let iconRect = NSRect(
                x: capsule.minX + padding,
                y: capsule.midY - iconSize / 2,
                width: iconSize,
                height: iconSize
            )
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let textX = capsule.minX + padding + iconSize + spacing
        let textRect = NSRect(
            x: textX,
            y: capsule.minY,
            width: max(0, capsule.maxX - padding - textX),
            height: capsule.height
        )
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var drawn = attributes
        drawn[.paragraphStyle] = style
        let lineHeight = ceil(Self.inlineMessageFont.ascender - Self.inlineMessageFont.descender)
        let lineBox = NSRect(
            x: textRect.minX,
            y: textRect.midY - lineHeight / 2,
            width: textRect.width,
            height: lineHeight
        )
        text.draw(
            with: lineBox,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: drawn
        )
    }
}
