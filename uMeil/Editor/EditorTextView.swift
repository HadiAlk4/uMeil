import AppKit

/// `NSTextView` subclass adding Cmd+Click definition jumps, context menu jump,
/// and keyboard routing for the non-activating completion popup.
final class EditorTextView: NSTextView {
    /// Called with the UTF-16 character index when the user Cmd+Clicks on text
    /// or picks Jump to Definition from the context menu over it.
    var onCommandClick: ((Int) -> Void)?
    /// Called with the UTF-16 character index under the mouse as it moves over
    /// the text, or `nil` when it is over no character or leaves the view.
    var onHoverCharacter: ((Int?) -> Void)?
    /// Called when the user invokes autocomplete (`Ctrl+Space` or `Esc`/`F5` `complete(_:)`).
    var onRequestCompletion: (() -> Void)?
    /// Called first on `keyDown` so an open completion popup can intercept arrows, Return, Tab, and Esc.
    var completionKeyHandler: ((NSEvent) -> Bool)?

    private var hoverTrackingArea: NSTrackingArea?

    /// The last build's messages, drawn at the ends of their lines.
    var inlineMessages: [InlineMessage] = [] {
        didSet {
            if inlineMessages != oldValue { needsDisplay = true }
        }
    }

    /// Values drawn after the ends of lines while debugging, such as `count = 4`.
    var inlineAnnotations: [InlineAnnotation] = [] {
        didSet {
            if inlineAnnotations != oldValue { needsDisplay = true }
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawInlineMessages(in: rect)
        drawInlineAnnotations(in: rect)
    }

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHoverCharacter?(characterOffset(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverCharacter?(nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let contextMenu = super.menu(for: event) ?? NSMenu()
        let jumpItem: NSMenuItem
        if let offset = characterOffset(for: event) {
            // Right-clicking does not move the cursor, so jump from the
            // symbol that was clicked rather than the one at the cursor.
            jumpItem = NSMenuItem(
                title: "Jump to Definition",
                action: #selector(jumpToClickedDefinition(_:)),
                keyEquivalent: ""
            )
            jumpItem.target = self
            jumpItem.representedObject = offset
        } else {
            jumpItem = NSMenuItem(
                title: "Jump to Definition",
                action: #selector(MainWindowController.jumpToDefinitionMenuAction(_:)),
                keyEquivalent: ""
            )
        }
        contextMenu.insertItem(jumpItem, at: 0)
        contextMenu.insertItem(.separator(), at: 1)
        return contextMenu
    }

    @objc private func jumpToClickedDefinition(_ sender: NSMenuItem) {
        guard let offset = sender.representedObject as? Int else { return }
        onCommandClick?(offset)
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
