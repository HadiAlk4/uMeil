import AppKit
import Testing
@testable import uMeil

@MainActor
struct CodeIntelligenceEditorUnitTests {
    @Test func ranksPrefixCompletionMatchesBeforeSubstringMatches() {
        let items = [
            LSPCompletionItem(label: " ROM_GPIOPinWrite", kind: .function, insertText: "ROM_GPIOPinWrite"),
            LSPCompletionItem(label: " GPIOPinWrite", kind: .function, insertText: "GPIOPinWrite"),
            LSPCompletionItem(label: " SysCtlDelay", kind: .function, insertText: "SysCtlDelay"),
            LSPCompletionItem(label: " GPIOPinRead", kind: .function, insertText: "GPIOPinRead")
        ]

        let ranked = CompletionPanelController.filterAndRank(items, prefix: "gpio")

        #expect(ranked.map(\.insertionText) == ["GPIOPinWrite", "GPIOPinRead", "ROM_GPIOPinWrite"])
        #expect(CompletionPanelController.filterAndRank(items, prefix: "").count == 4)
    }

    @Test func appliesAndClearsInlineUnderlinesTooltipsAndMarkers() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("int main(void) {\n    return missing_sym;\n}\n".utf8).write(to: file)

        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        try editor.open(file)

        let range = LSPRange(start: LSPPosition(line: 1, character: 11), end: LSPPosition(line: 1, character: 22))
        editor.applyLiveDiagnostics([
            LSPDiagnostic(range: range, severity: .error, message: "use of undeclared identifier 'missing_sym'")
        ])

        let offset = (editor.textView.string as NSString).range(of: "missing_sym").location
        let attrs = editor.textView.layoutManager?.temporaryAttributes(atCharacterIndex: offset, effectiveRange: nil)
        #expect(attrs?[.underlineColor] as? NSColor == EditorTheme.inlineErrorColor)
        #expect(attrs?[.toolTip] as? String == "use of undeclared identifier 'missing_sym'")
        #expect(editor.markers == [2: .error])
        #expect(!editor.diagnosticBar.isHidden)

        // Typing clears stale inline attributes synchronously so they never stick at wrong offsets.
        editor.textView.insertText("x", replacementRange: NSRange(location: offset, length: 0))
        let cleared = editor.textView.layoutManager?.temporaryAttributes(atCharacterIndex: offset, effectiveRange: nil)
        #expect(cleared?[.underlineColor] == nil)
        #expect(editor.markers.isEmpty)
        #expect(editor.diagnosticBar.isHidden)
    }

    @Test func turningCodeIntelligenceOffClearsAndIgnoresDiagnostics() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("int main(void) {\n    return missing_sym;\n}\n".utf8).write(to: file)

        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        try editor.open(file)

        let range = LSPRange(start: LSPPosition(line: 1, character: 11), end: LSPPosition(line: 1, character: 22))
        let diagnostic = LSPDiagnostic(range: range, severity: .error, message: "undeclared")
        editor.applyLiveDiagnostics([diagnostic])
        #expect(editor.markers == [2: .error])

        editor.setCodeIntelligenceEnabled(false)
        #expect(editor.liveDiagnostics.isEmpty)
        #expect(editor.markers.isEmpty)
        #expect(editor.diagnosticBar.isHidden)

        // Diagnostics that arrive late from clangd are dropped while off.
        editor.applyLiveDiagnostics([diagnostic])
        #expect(editor.liveDiagnostics.isEmpty)

        let complete = NSMenuItem(title: "Complete", action: #selector(EditorViewController.triggerCompletion(_:)),
                                  keyEquivalent: "")
        #expect(!editor.validateMenuItem(complete))

        editor.setCodeIntelligenceEnabled(true)
        #expect(editor.validateMenuItem(complete))
        editor.applyLiveDiagnostics([diagnostic])
        #expect(editor.markers == [2: .error])
    }

    @Test func detectsCompletionPrefixAndAutoTriggerRules() {
        let editor = EditorViewController()

        #expect(EditorViewController.identifierPrefixRange(in: "    GPIOPin", atUTF16Offset: 11)
            == NSRange(location: 4, length: 7))
        #expect(editor.shouldAutoTriggerCompletion(in: "    G", atUTF16Offset: 5) == false)
        #expect(editor.shouldAutoTriggerCompletion(in: "    GP", atUTF16Offset: 6) == true)
        #expect(editor.shouldAutoTriggerCompletion(in: "port.", atUTF16Offset: 5) == true)
        #expect(editor.shouldAutoTriggerCompletion(in: "ptr->", atUTF16Offset: 5) == true)
        #expect(editor.shouldAutoTriggerCompletion(in: "a > b", atUTF16Offset: 3) == false)
    }

    @Test func acceptingCompletionReplacesTypedPrefix() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("void f(void) {\n    GPIOPin\n}\n".utf8).write(to: file)

        let editor = EditorViewController()
        editor.loadViewIfNeeded()
        try editor.open(file)

        let end = (editor.textView.string as NSString).range(of: "GPIOPin\n").location + "GPIOPin".utf16.count
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        editor.intelligence.completionAnchorOffset = end - "GPIOPin".utf16.count
        editor.acceptCompletion(LSPCompletionItem(label: " GPIOPinWrite", kind: .function, insertText: "GPIOPinWrite"))

        #expect(editor.textView.string == "void f(void) {\n    GPIOPinWrite\n}\n")
        #expect(editor.isModified)
    }
}

