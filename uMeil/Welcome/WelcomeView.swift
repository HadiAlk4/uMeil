import AppKit

/// Shown in place of the editor when no folder is open: the app's icon and
/// name, buttons to start a project, the projects opened recently, and
/// a Check for Updates… icon in the bottom left corner.
///
/// The buttons send their actions up the responder chain (to the window
/// controller, or the app delegate for updates), like the menu items they match.
final class WelcomeView: NSView {
    /// Called with a folder chosen from the recent projects.
    var onOpenRecent: ((URL) -> Void)?

    private let recentStack = NSStackView()
    private let recentHeading = NSTextField(labelWithString: "Recent Projects")
    private(set) var recentFolders: [URL] = []
    /// An icon in the bottom left, shown only in builds that can check for updates.
    let updateButton = NSButton(
        image: NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath",
            accessibilityDescription: "Check for Updates…"
        ) ?? NSImage(),
        target: nil,
        action: #selector(AppDelegate.checkForUpdates(_:))
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WelcomeView is created in code, not from a nib")
    }

    /// Lists `folders` under "Recent Projects", or hides the section when empty.
    func showRecent(_ folders: [URL]) {
        recentFolders = folders
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for folder in folders {
            let row = RecentProjectRow(folder: folder)
            row.onClick = { [weak self] in self?.onOpenRecent?(folder) }
            recentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
        }
        recentHeading.isHidden = folders.isEmpty
        recentStack.isHidden = folders.isEmpty
    }

    // MARK: - Layout

    private func build() {
        let column = NSStackView(views: [Self.makeHeader(), Self.makeActions(), makeRecentSection()])
        column.orientation = .vertical
        column.spacing = 28
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 20),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20)
        ])
        showRecent([])
        addUpdateButton()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateButton.isHidden = !((NSApp.delegate as? AppDelegate)?.canCheckForUpdates ?? false)
    }

    private func addUpdateButton() {
        updateButton.toolTip = "Check for Updates…"
        updateButton.isBordered = false
        updateButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        updateButton.contentTintColor = .secondaryLabelColor
        updateButton.isHidden = true
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(updateButton)
        NSLayoutConstraint.activate([
            updateButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            updateButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    private static func makeHeader() -> NSView {
        // Read the icon from our own asset catalog: applicationIconImage goes
        // through the system icon cache, which can hand back the blank
        // placeholder when several builds share the bundle ID.
        let icon = NSImageView(image: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let title = NSTextField(labelWithString: AppInfo.name)
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Write, flash and debug code for the Tiva TM4C129")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let header = NSStackView(views: [icon, title, subtitle])
        header.orientation = .vertical
        header.spacing = 6
        header.setCustomSpacing(14, after: icon)
        return header
    }

    private static func makeActions() -> NSView {
        let actions = NSStackView(views: [
            actionButton("New Project…", symbol: "plus.square", action: #selector(MainWindowController.newProject(_:))),
            actionButton("Open Folder…", symbol: "folder", action: #selector(MainWindowController.chooseFolder(_:))),
            actionButton(
                "Import Keil Project…",
                symbol: "square.and.arrow.down",
                action: #selector(MainWindowController.importKeilProject(_:))
            )
        ])
        actions.orientation = .vertical
        actions.spacing = 8
        for button in actions.arrangedSubviews {
            button.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        return actions
    }

    private func makeRecentSection() -> NSView {
        recentHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        recentHeading.textColor = .secondaryLabelColor
        recentStack.orientation = .vertical
        recentStack.spacing = 2
        recentStack.alignment = .leading
        recentStack.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let recent = NSStackView(views: [recentHeading, recentStack])
        recent.orientation = .vertical
        recent.alignment = .leading
        recent.spacing = 6
        return recent
    }

    private static func actionButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.bezelStyle = .push
        button.controlSize = .large
        button.alignment = .left
        return button
    }
}

/// One recent project: a folder icon, its name, and where it is.
/// Highlights under the mouse and opens on click.
final class RecentProjectRow: NSView {
    let folder: URL
    var onClick: (() -> Void)?

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(folder: URL) {
        self.folder = folder
        super.init(frame: .zero)
        toolTip = folder.path(percentEncoded: false)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(folder.lastPathComponent)")

        let icon = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)

        let name = NSTextField(labelWithString: folder.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let location = NSTextField(labelWithString: Self.abbreviated(folder.deletingLastPathComponent()))
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: [name, location])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecentProjectRow is created in code, not from a nib")
    }

    /// The path with the home folder written as `~`.
    static func abbreviated(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    // Taking the mouse down here is what makes the mouse up come here too.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}
