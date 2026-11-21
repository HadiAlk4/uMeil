import AppKit

/// The toolbar's middle: a spinner or progress bar while something runs,
/// then an icon and a line saying how it went.
final class ActivityView: NSView {
    private(set) var activity = Activity.idle

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()

    static let width: CGFloat = 320

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        show(.idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ActivityView is created in code, not from a nib")
    }

    var text: String { label.stringValue }

    func show(_ activity: Activity) {
        self.activity = activity
        label.stringValue = activity.text
        label.textColor = activity.kind == .idle ? .secondaryLabelColor : .labelColor
        setAccessibilityValue(activity.text)
        toolTip = activity.text

        switch activity.kind {
        case .working(let progress):
            icon.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
            progressBar.isHidden = progress == nil
            progressBar.doubleValue = progress ?? 0
        default:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            progressBar.isHidden = true
            icon.image = Self.image(for: activity.kind)
            icon.isHidden = icon.image == nil
        }
    }

    private static func image(for kind: Activity.Kind) -> NSImage? {
        let symbol: (name: String, color: NSColor)
        switch kind {
        case .succeeded: symbol = ("checkmark.circle.fill", .systemGreen)
        case .warning: symbol = ("exclamationmark.triangle.fill", .systemYellow)
        case .failed: symbol = ("xmark.octagon.fill", .systemRed)
        case .info: symbol = ("ladybug.fill", .controlAccentColor)
        case .idle, .working: return nil
        }
        // The color is part of the image, since a toolbar tints template images gray.
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [symbol.color]))
        return NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func build() {
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Activity")

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .mini

        let line = NSStackView(views: [icon, spinner, label])
        line.spacing = 6
        let column = NSStackView(views: [line, progressBar])
        column.orientation = .vertical
        column.spacing = 2
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            progressBar.widthAnchor.constraint(equalToConstant: 180)
        ])
    }
}
