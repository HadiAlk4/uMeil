import AppKit

/// The app menu's Settings window and the View menu's font sizes.
extension AppDelegate: NSMenuItemValidation {
    /// uMeil > Settings… (⌘,)
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow(sender)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(sender)
    }

    /// View > Bigger Font (⌘+)
    @objc func makeFontBigger(_ sender: Any?) {
        AppearanceSettings.shared.makeFontBigger()
    }

    /// View > Smaller Font (⌘−)
    @objc func makeFontSmaller(_ sender: Any?) {
        AppearanceSettings.shared.makeFontSmaller()
    }

    /// View > Actual Size (⌘0)
    @objc func resetFontSize(_ sender: Any?) {
        AppearanceSettings.shared.resetFontSize()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let settings = AppearanceSettings.shared
        switch menuItem.action {
        case #selector(makeFontBigger(_:)): return settings.canMakeFontBigger
        case #selector(makeFontSmaller(_:)): return settings.canMakeFontSmaller
        case #selector(resetFontSize(_:)): return settings.fontSize != AppearanceSettings.defaultSize
        default: return true
        }
    }

    /// Applies the saved theme, and lets ⌘= make the font bigger too: "+"
    /// needs Shift on most keyboards, and people press ⌘= expecting it.
    func setUpAppearance() {
        AppearanceSettings.shared.applyTheme()
        // Local monitors are called on the main thread.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isBiggerFontShortcut(event) else { return event }
            let handled = MainActor.assumeIsolated { Self.makeFontBiggerIfPossible() }
            return handled ? nil : event
        }
    }

    nonisolated static func isBiggerFontShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers == "="
    }

    private static func makeFontBiggerIfPossible() -> Bool {
        guard AppearanceSettings.shared.canMakeFontBigger else { return false }
        AppearanceSettings.shared.makeFontBigger()
        return true
    }
}
