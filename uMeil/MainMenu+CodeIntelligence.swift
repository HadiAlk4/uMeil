import AppKit

extension MainMenu {
    /// Edit menu commands backed by `clangd`.
    static func addCodeIntelligenceItems(to menu: NSMenu) {
        menu.addItem(
            withTitle: "Code Intelligence",
            action: #selector(MainWindowController.toggleCodeIntelligence(_:)),
            keyEquivalent: ""
        )
        let complete = menu.addItem(
            withTitle: "Complete",
            action: #selector(EditorViewController.triggerCompletion(_:)),
            keyEquivalent: " "
        )
        complete.keyEquivalentModifierMask = [.control]

        let jump = menu.addItem(
            withTitle: "Jump to Definition",
            action: #selector(MainWindowController.jumpToDefinitionMenuAction(_:)),
            keyEquivalent: "j"
        )
        jump.keyEquivalentModifierMask = [.control, .command]

        // F2 also renames; the text view handles that key itself.
        let rename = menu.addItem(
            withTitle: "Rename Symbol…",
            action: #selector(EditorViewController.renameSymbol(_:)),
            keyEquivalent: "e"
        )
        rename.keyEquivalentModifierMask = [.control, .command]

        let format = menu.addItem(
            withTitle: "Format Selection",
            action: #selector(EditorViewController.formatSelection(_:)),
            keyEquivalent: "i"
        )
        format.keyEquivalentModifierMask = [.control]
    }
}
