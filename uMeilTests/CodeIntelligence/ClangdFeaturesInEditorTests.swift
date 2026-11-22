import AppKit
import Testing
@testable import uMeil

/// Snippets, parameter hints, hover, rename, and formatting against a real
/// `clangd` and the Blinky template.
@MainActor
@Suite(.enabled(if: ClangdTestEnvironment.canRunClangd))
struct ClangdFeaturesInEditorTests {
    private func makeBlinkyWindow(in folder: TemporaryDirectory) throws -> MainWindowController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let controller = MainWindowController(defaults: defaults)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
        try controller.createProject(named: "Blinky", in: folder.url)
        return controller
    }

    /// Replaces `target` in the editor with `replacement` and puts the
    /// cursor where `|` is in it.
    private func type(_ replacement: String, over target: String, in editor: EditorViewController) {
        let textView = editor.textView
        let range = (textView.string as NSString).range(of: target)
        let cursorOffset = (replacement as NSString).range(of: "|").location
        let clean = replacement.replacingOccurrences(of: "|", with: "")
        textView.insertText(clean, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + cursorOffset, length: 0))
    }

    /// clangd answers nothing useful until it has parsed main.c, which can
    /// outlast the first request on a slow machine, so ask again as a person would.
    private func retry(_ attempt: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + TestTiming.duration(.seconds(20))
        while ContinuousClock.now < deadline {
            if await attempt() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func completingADriverLibFunctionInsertsItsArguments() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let editor = controller.editor
        type("GPIOPinWr|", over: "GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0);", in: editor)

        // Until its headers are parsed, clangd offers only words from the
        // file itself; wait for the real function.
        let isFunction = { (item: LSPCompletionItem) in item.filterKey == "GPIOPinWrite" && item.kind == .function }
        let found = await retry {
            await editor.performCompletionRequest()
            return editor.completionPanel.filteredItems.contains(where: isFunction)
        }
        #expect(found)
        let item = try #require(editor.completionPanel.filteredItems.first(where: isFunction))
        editor.completionPanel.dismiss()
        editor.acceptCompletion(item)

        #expect(editor.textView.string.contains("GPIOPinWrite(ui32Port, ui8Pins, ui8Val)\n"))
        let selected = (editor.textView.string as NSString).substring(with: editor.textView.selectedRange())
        #expect(selected == "ui32Port")
        controller.codeIntelligence?.stop()
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func typingACallShowsItsSignatureWithTheCurrentArgument() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let editor = controller.editor
        type("GPIOPinWrite(GPIO_PORTN_BASE, |);", over: "GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0);", in: editor)

        let shown = await retry {
            await editor.performSignatureHelpRequest()
            return editor.signaturePanel.isVisible
        }
        #expect(shown)
        #expect(editor.signaturePanel.text?.string.contains("GPIOPinWrite(uint32_t ui32Port") == true)
        #expect(editor.intelligence.signatureHelp?.activeParameterName == "ui8Pins")

        // Outside any call there is nothing to show.
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        await editor.performSignatureHelpRequest()
        #expect(!editor.signaturePanel.isVisible)
        controller.codeIntelligence?.stop()
    }
}
