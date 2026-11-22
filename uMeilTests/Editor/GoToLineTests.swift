import AppKit
import Foundation
import Testing
@testable import uMeil

@MainActor
struct GoToLineTests {
    private func makeWindowController(lines: Int = 80) throws -> (MainWindowController, TemporaryDirectory) {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        let content = (1...lines).map { String(format: "int line_%03d = %d;", $0, $0) }.joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: file)

        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.window?.setFrame(NSRect(x: 100, y: 100, width: 900, height: 600), display: false)
        controller.openFolder(temp.url)
        controller.openFile(file)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return (controller, temp)
    }

    // MARK: - Parsing

    @Test func parsesPlainLineNumbersAndWhitespace() {
        #expect(GoToLineController.parse("42", maxLine: 100) == .init(line: 42, column: nil))
        #expect(GoToLineController.parse(" 42 ", maxLine: 100) == .init(line: 42, column: nil))
        #expect(GoToLineController.parse("\t1\n", maxLine: 100) == .init(line: 1, column: nil))
    }

    @Test func parsesLineAndColumn() {
        #expect(GoToLineController.parse("42:7", maxLine: 100) == .init(line: 42, column: 7))
        #expect(GoToLineController.parse("42:10", maxLine: 100) == .init(line: 42, column: 10))
        #expect(GoToLineController.parse(" 42 : 7 ", maxLine: 100) == .init(line: 42, column: 7))
    }

    @Test func toleratesLeadingColonAndLineKeyword() {
        #expect(GoToLineController.parse(":42", maxLine: 100) == .init(line: 42, column: nil))
        #expect(GoToLineController.parse(":42:10", maxLine: 100) == .init(line: 42, column: 10))
        #expect(GoToLineController.parse(" : 42 ", maxLine: 100) == .init(line: 42, column: nil))
        #expect(GoToLineController.parse("line 42", maxLine: 100) == .init(line: 42, column: nil))
        #expect(GoToLineController.parse("Line 42", maxLine: 100) == .init(line: 42, column: nil))
        #expect(GoToLineController.parse("LINE   42:7", maxLine: 100) == .init(line: 42, column: 7))
        #expect(GoToLineController.parse("line: 42", maxLine: 100) == .init(line: 42, column: nil))
        #expect(GoToLineController.parse("line:42:9", maxLine: 100) == .init(line: 42, column: 9))
    }

    @Test func clampsOutOfRangeLinesAndColumns() {
        #expect(GoToLineController.parse("0", maxLine: 100) == .init(line: 1, column: nil))
        #expect(GoToLineController.parse("-5", maxLine: 100) == .init(line: 1, column: nil))
        #expect(GoToLineController.parse("250", maxLine: 100) == .init(line: 100, column: nil))
        #expect(GoToLineController.parse("999999999999999999999999", maxLine: 50) == .init(line: 50, column: nil))
        #expect(GoToLineController.parse("-999999999999999999999999", maxLine: 50) == .init(line: 1, column: nil))
        #expect(GoToLineController.parse("42:0", maxLine: 100) == .init(line: 42, column: 1))
        #expect(GoToLineController.parse("42:-3", maxLine: 100) == .init(line: 42, column: 1))
        #expect(GoToLineController.parse("5", maxLine: 1) == .init(line: 1, column: nil))
        #expect(GoToLineController.parse("5", maxLine: 0) == .init(line: 1, column: nil))
    }

    @Test func rejectsInvalidInput() {
        let invalid = [
            "", "   ", "abc", "line", "line ", "line:", "lines 42", "line abc",
            "42abc", "42:abc", "42:", ":", "::42", "42:10:5", "12.5", "42 10", "-", "--5"
        ]
        for input in invalid {
            #expect(GoToLineController.parse(input, maxLine: 100) == nil, "Expected nil for \(input.debugDescription)")
        }
    }

    // MARK: - Menu and validation

    @Test func theMenuOffersGoToLineOnCommandL() throws {
        let menu = MainMenu.make(appName: "uMeil")
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let item = try #require(edit.items.first { $0.title == "Go to Line…" })

        #expect(item.keyEquivalent == "l")
        #expect(item.keyEquivalentModifierMask == [.command])
        #expect(item.action == #selector(MainWindowController.showGoToLine(_:)))
    }

    @Test func menuValidationRequiresAnOpenDocument() throws {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let temp = try TemporaryDirectory()
        let file = temp.url.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: file)

        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        let item = NSMenuItem(
            title: "Go to Line…",
            action: #selector(MainWindowController.showGoToLine(_:)),
            keyEquivalent: "l"
        )

        #expect(!controller.validateMenuItem(item))

        controller.openFolder(temp.url)
        #expect(!controller.validateMenuItem(item))

        controller.showGoToLine(nil)
        #expect(!controller.goToLine.panel.isVisible)

        controller.openFile(file)
        #expect(controller.validateMenuItem(item))

        controller.editor.close(hasFolder: true)
        #expect(!controller.validateMenuItem(item))
    }

    // MARK: - Panel and editor integration

    @Test func submittingLineNumberJumpsEditorScrollsAndClosesPanel() throws {
        let (controller, temp) = try makeWindowController(lines: 80)
        _ = temp
        defer { controller.goToLine.close(restoreFocus: false) }

        controller.showGoToLine(nil)
        #expect(controller.goToLine.panel.isVisible)
        #expect(controller.goToLine.inputField.placeholderString == "Go to line (1–81)")

        controller.goToLine.inputField.stringValue = "42"
        let handled = controller.goToLine.control(
            controller.goToLine.inputField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(handled)
        #expect(!controller.goToLine.panel.isVisible)
        let expectedOffset = try #require(controller.editor.lineIndex.offset(ofLine: 42))
        #expect(controller.editor.textView.selectedRange() == NSRange(location: expectedOffset, length: 0))
        #expect(controller.window?.firstResponder === controller.editor.textView)

        let layoutManager = try #require(controller.editor.textView.layoutManager)
        let container = try #require(controller.editor.textView.textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: expectedOffset, length: 1),
            actualCharacterRange: nil
        )
        let targetRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        #expect(controller.editor.textView.visibleRect.intersects(targetRect))
    }

    @Test func submittingLineAndColumnJumpsToExactOffset() throws {
        let (controller, temp) = try makeWindowController(lines: 60)
        _ = temp
        defer { controller.goToLine.close(restoreFocus: false) }

        controller.showGoToLine(nil)
        controller.goToLine.inputField.stringValue = "42:7"
        controller.goToLine.submit()

        #expect(!controller.goToLine.panel.isVisible)
        let expectedOffset = try #require(controller.editor.lineIndex.offset(line: 42, column: 7))
        #expect(controller.editor.textView.selectedRange() == NSRange(location: expectedOffset, length: 0))
    }

    @Test func submittingOutOfRangeLineClampsCleanly() throws {
        let (controller, temp) = try makeWindowController(lines: 10)
        _ = temp
        defer { controller.goToLine.close(restoreFocus: false) }

        controller.showGoToLine(nil)
        controller.goToLine.inputField.stringValue = "999"
        controller.goToLine.submit()

        let lastLine = controller.editor.lineIndex.lineCount
        let expectedOffset = try #require(controller.editor.lineIndex.offset(ofLine: lastLine))
        #expect(controller.editor.textView.selectedRange() == NSRange(location: expectedOffset, length: 0))
    }

    @Test func invalidInputDoesNotJumpOrClosePanel() throws {
        let (controller, temp) = try makeWindowController(lines: 20)
        _ = temp
        defer { controller.goToLine.close(restoreFocus: false) }

        controller.editor.goTo(line: 5, column: 3)
        let originalSelection = controller.editor.textView.selectedRange()

        controller.showGoToLine(nil)
        controller.goToLine.inputField.stringValue = "not-a-line"
        controller.goToLine.submit()

        #expect(controller.goToLine.panel.isVisible)
        #expect(controller.editor.textView.selectedRange() == originalSelection)
        #expect(controller.goToLine.hintLabel.textColor == .systemRed)
    }

    @Test func escapeDismissesWithoutMovingCursorAndReturnsFocusToEditor() throws {
        let (controller, temp) = try makeWindowController(lines: 50)
        _ = temp
        defer { controller.goToLine.close(restoreFocus: false) }

        controller.editor.goTo(line: 10, column: 4)
        let originalSelection = controller.editor.textView.selectedRange()

        controller.showGoToLine(nil)
        controller.goToLine.inputField.stringValue = "42"
        let handled = controller.goToLine.control(
            controller.goToLine.inputField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        )

        #expect(handled)
        #expect(!controller.goToLine.panel.isVisible)
        #expect(controller.editor.textView.selectedRange() == originalSelection)
        #expect(controller.window?.firstResponder === controller.editor.textView)
    }

    @Test func resigningKeyClosesPanelWithoutMovingCursorAndReturnsFocusToEditor() throws {
        let (controller, temp) = try makeWindowController(lines: 50)
        _ = temp
        defer { controller.goToLine.close(restoreFocus: false) }

        controller.editor.goTo(line: 8, column: 2)
        let originalSelection = controller.editor.textView.selectedRange()

        controller.showGoToLine(nil)
        controller.goToLine.inputField.stringValue = "35"
        controller.goToLine.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: controller.goToLine.panel)
        )

        #expect(!controller.goToLine.panel.isVisible)
        #expect(controller.editor.textView.selectedRange() == originalSelection)
        #expect(controller.window?.firstResponder === controller.editor.textView)
    }

    @Test func panelPositionsNearTopCenterAndMatchesWindowAppearance() throws {
        let (controller, temp) = try makeWindowController(lines: 20)
        _ = temp
        defer { controller.goToLine.close(restoreFocus: false) }

        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        controller.showGoToLine(nil)

        let panelFrame = controller.goToLine.panel.frame
        #expect(abs(panelFrame.midX - window.frame.midX) < 1)
        #expect(panelFrame.maxY < window.frame.maxY)
        #expect(panelFrame.maxY > window.frame.midY)
        #expect(controller.goToLine.panel.appearance?.name == .darkAqua)
    }
}
