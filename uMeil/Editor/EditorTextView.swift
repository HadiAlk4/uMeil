import AppKit

/// `NSTextView` subclass adding Cmd+Click definition jumps, context menu jump,
/// and keyboard routing for the non-activating completion popup.
final class EditorTextView: NSTextView {
    /// Called with the UTF-16 character index when the user Cmd+Clicks on text.
    var onCommandClick: ((Int) -> Void)?
    /// Called when the user invokes autocomplete (`Ctrl+Space` or `Esc`/`F5` `complete(_:)`).
    var onRequestCompletion: (() -> Void)?
    /// Called first on `keyDown` so an open completion popup can intercept arrows, Return, Tab, and Esc.
    var completionKeyHandler: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let offset = characterOffset(for: event) {
            onCommandClick?(offset)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if completionKeyHandler?(event) == true {
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .control, event.charactersIgnoringModifiers == " " {
            onRequestCompletion?()
            return
        }
        super.keyDown(with: event)
    }

    override func complete(_ sender: Any?) {
        onRequestCompletion?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let contextMenu = super.menu(for: event) ?? NSMenu()
        let jumpItem = NSMenuItem(
            title: "Jump to Definition",
            action: #selector(MainWindowController.jumpToDefinitionMenuAction(_:)),
            keyEquivalent: ""
        )
        contextMenu.insertItem(jumpItem, at: 0)
        contextMenu.insertItem(.separator(), at: 1)
        return contextMenu
    }

    private func characterOffset(for event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else {
            return nil
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard lineRect.insetBy(dx: -4, dy: -2).contains(containerPoint) else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return charIndex < storage.length ? charIndex : nil
    }
}
