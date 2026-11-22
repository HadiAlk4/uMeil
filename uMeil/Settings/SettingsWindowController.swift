import AppKit

/// uMeil > Settings…: the code font, its size, and light or dark mode.
/// Changes apply as soon as they are made, as is usual for Mac settings.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController(settings: .shared)

    let settings: AppearanceSettings
    let fontPopUp = NSPopUpButton()
    let sizeField = NSTextField()
    let sizeStepper = NSStepper()
    let themeControl = NSSegmentedControl(
        labels: AppearanceSettings.Theme.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    let preview = NSTextField(labelWithString: "GPIO_PORTN_DATA_R ^= 0x01;  // LED D1")

    /// The fonts offered, by PostScript name. `nil` is the system's monospaced font.
    private(set) var fontChoices: [String?] = []

    init(settings: AppearanceSettings) {
        self.settings = settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContent()
        window.center()
        showCurrentSettings()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged(_:)),
            name: AppearanceSettings.didChange,
            object: settings
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code, not from a nib")
    }

    private func makeContent() -> NSView {
        fontChoices = [nil] + AppearanceSettings.monospacedFontNames()
        fontPopUp.removeAllItems()
        for choice in fontChoices {
            fontPopUp.addItem(withTitle: choice.map(AppearanceSettings.displayName(for:)) ?? "System Monospaced")
            fontPopUp.lastItem?.representedObject = choice
            if choice == nil, fontChoices.count > 1 {
                fontPopUp.menu?.addItem(.separator())
            }
        }
        fontPopUp.target = self
        fontPopUp.action = #selector(fontChosen(_:))

        let size = makeSizeControls()

        themeControl.target = self
        themeControl.action = #selector(themeChosen(_:))

        preview.lineBreakMode = .byTruncatingTail
        preview.textColor = .secondaryLabelColor

        let hint = NSTextField(labelWithString: "⌘+ and ⌘− change the size from any window.")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor

        let grid = NSGridView(views: [
            [label("Font:"), fontPopUp],
            [label("Size:"), size],
            [label("Appearance:"), themeControl],
            [NSGridCell.emptyContentView, preview],
            [NSGridCell.emptyContentView, hint]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            fontPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        return content
    }

    /// A field to type the size in, with arrows beside it to step it.
    private func makeSizeControls() -> NSView {
        sizeField.formatter = Self.sizeFormatter
        sizeField.alignment = .right
        sizeField.target = self
        sizeField.action = #selector(sizeTyped(_:))
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        sizeStepper.minValue = Double(AppearanceSettings.sizes.lowerBound)
        sizeStepper.maxValue = Double(AppearanceSettings.sizes.upperBound)
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped(_:))
        let size = NSStackView(views: [sizeField, sizeStepper, NSTextField(labelWithString: "pt")])
        size.spacing = 4
        return size
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private static let sizeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = NSNumber(value: Double(AppearanceSettings.sizes.lowerBound))
        formatter.maximum = NSNumber(value: Double(AppearanceSettings.sizes.upperBound))
        return formatter
    }()

    /// Puts the controls in line with the settings, such as after ⌘+.
    func showCurrentSettings() {
        let chosen = fontPopUp.itemArray.first { item in
            !item.isSeparatorItem && item.representedObject as? String == settings.fontName
        }
        fontPopUp.select(chosen ?? fontPopUp.itemArray.first)
        sizeField.integerValue = Int(settings.fontSize)
        sizeStepper.integerValue = Int(settings.fontSize)
        themeControl.selectedSegment = AppearanceSettings.Theme.allCases.firstIndex(of: settings.theme) ?? 0
        preview.font = settings.font
    }

    @objc private func settingsChanged(_ notification: Notification) {
        showCurrentSettings()
    }

    @objc func fontChosen(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        settings.fontName = item.representedObject as? String
    }

    @objc func sizeTyped(_ sender: NSTextField) {
        settings.fontSize = CGFloat(sender.integerValue)
        showCurrentSettings()
    }

    @objc func sizeStepped(_ sender: NSStepper) {
        settings.fontSize = CGFloat(sender.integerValue)
    }

    @objc func themeChosen(_ sender: NSSegmentedControl) {
        let themes = AppearanceSettings.Theme.allCases
        guard themes.indices.contains(sender.selectedSegment) else { return }
        settings.theme = themes[sender.selectedSegment]
    }
}
