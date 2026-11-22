import AppKit

private struct QuickFixLineLayout {
    var origin: NSPoint
    var lineRect: NSRect
    var usedRect: NSRect
}

extension EditorTextView {
    /// A live diagnostic with an auto-fix drawn as a one-click capsule at the end of its line.
    struct InlineQuickFix: Equatable {
        /// Where the line starts in the text, in UTF-16 units.
        var lineStart: Int
        var severity: Diagnostic.Severity
        var message: String
        var moreCount = 0
        var action: LSPCodeAction
    }

    private static let quickFixBadgeFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let quickFixBadgeText = "Fix"

    private static var quickFixBadgeWidth: CGFloat {
        let textWidth = ceil((quickFixBadgeText as NSString).size(withAttributes: [.font: quickFixBadgeFont]).width)
        return textWidth + 12
    }

    /// Computes the clickable capsule rect in view coordinates for `item`, or `nil` if it does not fit.
    func quickFixCapsuleRect(for item: InlineQuickFix) -> NSRect? {
        guard let layout = quickFixLineLayout(forLineStart: item.lineStart) else { return nil }
        let start = layout.origin.x + layout.usedRect.maxX + Self.inlineMessageGap
        let rightEdge = max(bounds.maxX, enclosingScrollView?.contentView.bounds.maxX ?? bounds.maxX)
        let available = rightEdge - start - 8

        let iconSize: CGFloat = 11, padding: CGFloat = 7, spacing: CGFloat = 5
        let badgeWidth = Self.quickFixBadgeWidth
        let minWidth = padding + iconSize + spacing + badgeWidth + 4
        guard available >= minWidth else { return nil }

        let displayMessage = Self.inlineText(
            for: BuildSummary.LineMessage(severity: item.severity, text: item.message, moreCount: item.moreCount)
        ) as NSString
        let textWidth = ceil(displayMessage.size(withAttributes: [.font: Self.inlineMessageFont]).width)
        let idealWidth = padding + iconSize + spacing + textWidth + 8 + badgeWidth + 4
        let width = min(idealWidth, available)
        let height = min(layout.lineRect.height - 2, 17)
        return NSRect(x: start, y: layout.lineRect.midY - height / 2, width: width, height: height)
    }

    /// Returns the quick-fix capsule containing `viewPoint`, if any.
    func quickFix(at viewPoint: NSPoint) -> InlineQuickFix? {
        inlineQuickFixes.first { quickFixCapsuleRect(for: $0)?.contains(viewPoint) == true }
    }

    /// Handles a primary click at `viewPoint` if it lands on a quick-fix capsule.
    @discardableResult
    func handleQuickFixClick(at viewPoint: NSPoint) -> Bool {
        guard let hit = quickFix(at: viewPoint) else { return false }
        onQuickFixClick?(hit.action)
        return true
    }

    @discardableResult
    func handleQuickFixClick(with event: NSEvent) -> Bool {
        handleQuickFixClick(at: convert(event.locationInWindow, from: nil))
    }

    func updateQuickFixHover(with event: NSEvent) {
        guard !inlineQuickFixes.isEmpty else {
            clearQuickFixHover()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = quickFix(at: point) {
            NSCursor.pointingHand.set()
            toolTip = DiagnosticQuickFix.tooltip(for: hit.action)
        } else {
            clearQuickFixHover()
        }
    }

    func clearQuickFixHover() {
        if toolTip?.hasPrefix("Fix: ") == true {
            toolTip = nil
        }
    }

    /// Draws each fixable live diagnostic behind the text: a faint line tint and a capsule with
    /// an inline `Fix` pill that applies the quick-fix with one click.
    func drawInlineQuickFixes(in dirtyRect: NSRect) {
        guard !inlineQuickFixes.isEmpty else { return }
        for item in inlineQuickFixes {
            guard let layout = quickFixLineLayout(forLineStart: item.lineStart),
                  layout.lineRect.intersects(dirtyRect)
            else { continue }

            let color = Self.inlineColor(for: item.severity)
            color.withAlphaComponent(0.07).setFill()
            NSRect(x: bounds.minX, y: layout.lineRect.minY, width: bounds.width, height: layout.lineRect.height).fill()

            guard let capsule = quickFixCapsuleRect(for: item) else { continue }
            drawQuickFixCapsule(for: item, color: color, in: capsule)
        }
    }

    private func quickFixLineLayout(forLineStart lineStart: Int) -> QuickFixLineLayout? {
        guard let layoutManager, let storage = textStorage, storage.length > 0, lineStart <= storage.length else {
            return nil
        }
        let characterIndex = min(lineStart, storage.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let origin = textContainerOrigin
        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        lineRect = lineRect.offsetBy(dx: origin.x, dy: origin.y)
        return QuickFixLineLayout(origin: origin, lineRect: lineRect, usedRect: usedRect)
    }

    private func drawQuickFixCapsule(for item: InlineQuickFix, color: NSColor, in capsule: NSRect) {
        let iconSize: CGFloat = 11, padding: CGFloat = 7, spacing: CGFloat = 5
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()

        drawQuickFixSeverityIcon(item.severity, color: color, in: NSRect(
            x: capsule.minX + padding,
            y: capsule.midY - iconSize / 2,
            width: iconSize,
            height: iconSize
        ))

        let badgeRect = drawQuickFixPill(inside: capsule)
        let textX = capsule.minX + padding + iconSize + spacing
        let textWidth = badgeRect.minX - 6 - textX
        guard textWidth >= 18 else { return }
        drawQuickFixMessage(item, in: NSRect(x: textX, y: capsule.minY, width: textWidth, height: capsule.height))
    }

    private func drawQuickFixSeverityIcon(_ severity: Diagnostic.Severity, color: NSColor, in rect: NSRect) {
        let symbol = severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(.init(paletteColors: [.white, color]))
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func drawQuickFixPill(inside capsule: NSRect) -> NSRect {
        let badgeWidth = Self.quickFixBadgeWidth
        let badgeHeight = max(capsule.height - 4, 12)
        let badgeRect = NSRect(
            x: capsule.maxX - badgeWidth - 3,
            y: capsule.midY - badgeHeight / 2,
            width: badgeWidth,
            height: badgeHeight
        )
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeHeight / 2, yRadius: badgeHeight / 2).fill()

        let nsText = Self.quickFixBadgeText as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.quickFixBadgeFont, .foregroundColor: NSColor.white]
        let size = nsText.size(withAttributes: attrs)
        nsText.draw(
            at: NSPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2),
            withAttributes: attrs
        )
        return badgeRect
    }

    private func drawQuickFixMessage(_ item: InlineQuickFix, in textRect: NSRect) {
        let messageText = Self.inlineText(
            for: BuildSummary.LineMessage(severity: item.severity, text: item.message, moreCount: item.moreCount)
        ) as NSString
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let lineHeight = ceil(Self.inlineMessageFont.ascender - Self.inlineMessageFont.descender)
        let lineBox = NSRect(
            x: textRect.minX,
            y: textRect.midY - lineHeight / 2,
            width: textRect.width,
            height: lineHeight
        )
        messageText.draw(
            with: lineBox,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: Self.inlineMessageFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        )
    }
}
