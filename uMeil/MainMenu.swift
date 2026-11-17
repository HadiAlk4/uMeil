import AppKit

/// Builds the menu bar in code, since the app has no storyboard or nib.
@MainActor
enum MainMenu {
    static func make(appName: String) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(appMenu(appName: appName)))
        mainMenu.addItem(submenuItem(fileMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(viewMenu()))
        mainMenu.addItem(submenuItem(productMenu()))
        mainMenu.addItem(submenuItem(debugMenu()))

        let window = windowMenu()
        mainMenu.addItem(submenuItem(window))
        NSApp.windowsMenu = window

        return mainMenu
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private static func appMenu(appName: String) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        let newProject = menu.addItem(
            withTitle: "New Project…",
            action: #selector(MainWindowController.newProject(_:)),
            keyEquivalent: "n"
        )
        newProject.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: "Open…",
            action: #selector(MainWindowController.openDocument(_:)),
            keyEquivalent: "o"
        )
        let openFolder = menu.addItem(
            withTitle: "Open Folder…",
            action: #selector(MainWindowController.chooseFolder(_:)),
            keyEquivalent: "o"
        )
        openFolder.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: "Import Keil Project…",
            action: #selector(MainWindowController.importKeilProject(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Save", action: #selector(MainWindowController.saveDocument(_:)), keyEquivalent: "s")
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(
            withTitle: "Show Terminal",
            action: #selector(MainWindowController.toggleTerminal(_:)),
            keyEquivalent: "j"
        )
        menu.addItem(
            withTitle: "Show Issues",
            action: #selector(MainWindowController.toggleIssues(_:)),
            keyEquivalent: ""
        )
        return menu
    }

    private static func productMenu() -> NSMenu {
        let menu = NSMenu(title: "Product")
        menu.addItem(withTitle: "Build", action: #selector(MainWindowController.buildProject(_:)), keyEquivalent: "b")
        menu.addItem(
            withTitle: "Build and Flash",
            action: #selector(MainWindowController.flashProject(_:)),
            keyEquivalent: "r"
        )
        menu.addItem(
            withTitle: "Flash Image…",
            action: #selector(MainWindowController.flashImage(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Stop", action: #selector(MainWindowController.stopFlashing(_:)), keyEquivalent: ".")
        return menu
    }

    /// The shortcuts are the Keil µVision debugger's, which the course uses.
    private static func debugMenu() -> NSMenu {
        let menu = NSMenu(title: "Debug")
        func add(_ title: String, _ action: Selector, key: Int, control: Bool = false) {
            let functionKey = UnicodeScalar(key).map { String(Character($0)) } ?? ""
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: functionKey)
            item.keyEquivalentModifierMask = control ? [.control] : []
        }

        add("Start/Stop Debug Session", #selector(MainWindowController.toggleDebugging(_:)), key: NSF5FunctionKey,
            control: true)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset", action: #selector(MainWindowController.debugReset(_:)), keyEquivalent: "")
        add("Run", #selector(MainWindowController.debugContinue(_:)), key: NSF5FunctionKey)
        menu.addItem(withTitle: "Stop", action: #selector(MainWindowController.debugPause(_:)), keyEquivalent: "")
        add("Step", #selector(MainWindowController.debugStepInto(_:)), key: NSF11FunctionKey)
        add("Step Over", #selector(MainWindowController.debugStepOver(_:)), key: NSF10FunctionKey)
        add("Step Out", #selector(MainWindowController.debugStepOut(_:)), key: NSF11FunctionKey, control: true)
        add("Run to Cursor Line", #selector(MainWindowController.debugRunToCursor(_:)), key: NSF10FunctionKey,
            control: true)
        menu.addItem(.separator())
        add("Insert/Remove Breakpoint", #selector(MainWindowController.toggleBreakpointAtCursor(_:)),
            key: NSF9FunctionKey)
        return menu
    }

    /// Edit > Find. The items drive the text view's built-in find bar; the
    /// tag on each item says which find action it performs.
    private static func findMenu() -> NSMenu {
        let menu = NSMenu(title: "Find")
        struct FindItem {
            let title: String
            let action: NSTextFinder.Action
            let key: String
            let modifiers: NSEvent.ModifierFlags
        }
        let items = [
            FindItem(title: "Find…", action: .showFindInterface, key: "f", modifiers: [.command]),
            FindItem(
                title: "Find and Replace…",
                action: .showReplaceInterface,
                key: "f",
                modifiers: [.command, .option]
            ),
            FindItem(title: "Find Next", action: .nextMatch, key: "g", modifiers: [.command]),
            FindItem(title: "Find Previous", action: .previousMatch, key: "g", modifiers: [.command, .shift]),
            FindItem(title: "Use Selection for Find", action: .setSearchString, key: "e", modifiers: [.command])
        ]
        for findItem in items {
            let item = menu.addItem(
                withTitle: findItem.title,
                action: #selector(NSResponder.performTextFinderAction(_:)),
                keyEquivalent: findItem.key
            )
            item.keyEquivalentModifierMask = findItem.modifiers
            item.tag = findItem.action.rawValue
        }
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())

        let find = menu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
        find.submenu = findMenu()

        menu.addItem(.separator())
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
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Toolchain Status",
            action: #selector(AppDelegate.showToolchainStatus(_:)),
            keyEquivalent: ""
        )
        let serialMonitor = menu.addItem(
            withTitle: "Serial Monitor",
            action: #selector(AppDelegate.showSerialMonitor(_:)),
            keyEquivalent: "m"
        )
        serialMonitor.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }
}
