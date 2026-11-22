import AppKit
import Testing
@testable import uMeil

@MainActor
struct AppearanceSettingsTests {
    private func makeSettings() throws -> AppearanceSettings {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return AppearanceSettings(defaults: defaults)
    }

    /// Runs `body` with the app's shared settings at `size`, then puts them back.
    private func withSharedFontSize(_ size: CGFloat, _ body: () throws -> Void) rethrows {
        let shared = AppearanceSettings.shared
        let saved = shared.fontSize
        defer { shared.fontSize = saved }
        shared.fontSize = size
        try body()
    }

    // MARK: - Settings

    @Test func theFontStartsAtThirteenPointsInTheSystemMonospacedFont() throws {
        let settings = try makeSettings()
        #expect(settings.fontSize == 13)
        #expect(settings.fontName == nil)
        #expect(settings.font.pointSize == 13)
        #expect(settings.font.isFixedPitch)
    }

    @Test func biggerAndSmallerStepByAPointAndStopAtTheEnds() throws {
        let settings = try makeSettings()
        settings.makeFontBigger()
        #expect(settings.fontSize == 14)
        settings.makeFontSmaller()
        settings.makeFontSmaller()
        #expect(settings.fontSize == 12)

        settings.fontSize = 100
        #expect(settings.fontSize == AppearanceSettings.sizes.upperBound)
        #expect(!settings.canMakeFontBigger)
        settings.fontSize = 1
        #expect(settings.fontSize == AppearanceSettings.sizes.lowerBound)
        #expect(!settings.canMakeFontSmaller)

        settings.resetFontSize()
        #expect(settings.fontSize == 13)
    }

    @Test func aChosenFontIsUsedAndAMissingOneFallsBack() throws {
        let settings = try makeSettings()
        settings.fontName = "Menlo-Regular"
        #expect(settings.font.fontName == "Menlo-Regular")

        settings.fontName = "No-Such-Font"
        #expect(settings.font.isFixedPitch)
        #expect(settings.font.pointSize == 13)
    }

    @Test func choicesAreSavedAndAnnounced() throws {
        let settings = try makeSettings()
        var announcements = 0
        let token = NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChange, object: settings, queue: nil
        ) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        settings.fontSize = 18
        settings.fontSize = 18
        settings.theme = .dark

        #expect(announcements == 2)
        let reloaded = AppearanceSettings(defaults: settings.defaults)
        #expect(reloaded.fontSize == 18)
        #expect(reloaded.theme == .dark)
        #expect(AppearanceSettings.Theme.dark.appearance?.name == .darkAqua)
        #expect(AppearanceSettings.Theme.system.appearance == nil)
    }

    @Test func theFontListOffersOnlyRegularFixedWidthFaces() {
        let names = AppearanceSettings.monospacedFontNames()
        #expect(names.contains("Menlo-Regular"))
        #expect(!names.contains("Menlo-Bold"))
    }

    // MARK: - Everything follows the size

    @Test func theEditorGutterAndTablesFollowTheSize() {
        withSharedFontSize(20) {
            #expect(EditorTheme.font.pointSize == 20)
            #expect(EditorTheme.lineNumberFont.pointSize == 18)
            #expect(DebugTableStyle.font.pointSize == 19)
            #expect(DebugTableStyle.rowHeight(base: 19) == 26)
        }
        #expect(DebugTableStyle.rowHeight(base: 19) == 19)
    }

    @Test func anOpenFileTheConsoleAndTheTablesTakeTheNewSize() throws {
        let folder = try TemporaryFolder()
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        try controller.createProject(named: "Blinky", in: folder.url)
        controller.debugPanels.command.appendOutput("Open On-Chip Debugger\n")

        try withSharedFontSize(22) {
            let storage = try #require(controller.editor.textView.textStorage)
            let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.pointSize == 22)
            #expect(controller.editor.textView.typingAttributes[.font] as? NSFont == EditorTheme.font)

            let console = controller.debugPanels.command.textView
            #expect(console.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == EditorTheme.font)
            #expect(controller.debugPanels.watch.tableView.rowHeight == 28)
        }
        #expect(controller.debugPanels.watch.tableView.rowHeight == 19)
    }

    // MARK: - Settings window and shortcuts

    @Test func theSettingsWindowChangesAndFollowsTheSettings() throws {
        let settings = try makeSettings()
        let window = SettingsWindowController(settings: settings)
        #expect(window.sizeField.integerValue == 13)
        #expect(window.fontPopUp.titleOfSelectedItem == "System Monospaced")

        window.sizeStepper.integerValue = 16
        window.sizeStepped(window.sizeStepper)
        #expect(settings.fontSize == 16)

        settings.makeFontBigger()
        #expect(window.sizeField.integerValue == 17)

        let menlo = try #require(
            window.fontPopUp.itemArray.first { $0.representedObject as? String == "Menlo-Regular" }
        )
        window.fontPopUp.select(menlo)
        window.fontChosen(window.fontPopUp)
        #expect(settings.fontName == "Menlo-Regular")

        window.themeControl.selectedSegment = 2
        window.themeChosen(window.themeControl)
        #expect(settings.theme == .dark)
        NSApp.appearance = nil
    }

    @Test func commandEqualsCountsAsCommandPlus() throws {
        func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: 24
            ))
        }
        #expect(AppDelegate.isBiggerFontShortcut(try key("=", .command)))
        #expect(!AppDelegate.isBiggerFontShortcut(try key("=", [.command, .option])))
        #expect(!AppDelegate.isBiggerFontShortcut(try key("-", .command)))
    }

    @Test func theViewMenuHasTheFontSizesAndTheAppMenuHasSettings() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        let bigger = try #require(items.first { $0.action == #selector(AppDelegate.makeFontBigger(_:)) })
        #expect(bigger.keyEquivalent == "+")
        #expect(items.contains { $0.action == #selector(AppDelegate.makeFontSmaller(_:)) && $0.keyEquivalent == "-" })
        #expect(items.contains { $0.action == #selector(AppDelegate.showSettings(_:)) && $0.keyEquivalent == "," })
    }
}