@MainActor
@Suite(.enabled(if: ClangdTestEnvironment.canRunClangd))
struct CodeIntelligenceInEditorTests {
    private func makeBlinkyWindow(in folder: TemporaryDirectory) throws -> MainWindowController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let controller = MainWindowController(defaults: defaults)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        try controller.createProject(named: "Blinky", in: folder.url)
        return controller
    }

    private func waitUntil(
        timeout: Duration = .seconds(20),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + TestTiming.duration(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return condition()
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func openingBlinkyPreparesCompileCommandsAndNavigatesToDriverLibDefinition() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let projectFolder = try #require(controller.folder)
        let compileDB = projectFolder.appending(path: "build/compile_commands.json")
        #expect(FileManager.default.fileExists(atPath: compileDB.path(percentEncoded: false)))

        let text = controller.editor.textView.string
        let callRange = (text as NSString).range(of: "GPIOPinWrite(")
        controller.editor.textView.setSelectedRange(NSRange(location: callRange.location + 2, length: 0))

        // clangd answers nothing until it has parsed main.c, which on a slow
        // CI runner can outlast the first request, so ask again as a person
        // would.
        var navigated = false
        for _ in 0..<7 where !navigated {
            controller.jumpToDefinitionMenuAction(nil)
            navigated = await waitUntil(timeout: .seconds(3)) {
                controller.editor.document?.url.lastPathComponent == "gpio.h"
            }
        }
        #expect(navigated)
        #expect(controller.editor.document?.url.pathComponents.contains("driverlib") == true)
        controller.codeIntelligence?.stop()
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func inlineErrorsAndAutocompleteWorkWhileEditingBlinky() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let textView = controller.editor.textView
        let original = textView.string

        // Wait until initial clean parse finishes, then introduce an error.
        try await Task.sleep(for: .milliseconds(250))
        let broken = original.replacingOccurrences(
            of: "GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0);",
            with: "missing_editor_symbol();"
        )
        textView.insertText(broken, replacementRange: NSRange(location: 0, length: (original as NSString).length))

        let flagged = await waitUntil {
            !controller.editor.liveDiagnostics.isEmpty && !controller.editor.diagnosticBar.isHidden
        }
        #expect(flagged)
        #expect(controller.editor.liveDiagnostics.contains { $0.message.contains("missing_editor_symbol") })
        #expect(!controller.editor.markers.isEmpty)

        // Replace with a partial driverlib symbol and request completion.
        let typing = original.replacingOccurrences(
            of: "GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0);",
            with: "GPIOPin"
        )
        textView.insertText(
            typing,
            replacementRange: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        let cursor = (typing as NSString).range(of: "GPIOPin\n").location + "GPIOPin".utf16.count
        textView.setSelectedRange(NSRange(location: cursor, length: 0))

        await controller.editor.performCompletionRequest()

        let hasDriverLibMatch = controller.editor.completionPanel.filteredItems.contains {
            $0.insertionText == "GPIOPinWrite"
        }
        #expect(hasDriverLibMatch)
        controller.editor.completionPanel.dismiss()
        controller.codeIntelligence?.stop()
    }
}

/// The Edit > Code Intelligence switch in the main window.
@MainActor
struct CodeIntelligenceToggleTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @Test func isOnByDefaultAndShowsAsChecked() throws {
        let controller = MainWindowController(defaults: try makeDefaults(), boardMonitor: FakeBoardMonitor())
        let item = menuItem(#selector(MainWindowController.toggleCodeIntelligence(_:)))

        #expect(controller.isCodeIntelligenceEnabled)
        #expect(controller.codeIntelligence?.isEnabled == true)
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .on)
    }

    @Test func togglingTurnsItOffAndIsRememberedForTheNextWindow() throws {
        let defaults = try makeDefaults()
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        let item = menuItem(#selector(MainWindowController.toggleCodeIntelligence(_:)))

        controller.toggleCodeIntelligence(nil)
        _ = controller.validateMenuItem(item)
        #expect(item.state == .off)
        #expect(controller.codeIntelligence?.isEnabled == false)
        #expect(!controller.editor.intelligence.isEnabled)

        let next = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        #expect(!next.isCodeIntelligenceEnabled)
        #expect(next.codeIntelligence?.isEnabled == false)
        #expect(!next.editor.intelligence.isEnabled)

        next.toggleCodeIntelligence(nil)
        #expect(next.isCodeIntelligenceEnabled)
        #expect(next.editor.intelligence.isEnabled)
    }

    @Test func jumpToDefinitionIsDisabledWhileOff() throws {
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: file)

        let controller = MainWindowController(defaults: try makeDefaults(), boardMonitor: FakeBoardMonitor())
        controller.openItem(at: file)
        let jump = menuItem(#selector(MainWindowController.jumpToDefinitionMenuAction(_:)))
        #expect(controller.validateMenuItem(jump))

        controller.toggleCodeIntelligence(nil)
        #expect(!controller.validateMenuItem(jump))
    }
}
