import AppKit
import Testing
@testable import uMeil

@MainActor
struct InlineValuesTests {
    private func variable(_ name: String, _ value: String?) throws -> DebugVariable {
        var fields = [MIField(name: "name", value: .string(name))]
        if let value { fields.append(MIField(name: "value", value: .string(value))) }
        return try #require(DebugVariable(.tuple(fields)))
    }

    private let source = """
        #include <stdint.h>

        static int helper(int count)
        {
            return count * 2;
        }

        int main(void)
        {
            int count = 4;
            int total = 0; // count is not read here
            uint8_t buffer[8];
            for (int i = 0; i < count; i++) {
                total += helper(i);
            }
            return total;
        }
        """

    // MARK: - Which lines get values

    @Test func printsTheValuesOfVariablesUsedOnEachLineOfTheStoppedFunction() throws {
        let variables = try [variable("count", "4"), variable("total", "6"), variable("i", "3")]

        let values = InlineValues.annotations(source: source, stoppedAt: 14, variables: variables)

        #expect(values == [
            10: "count = 4",
            11: "total = 6",
            13: "i = 3, count = 4",
            14: "total = 6, i = 3"
        ])
    }

    @Test func leavesOutLinesBelowTheStoppedLineAndOtherFunctions() throws {
        let values = InlineValues.annotations(source: source, stoppedAt: 11, variables: [try variable("count", "4")])

        // Line 5, in `helper`, also names `count`, but that is a different variable.
        #expect(values == [10: "count = 4"])
    }

    @Test func leavesOutVariablesWithoutASimpleValue() throws {
        let values = InlineValues.annotations(
            source: source,
            stoppedAt: 12,
            variables: [try variable("buffer", nil)]
        )

        #expect(values.isEmpty)
    }

    @Test func ignoresNamesInCommentsStringsAndMembers() {
        var inComment = false
        let code = InlineValues.codeText(#"x = s.count + "count"; /* count */ y // count"#, inBlockComment: &inComment)

        #expect(InlineValues.identifiers(in: code) == ["x", "s", "y"])
        #expect(InlineValues.identifiers(in: "p->count + q . total + count") == ["p", "q", "count"])
    }

    @Test func aBlockCommentCanSpanLines() {
        var inComment = false
        _ = InlineValues.codeText("a = 1; /* count", inBlockComment: &inComment)
        #expect(inComment)
        let next = InlineValues.codeText("still count */ b = 2;", inBlockComment: &inComment)

        #expect(!inComment)
        #expect(InlineValues.identifiers(in: next) == ["b"])
    }

    @Test func showsAtMostFourValuesPerLineAndShortensLongOnes() throws {
        let source = "int main(void)\n{\n    a = b + c + d + e;\n}"
        let long = String(repeating: "x", count: 80)
        let variables = try ["a", "b", "c", "d", "e"].map { try variable($0, $0 == "a" ? long : "1") }

        let values = InlineValues.annotations(source: source, stoppedAt: 3, variables: variables)
        let line = try #require(values[3])

        #expect(line.hasPrefix("a = " + String(repeating: "x", count: InlineValues.maximumValueLength - 1) + "…"))
        #expect(line.hasSuffix(", b = 1, c = 1, d = 1"))
    }

    @Test func aStopOutsideTheTextShowsNothing() throws {
        let values = InlineValues.annotations(source: "int x;", stoppedAt: 9, variables: [try variable("x", "1")])

        #expect(values.isEmpty)
    }

    // MARK: - In the editor

    @Test func theEditorDrawsValuesAfterTheEndOfTheirLines() throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "main.c")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let editor = EditorViewController()
        editor.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        try editor.open(file)

        editor.showInlineValues([10: "count = 4"])

        #expect(editor.inlineValues == [10: "count = 4"])
        let textView = try #require(editor.textView as? EditorTextView)
        let start = try #require(editor.lineIndex.offset(ofLine: 10))
        let origin = try #require(textView.inlineAnnotationOrigin(forLineStart: start))
        let layoutManager = try #require(textView.layoutManager)
        let lineEnd = layoutManager.lineFragmentUsedRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil
        ).maxX
        #expect(origin.x > lineEnd, "the value would cover the code")
        #expect(editor.textView.string == source, "the value must not become part of the text")

        editor.clearDebugMarks()
        #expect(editor.inlineValues.isEmpty)
    }

    @Test func theWindowPrintsTheStoppedFramesValuesInTheCode() async throws {
        let folder = try TemporaryFolder()
        let file = folder.url.appending(path: "main.c")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let path = file.path(percentEncoded: false)
        let gdb = FakeDebugger { command in
            if command == "-stack-list-frames" {
                return ["^done,stack=[frame={level=\"0\",addr=\"0x0000020a\",func=\"main\","
                    + "fullname=\"\(path)\",line=\"14\"}]"]
            }
            if command.hasPrefix("-stack-list-variables") {
                return ["^done,variables=[{name=\"count\",type=\"int\",value=\"4\"},"
                    + "{name=\"total\",type=\"int\",value=\"6\"},{name=\"i\",type=\"int\",value=\"3\"}]"]
            }
            if command.hasPrefix("-exec-") && command != "-exec-interrupt" {
                return ["^running", "*running,thread-id=\"all\""]
            }
            return ["^done"]
        }
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        // Not `openFolder`: it ends any session in the background, which would end this one.
        #expect(controller.openFile(file))
        controller.debugger.connect = { _ in gdb }

        try await controller.debugger.start(FakeBlinky.plan)
        gdb.print(FakeBlinky.stop(atLine: 14, of: file, reason: "breakpoint-hit"))
        await waitUntil("values are printed") { !controller.editor.inlineValues.isEmpty }

        #expect(controller.editor.inlineValues[13] == "i = 3, count = 4")
        #expect(controller.editor.inlineValues[14] == "total = 6, i = 3")

        controller.debugContinue(nil)
        await waitUntil("the program runs") { controller.debugger.state == .running }
        #expect(controller.editor.inlineValues.isEmpty, "values from the last stop no longer hold")

        await controller.debugger.stop()
    }
}
