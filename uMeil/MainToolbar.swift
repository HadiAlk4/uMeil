import AppKit

/// The main window's toolbar: Build, Flash, the debugger's controls, and
/// whether a board is plugged in.
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

    /// A button for one of the debugger's commands.
    private struct DebugButton {
        var title: String
        var symbol: String
        var toolTip: String
        var action: Selector

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("Debug." + title) }
    }

    /// The names follow the Keil µVision debugger, which the course uses.
    private let debugButtons = [
        DebugButton(
            title: "Debug",
            symbol: "ladybug",
            toolTip: "Start or stop a debug session",
            action: #selector(MainWindowController.toggleDebugging(_:))
        ),
        DebugButton(
            title: "Reset",
            symbol: "arrow.counterclockwise",
            toolTip: "Reset the chip and stop at its first instruction",
            action: #selector(MainWindowController.debugReset(_:))
        ),
        DebugButton(
            title: "Run",
            symbol: "play",
            toolTip: "Run until a breakpoint",
            action: #selector(MainWindowController.debugContinue(_:))
        ),
        DebugButton(
            title: "Stop",
            symbol: "xmark.circle",
            toolTip: "Stop the running program where it is",
            action: #selector(MainWindowController.debugPause(_:))
        ),
        DebugButton(
            title: "Step",
            symbol: "arrow.down.right",
            toolTip: "Run one line, going into a function it calls",
            action: #selector(MainWindowController.debugStepInto(_:))
        ),
        DebugButton(
            title: "Step Over",
            symbol: "arrow.turn.up.right",
            toolTip: "Run one line, including any function it calls",
            action: #selector(MainWindowController.debugStepOver(_:))
        ),
        DebugButton(
            title: "Step Out",
            symbol: "arrow.up.left",
            toolTip: "Run until this function returns",
            action: #selector(MainWindowController.debugStepOut(_:))
        ),
        DebugButton(
            title: "Run to Cursor Line",
            symbol: "arrow.right.to.line",
            toolTip: "Run until the line the cursor is on",
            action: #selector(MainWindowController.debugRunToCursor(_:))
        )
    ]

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
        [Item.build, Item.flash, .space] + debugButtons.map(\.identifier) + [.flexibleSpace, Item.board]
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
            // The toolbar sizes the item once, while it still says "No board",
            // so reserve room for the longer text or it is clipped at the edge.
            boardLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            let longest = NSTextField(labelWithString: "Board connected")
            longest.font = boardLabel.font
            let dotWidth = boardDot.intrinsicContentSize.width
            stack.widthAnchor.constraint(
                greaterThanOrEqualToConstant: ceil(dotWidth + stack.spacing + longest.fittingSize.width)
            ).isActive = true
            item.view = stack
            return item
        default:
            guard let debug = debugButtons.first(where: { $0.identifier == itemIdentifier }) else { return nil }
            return button(
                itemIdentifier,
                title: debug.title,
                symbol: debug.symbol,
                toolTip: debug.toolTip,
                action: debug.action
            )
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
