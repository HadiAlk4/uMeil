import AppKit

/// Draws SF Symbols for toolbar buttons and status icons with explicit
/// appearance-aware colors, avoiding AppKit's toolbar template tinting that
/// washes enabled icons out to muted gray and strips accent colors.
@MainActor
enum ToolbarIcon {
    static let buttonSymbolPointSize: CGFloat = 13.5
    static let buttonCanvasSize = NSSize(width: 20, height: 18)

    /// Full-contrast tint for available toolbar actions.
    static var enabledTintColor: NSColor { .labelColor }
    /// Vivid red tint for available Stop / End Debug Session actions.
    static var stopTintColor: NSColor { .systemRed }
    /// Muted gray tint for unavailable toolbar actions.
    static var disabledTintColor: NSColor { .tertiaryLabelColor }

    static func drawSymbol(
        _ symbol: String,
        in bounds: NSRect,
        tintColor: NSColor,
        pointSize: CGFloat = buttonSymbolPointSize,
        weight: NSFont.Weight = .medium
    ) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config),
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        let symbolSize = base.size
        let drawRect = NSRect(
            x: bounds.midX - symbolSize.width / 2,
            y: bounds.midY - symbolSize.height / 2,
            width: symbolSize.width,
            height: symbolSize.height
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        base.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: nil
        )
        tintColor.setFill()
        drawRect.insetBy(dx: -2, dy: -2).fill(using: .sourceIn)
        context.endTransparencyLayer()
    }

    static func makeImage(
        symbol: String,
        tintColor: NSColor,
        pointSize: CGFloat = buttonSymbolPointSize,
        weight: NSFont.Weight = .medium,
        canvasSize: NSSize = buttonCanvasSize,
        accessibilityDescription: String? = nil
    ) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(config)
        else {
            return NSImage(size: canvasSize)
        }
        let symbolSize = base.size
        let size = NSSize(
            width: max(canvasSize.width, ceil(symbolSize.width)),
            height: max(canvasSize.height, ceil(symbolSize.height))
        )
        let image = NSImage(size: size, flipped: false) { rect in
            let appearance = NSApp.windows.first(where: { $0.toolbar != nil })?.effectiveAppearance
                ?? NSAppearance.currentDrawing()
            appearance.performAsCurrentDrawingAppearance {
                drawSymbol(symbol, in: rect, tintColor: tintColor, pointSize: pointSize, weight: weight)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}

/// A label inside a toolbar item that always resolves dynamic text colors
/// against its window's `effectiveAppearance`.
@MainActor
final class ToolbarLabel: NSTextField {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = window?.effectiveAppearance ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            super.draw(dirtyRect)
        }
    }
}

/// A toolbar button that renders its SF Symbol directly in `draw(_:)` using the
/// window's `effectiveAppearance`, preventing `NSToolbarButtonCell` from washing
/// enabled buttons out to gray or caching dark-mode colors across theme switches.
@MainActor
final class ToolbarButton: NSButton {
    var symbolName: String {
        didSet {
            if symbolName != oldValue {
                refreshMetadataImage()
                needsDisplay = true
            }
        }
    }

    var activeTintColor: NSColor {
        didSet {
            refreshMetadataImage()
            needsDisplay = true
        }
    }

    var effectiveTintColor: NSColor {
        isEnabled ? activeTintColor : ToolbarIcon.disabledTintColor
    }

    override var isEnabled: Bool {
        didSet {
            refreshMetadataImage()
            needsDisplay = true
        }
    }

    init(
        title: String,
        symbol: String,
        toolTip: String,
        action: Selector,
        activeTintColor: NSColor = ToolbarIcon.enabledTintColor
    ) {
        self.symbolName = symbol
        self.activeTintColor = activeTintColor
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 24))
        self.title = ""
        self.imagePosition = .imageOnly
        self.isBordered = false
        self.bezelStyle = .regularSquare
        self.target = nil
        self.action = action
        self.toolTip = toolTip
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])
        refreshMetadataImage()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolbarButton is created in code, not from a nib")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = window?.effectiveAppearance ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            if isHighlighted && isEnabled {
                NSColor.labelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(
                    roundedRect: bounds.insetBy(dx: 2, dy: 2),
                    xRadius: 6,
                    yRadius: 6
                ).fill()
            }
            ToolbarIcon.drawSymbol(
                symbolName,
                in: bounds,
                tintColor: effectiveTintColor
            )
        }
    }

    func refreshMetadataImage() {
        let tint = effectiveTintColor
        contentTintColor = tint
        image = ToolbarIcon.makeImage(
            symbol: symbolName,
            tintColor: tint,
            accessibilityDescription: accessibilityLabel()
        )
        needsDisplay = true
    }
}

