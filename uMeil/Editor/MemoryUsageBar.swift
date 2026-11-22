import AppKit

/// The strip under the editor that shows how full flash and RAM are after
/// the last successful build, with a small meter for each.
final class MemoryUsageBar: NSView {
    private(set) var usage: MemoryUsage?
    let flashMeter = Meter()
    let ramMeter = Meter()

    static let height: CGFloat = 22

    /// The line along the top. Off when the bar sits inside a strip that
    /// draws its own, such as the editor's status line.
    var showsSeparator = true {
        didSet { separator.isHidden = !showsSeparator }
    }
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator

        let dot = NSTextField(labelWithString: "·")
        dot.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [NSView(), flashMeter, dot, ramMeter])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)

        for subview in [separator, row] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: separator.bottomAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MemoryUsageBar is created in code, not from a nib")
    }

    /// Shows `usage`, or hides the bar for `nil`.
    func show(_ usage: MemoryUsage?) {
        self.usage = usage
        isHidden = usage == nil
        guard let usage else { return }
        flashMeter.show(usage.flash)
        ramMeter.show(usage.ram)
        toolTip = "\(usage.flash.detailText)\n\(usage.ram.detailText)\nFrom the last successful build"
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Memory used: \(usage.summary)")
    }

    /// "Flash 12%" with a short bar filled to match.
    final class Meter: NSView {
        let label = NSTextField(labelWithString: "")
        private let track = Track()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            let row = NSStackView(views: [label, track])
            row.orientation = .horizontal
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                track.widthAnchor.constraint(equalToConstant: 48),
                track.heightAnchor.constraint(equalToConstant: 5)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Meter is created in code, not from a nib")
        }

        func show(_ region: MemoryUsage.Region) {
            label.stringValue = "\(region.name) \(region.percentText)"
            track.fraction = region.fraction
            track.color = switch region.level {
            case .comfortable: .systemGreen
            case .tight: .systemOrange
            case .full: .systemRed
            }
            label.textColor = region.level == .full ? .systemRed : .secondaryLabelColor
        }

        var fraction: Double { track.fraction }
    }

    private final class Track: NSView {
        var fraction: Double = 0 { didSet { needsDisplay = true } }
        var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            let radius = bounds.height / 2
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            guard fraction > 0 else { return }
            // Even a sliver shows, so a small program does not look like nothing.
            let width = max(bounds.height, bounds.width * min(fraction, 1))
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                xRadius: radius,
                yRadius: radius
            ).fill()
        }
    }
}
