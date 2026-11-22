import AppKit

/// Follows the font chosen in Settings, or with ⌘+ and ⌘−, everywhere the
/// window shows code: the editor, the terminal, the debugger's console,
/// and its tables.
extension MainWindowController {
    func observeAppearanceSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceSettingsChanged(_:)),
            name: AppearanceSettings.didChange,
            object: nil
        )
    }

    @objc func appearanceSettingsChanged(_ notification: Notification) {
        applyFontSettings()
    }

    func applyFontSettings() {
        editor.applyFontSettings()
        terminal.applyFont()
        debugPanels.command.applyFont()
        let tables: [(NSTableView, CGFloat)] = [
            (debugPanels.registers.outlineView, RegistersViewController.baseRowHeight),
            (debugPanels.callStackLocals.outlineView, CallStackLocalsViewController.baseRowHeight),
            (debugPanels.disassembly.tableView, DisassemblyViewController.baseRowHeight),
            (debugPanels.watch.tableView, WatchViewController.baseRowHeight),
            (debugPanels.memory.tableView, MemoryViewController.baseRowHeight),
            (debugPanels.peripherals.outlineView, PeripheralsViewController.baseRowHeight)
        ]
        for (table, base) in tables {
            DebugTableStyle.applyFont(to: table, base: base)
        }
        debugPanels.watch.inputField.font = EditorTheme.font
        debugPanels.memory.addressField.font = EditorTheme.font
    }
}