/// A solid colored status dot that draws directly so `NSToolbar` cannot wash
/// its color out to monochrome gray.
@MainActor
final class BoardStatusDotView: NSView {
    static let diameter: CGFloat = 8

    var dotColor: NSColor = .systemGray {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BoardStatusDotView is created in code, not from a nib")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.diameter, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = window?.effectiveAppearance ?? effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            dotColor.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

/// A bordered toolbar button item whose icon stays full-contrast when enabled
/// and clearly dimmed only when unavailable.
@MainActor
final class ActionToolbarItem: NSToolbarItem {
    let symbolName: String
    let activeTintColor: NSColor
    var isActionEnabled: ((Selector) -> Bool)? {
        didSet { validate() }
    }

    var effectiveTintColor: NSColor {
        isEnabled ? activeTintColor : ToolbarIcon.disabledTintColor
    }

    init(
        itemIdentifier: NSToolbarItem.Identifier,
        title: String,
        symbol: String,
        toolTip: String,
        action: Selector,
        activeTintColor: NSColor = ToolbarIcon.enabledTintColor
    ) {
        self.symbolName = symbol
        self.activeTintColor = activeTintColor
        super.init(itemIdentifier: itemIdentifier)
        label = title
        self.toolTip = toolTip
        isBordered = true
        // No target: the action goes to the window controller through the responder chain.
        self.action = action
        refreshAppearance()
    }

    override var isEnabled: Bool {
        didSet {
            refreshAppearance()
        }
    }

    override func validate() {
        if let action, let isActionEnabled {
            isEnabled = isActionEnabled(action)
        } else {
            super.validate()
            refreshAppearance()
        }
    }

    func refreshAppearance() {
        image = nil
        image = ToolbarIcon.makeImage(
            symbol: symbolName,
            tintColor: effectiveTintColor,
            accessibilityDescription: label
        )
    }
}

/// The main window's toolbar: Build, Flash, the debugger's controls, what
/// the app is doing, and whether a board is plugged in.
///
/// The debugger's run and step buttons appear only during a debug session,
/// next to the Debug button that starts and ends it.
///
/// The buttons send their actions up the responder chain, where the window
/// controller handles them and decides when they are enabled.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "MainToolbar")

    static let connectedBoardText = "Board connected"
    static let disconnectedBoardText = "No board"
    /// Extra visual gap between the Build/Flash group and the Debug group.
    static let groupSpacingWidth: CGFloat = 14

    /// "Board connected" or "No board", with a dot that is green or gray.
    let boardLabel: NSTextField = ToolbarLabel(labelWithString: "")
    let boardDot = BoardStatusDotView()
    /// "Building…", "Build succeeded", "Stopped at main.c:21", and so on.
    let activity = ActivityView()
    /// Whether the run and step buttons are showing.
    private(set) var isShowingDebugControls = false
    private(set) weak var debugItem: DebugControlsItem?
    private(set) weak var buildItem: ActionToolbarItem?
    private(set) weak var flashItem: ActionToolbarItem?

    /// Decides whether toolbar actions can run right now, keeping Build, Flash,
    /// and the debugger buttons in sync with the window controller.
    var isActionEnabled: ((Selector) -> Bool)? {
        didSet {
            debugItem?.isActionEnabled = isActionEnabled
            buildItem?.isActionEnabled = isActionEnabled
            flashItem?.isActionEnabled = isActionEnabled
        }
    }

    enum Item {
        static let build = NSToolbarItem.Identifier("Build")
        static let flash = NSToolbarItem.Identifier("Flash")
        static let groupSpacer = NSToolbarItem.Identifier("GroupSpacer")
        static let debug = NSToolbarItem.Identifier("Debug")
        static let activity = NSToolbarItem.Identifier("Activity")
        static let board = NSToolbarItem.Identifier("Board")
    }

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        boardLabel.font = .systemFont(ofSize: 12, weight: .medium)
        boardLabel.usesSingleLineMode = true
        boardLabel.lineBreakMode = .byClipping
        showBoard(isConnected: false)
    }

