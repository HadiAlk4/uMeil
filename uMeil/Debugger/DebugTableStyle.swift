import AppKit
import QuartzCore

/// How the debugger's tables draw their text, so `Regs`, `Call Stack +
/// Locals`, `Watch 1`, `Memory 1`, `Peripherals` and `Disassembly` all
/// look alike.
@MainActor
enum DebugTableStyle {
    /// One monospaced font for names and values alike, so columns line up.
    /// The editor's font, a point smaller.
    static var font: NSFont {
        let settings = AppearanceSettings.shared
        return settings.font(ofSize: max(settings.fontSize - 1, 8))
    }

    /// `base` is a table's row height at the standard size; rows grow and
    /// shrink with the font from there.
    static func rowHeight(base: CGFloat) -> CGFloat {
        max(base + AppearanceSettings.shared.fontSize - AppearanceSettings.defaultSize, 14)
    }

    /// Redraws `tableView` in the current font, with rows to fit it.
    static func applyFont(to tableView: NSTableView, base: CGFloat) {
        tableView.rowHeight = rowHeight(base: base)
        tableView.reloadData()
    }

    /// Values that changed since the last stop are red, as Keil shows them.
    static let changedColor = NSColor.systemRed

    /// Dimmer color for `0x` prefixes, leading zeros in hex values, and zero
    /// bytes (`00`) in memory dumps. Semantic so it adapts to Light/Dark mode,
    /// Increase Contrast, and selected table rows.
    static let dimmedHexColor = NSColor.tertiaryLabelColor

    /// Dimmer red for `0x` prefixes and leading zeros of a changed hex value,
    /// so the whole value still reads as changed while meaningful digits pop.
    static let dimmedChangedColor = changedColor.withAlphaComponent(0.45)

    private static let truncatingParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// How long a changed value's background glows after a stop.
    static let flashDuration: CFTimeInterval = 1.2

    /// Cells made within this long of an update count as showing the update,
    /// so they flash; ones made later, when a row scrolls into view, do not.
    static let flashWindow: TimeInterval = 0.5

    /// Draws `label` as a changed value: red text, and when `flash` is true
    /// a red glow behind it that fades away.
    static func markChanged(_ label: NSTextField, flash shouldFlash: Bool) {
        label.textColor = changedColor
        if shouldFlash {
            flash(label)
        }
    }

    /// Formats `text` in the table font with `baseColor`, dimming the `0x`
    /// prefix and leading zeros of any hex literal inside it (keeping at least
    /// the final digit bright for values like `0x00000000`).
    static func styledHex(
        _ text: String,
        baseColor: NSColor = .labelColor,
        dimmedColor: NSColor? = nil
    ) -> NSAttributedString {
        let dim = dimmedColor ?? (baseColor == changedColor ? dimmedChangedColor : dimmedHexColor)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: baseColor,
                .paragraphStyle: truncatingParagraphStyle
            ]
        )
        for range in DebugValueFormatter.dimmedHexRanges(in: text) {
            result.addAttribute(.foregroundColor, value: dim, range: range)
        }
        return result
    }

    /// Sets `text` on `label` in the table font, optionally dimming the `0x`
    /// prefix and leading zeros of any hex literals. When `isChanged` is true,
    /// draws the value in `changedColor` (with dimmed-red leading zeros) and
    /// flashes when `shouldFlash` is true.
    static func applyValue(
        _ text: String,
        to label: NSTextField,
        baseColor: NSColor = .labelColor,
        isChanged: Bool = false,
        flash shouldFlash: Bool = false,
        styleHex: Bool = true
    ) {
        let color = isChanged ? changedColor : baseColor
        label.font = font
        label.lineBreakMode = .byTruncatingTail
        label.textColor = color
        if styleHex, !DebugValueFormatter.dimmedHexRanges(in: text).isEmpty {
            label.attributedStringValue = styledHex(text, baseColor: color)
        } else {
            label.stringValue = text
        }
        if isChanged && shouldFlash {
            flash(label)
        }
    }

    /// Glows red behind `view` for a moment, fading out.
    static func flash(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let glow = changedColor.withAlphaComponent(0.28).cgColor
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = glow
        fade.toValue = NSColor.clear.cgColor
        fade.duration = flashDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.cornerRadius = 3
        layer.backgroundColor = NSColor.clear.cgColor
        layer.add(fade, forKey: "changedFlash")
    }

    /// Whether a cell made now should flash for an update made at `updatedAt`.
    static func shouldFlash(since updatedAt: Date?, now: Date = Date()) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) < flashWindow
    }

    /// `text` with unchanged `00` bytes dimmed and the bytes at `changedOffsets`
    /// in red. `text` is a row of two-digit hex bytes separated by single
    /// spaces, as `Memory 1` shows them.
    static func hexBytes(_ text: String, changedOffsets: Set<Int>) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: truncatingParagraphStyle
            ]
        )
        let nsText = text as NSString
        let length = nsText.length
        var offset = 0
        while offset * 3 + 2 <= length {
            let range = NSRange(location: offset * 3, length: 2)
            if changedOffsets.contains(offset) {
                result.addAttribute(.foregroundColor, value: changedColor, range: range)
            } else if nsText.substring(with: range) == "00" {
                result.addAttribute(.foregroundColor, value: dimmedHexColor, range: range)
            }
            offset += 1
        }
        return result
    }
}
