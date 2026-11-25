import AppKit
import Testing
@testable import uMeil

/// Snippets, parameter hints, hover, rename, and formatting against a real
/// `clangd` and the Blinky template.
@MainActor
@Suite(.enabled(if: ClangdTestEnvironment.canRunClangd))
struct ClangdFeaturesInEditorTests {
    private func makeBlinkyWindow(in folder: TemporaryDirectory) throws -> MainWindowController {
        let defaults = TestDefaults()

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

    /// Waits until clangd has parsed main.c together with its TivaWare
    /// headers. Until then clangd answers completions with plain words from
    /// the file, and repeating the request does not make the headers parse
    /// any sooner. A hover waits for the parse, so on a busy machine it is
    /// the way to wait. Call it before editing the call to GPIOPinWrite.
    private func waitForHeaders(in editor: EditorViewController) async -> Bool {
        let pin = (editor.textView.string as NSString).range(of: "GPIO_PIN_1);").location + 3
        let parsed = await retry {
            editor.intelligence.hoverRange = nil
            return await editor.showCodeHover(atCharacterIndex: pin)?.contains("0x00000002") == true
        }
        editor.dismissCodeHover()
        return parsed
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func completingADriverLibFunctionInsertsItsArguments() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let editor = controller.editor
        #expect(await waitForHeaders(in: editor))
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

    @Test(.timeLimit(TestTiming.minutes(1)))
    func hoveringAMacroShowsItsValue() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let editor = controller.editor
        let pin = (editor.textView.string as NSString).range(of: "GPIO_PIN_1);").location + 3

        var shown: String?
        let answered = await retry {
            editor.intelligence.hoverRange = nil
            shown = await editor.showCodeHover(atCharacterIndex: pin)
            return shown?.contains("0x00000002") == true
        }
        #expect(answered, "hover said: \(shown ?? "nothing")")
        #expect(editor.hoverPanel.isVisible)

        // Typing hides it.
        editor.textView.insertText(" ", replacementRange: NSRange(location: 0, length: 0))
        #expect(!editor.hoverPanel.isVisible)
        controller.codeIntelligence?.stop()
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func completionsThatFitTheArgumentComeFirst() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let editor = controller.editor
        #expect(await waitForHeaders(in: editor))
        type("GPIOPinWrite(GPIO_PORTN_BASE, GPIO_P|", over: "GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, 0);", in: editor)

        var first: [String] = []
        let ranked = await retry {
            await editor.performCompletionRequest()
            first = editor.completionPanel.filteredItems.prefix(3).map(\.filterKey)
            return !first.isEmpty && first.allSatisfy { $0.hasPrefix("GPIO_PIN_") }
        }
        #expect(ranked, "listed first: \(first)")
        editor.completionPanel.dismiss()
        controller.codeIntelligence?.stop()
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func renamingAVariableChangesEveryUseInOneUndo() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let editor = controller.editor
        let textView = editor.textView
        let before = textView.string
            .replacingOccurrences(of: "for (;;) {", with: "uint32_t pause = HALF_SECOND;\n    for (;;) {")
            .replacingOccurrences(of: "SysCtlDelay(HALF_SECOND)", with: "SysCtlDelay(pause)")
        let everything = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText(before, replacementRange: everything)
        textView.undoManager?.removeAllActions()

        var problems: [String] = []
        editor.intelligence.renamePrompt = { _ in "halfSecond" }
        editor.intelligence.renameProblemHandler = { problems.append($0) }
        let use = (before as NSString).range(of: "SysCtlDelay(pause)").location + 14
        textView.setSelectedRange(NSRange(location: use, length: 0))

        let renamed = await retry {
            problems.removeAll()
            await editor.performRename()
            return !textView.string.contains("pause")
        }
        #expect(renamed, "problems: \(problems)")
        #expect(textView.string.components(separatedBy: "halfSecond").count - 1 == 3)
        #expect(editor.isModified)

        textView.undoManager?.undo()
        #expect(textView.string == before)
        controller.codeIntelligence?.stop()
    }

    @Test(.timeLimit(TestTiming.minutes(1)))
    func renamingATivaWareFunctionIsRefused() async throws {
        let temp = try TemporaryDirectory()
        let controller = try makeBlinkyWindow(in: temp)
        let editor = controller.editor
        let original = editor.textView.string
        var problems: [String] = []
        editor.intelligence.renamePrompt = { _ in "WritePin" }
        editor.intelligence.renameProblemHandler = { problems.append($0) }
        let call = (original as NSString).range(of: "GPIOPinWrite(").location + 3
        editor.textView.setSelectedRange(NSRange(location: call, length: 0))

        // Early answers can be "not indexed yet"; wait for clangd's real answer.
        let refused = await retry {
            problems.removeAll()
            await editor.performRename()
            return problems.contains { $0.contains("gpio.h") }
        }
        #expect(refused, "problems: \(problems)")
        #expect(editor.textView.string == original)
        controller.codeIntelligence?.stop()
    }
}