    func showBoard(isConnected: Bool) {
        let text = isConnected ? Self.connectedBoardText : Self.disconnectedBoardText
        boardLabel.stringValue = text
        boardLabel.textColor = isConnected ? .labelColor : .secondaryLabelColor
        boardDot.dotColor = isConnected ? .systemGreen : .systemGray
        boardDot.setAccessibilityLabel(text)
    }

    /// Shows the run and step buttons during a debug session, so they are
    /// not a row of disabled buttons the rest of the time.
    func showDebugControls(_ isShown: Bool) {
        isShowingDebugControls = isShown
        debugItem?.showSession(isShown)
    }

    /// The actions of every toolbar button showing now.
    var visibleActions: [Selector] {
        toolbar.items.flatMap { item -> [Selector] in
            if let debug = item as? DebugControlsItem { return debug.visibleActions }
            return item.action.map { [$0] } ?? []
        }
    }

    // MARK: - NSToolbarDelegate

    /// Whether a board is plugged in shows in the status line under the
    /// editor, which keeps the toolbar to the actions and their progress.
    /// `.space` plus `Item.groupSpacer` puts clear visual breathing room
    /// between the Build/Flash group and the Debug group.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Item.build, Item.flash,
            .space, Item.groupSpacer,
            Item.debug,
            .flexibleSpace, Item.activity, .flexibleSpace
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Item.board]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Item.build:
            let item = ActionToolbarItem(
                itemIdentifier: itemIdentifier,
                title: "Build",
                symbol: "hammer",
                toolTip: "Build — Build the project (⌘B)",
                action: #selector(MainWindowController.buildProject(_:))
            )
            item.isActionEnabled = isActionEnabled
            buildItem = item
            return item
        case Item.flash:
            let item = ActionToolbarItem(
                itemIdentifier: itemIdentifier,
                title: "Flash",
                symbol: "arrow.down.to.line",
                toolTip: "Build and Flash — Build the project and write it to the board (⌘R)",
                action: #selector(MainWindowController.flashProject(_:))
            )
            item.isActionEnabled = isActionEnabled
            flashItem = item
            return item
        case Item.groupSpacer:
            return groupSpacerItem(itemIdentifier)
        case Item.debug:
            let item = DebugControlsItem(itemIdentifier: itemIdentifier, isSessionActive: isShowingDebugControls)
            item.isActionEnabled = isActionEnabled
            debugItem = item
            return item
        case Item.activity:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Activity"
            item.view = activity
            item.visibilityPriority = .high
            return item
        case Item.board:
            return boardItem(itemIdentifier)
        default:
            return nil
        }
    }

    private func groupSpacerItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = ""
        // A borderless disabled NSButton suppresses the macOS toolbar capsule
        // background while reserving horizontal breathing room between groups.
        let spacer = NSButton(title: "", target: nil, action: nil)
        spacer.isBordered = false
        spacer.isEnabled = false
        spacer.setAccessibilityElement(false)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spacer.widthAnchor.constraint(equalToConstant: Self.groupSpacingWidth),
            spacer.heightAnchor.constraint(equalToConstant: 1)
        ])
        item.view = spacer
        item.isEnabled = false
        return item
    }

    private func boardItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Board"
        let stack = NSStackView(views: [boardDot, boardLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        // Generous horizontal padding inside the toolbar capsule so the label
        // never crowds or clips at its rounded edges.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        boardLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        boardLabel.setContentHuggingPriority(.required, for: .horizontal)
        // The toolbar sizes the item once, while it may still say "No board",
        // so reserve room for the longer "Board connected" label plus margin.
        let longest = NSTextField(labelWithString: Self.connectedBoardText)
        longest.font = boardLabel.font
        longest.sizeToFit()
        let insets = stack.edgeInsets.left + stack.edgeInsets.right
        let minimumWidth = ceil(
            insets + BoardStatusDotView.diameter + stack.spacing + longest.fittingSize.width + 8
        )
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
        item.view = stack
        return item
    }
}
