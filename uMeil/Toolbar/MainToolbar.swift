import AppKit

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

    /// "Board connected" or "No board", with a dot that is green or gray.
    let boardLabel = NSTextField(labelWithString: "")
    private let boardDot = NSImageView()
    /// "Building…", "Build succeeded", "Stopped at main.c:21", and so on.
    let activity = ActivityView()
    /// Whether the run and step buttons are showing.
    private(set) var isShowingDebugControls = false
    private(set) weak var debugItem: DebugControlsItem?

    /// Decides whether the debugger buttons are enabled, since buttons inside
    /// a toolbar item are not checked through the responder chain.
    var isActionEnabled: ((Selector) -> Bool)? {
        didSet { debugItem?.isActionEnabled = isActionEnabled }
    }

    private enum Item {
        static let build = NSToolbarItem.Identifier("Build")
        static let flash = NSToolbarItem.Identifier("Flash")
        static let debug = NSToolbarItem.Identifier("Debug")
        static let activity = NSToolbarItem.Identifier("Activity")
        static let board = NSToolbarItem.Identifier("Board")
    }

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        showBoard(isConnected: false)
    }

    func showBoard(isConnected: Bool) {
        boardLabel.stringValue = isConnected ? "Board connected" : "No board"
        boardLabel.textColor = isConnected ? .labelColor : .secondaryLabelColor
        // The color is part of the image, since a toolbar draws tinted
        // template images in its own gray.
        let color: NSColor = isConnected ? .systemGreen : .tertiaryLabelColor
        let dot = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        boardDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(dot)
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
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.build, Item.flash, .space, Item.debug, .flexibleSpace, Item.activity, .flexibleSpace]
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
            return button(
                itemIdentifier,
                title: "Build",
                symbol: "hammer",
                toolTip: "Build the project",
                action: #selector(MainWindowController.buildProject(_:))
            )
        case Item.flash:
            return button(
                itemIdentifier,
                title: "Flash",
                symbol: "arrow.down.to.line",
                toolTip: "Build the project and write it to the board",
                action: #selector(MainWindowController.flashProject(_:))
            )
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

    private func boardItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Board"
        let stack = NSStackView(views: [boardDot, boardLabel])
        stack.orientation = .horizontal
        stack.spacing = 5
        // Padding inside the toolbar's capsule, so the text does not run
        // into its rounded edge.
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        // The toolbar sizes the item once, while it still says "No board",
        // so reserve room for the longer text or it is clipped at the edge.
        boardLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let longest = NSTextField(labelWithString: "Board connected")
        longest.font = boardLabel.font
        let dotWidth = boardDot.intrinsicContentSize.width
        let insets = stack.edgeInsets.left + stack.edgeInsets.right
        stack.widthAnchor.constraint(
            greaterThanOrEqualToConstant: ceil(insets + dotWidth + stack.spacing + longest.fittingSize.width)
        ).isActive = true
        item.view = stack
        return item
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier,
        title: String,
        symbol: String,
        toolTip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.toolTip = toolTip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.isBordered = true
        // No target: the action goes to the window controller through the responder chain.
        item.action = action
        return item
    }
}
