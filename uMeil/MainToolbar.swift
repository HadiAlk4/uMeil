import AppKit

/// The main window's toolbar: Build, Flash, and whether a board is plugged in.
///
/// The buttons send their actions up the responder chain, where the window
/// controller handles them and decides when they are enabled.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "MainToolbar")

    /// "Board connected" or "No board", with a dot that is green or gray.
    let boardLabel = NSTextField(labelWithString: "")
    private let boardDot = NSImageView()

    private enum Item {
        static let build = NSToolbarItem.Identifier("Build")
        static let flash = NSToolbarItem.Identifier("Flash")
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

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.build, Item.flash, .flexibleSpace, Item.board]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
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
        case Item.board:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Board"
            let stack = NSStackView(views: [boardDot, boardLabel])
            stack.orientation = .horizontal
            stack.spacing = 5
            item.view = stack
            return item
        default:
            return nil
        }
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
