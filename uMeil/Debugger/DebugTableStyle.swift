import AppKit
import QuartzCore

/// How the debugger's tables draw their text, so `Regs`, `Call Stack +
/// Locals`, `Watch 1`, `Memory 1`, `Peripherals` and `Disassembly` all
/// look alike.
@MainActor
enum DebugTableStyle {
    /// One monospaced font for names and values alike, so columns line up.
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// Values that changed since the last stop are red, as Keil shows them.
    static let changedColor = NSColor.systemRed

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

    /// `text` with the bytes at `changedOffsets` in red. `text` is a row of
    /// two-digit hex bytes separated by single spaces, as `Memory 1` shows them.
    static func hexBytes(_ text: String, changedOffsets: Set<Int>) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        let length = (text as NSString).length
        for offset in changedOffsets {
            let range = NSRange(location: offset * 3, length: 2)
            guard range.location + range.length <= length else { continue }
            result.addAttribute(.foregroundColor, value: changedColor, range: range)
        }
        return result
    }
}
