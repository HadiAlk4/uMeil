import AppKit
import Foundation
import Testing
@testable import uMeil

/// The debugging conveniences on a real EK-TM4C1294XL: values printed in the
/// code, the floating debug bar, and the Serial tab.
///
/// Like the other board tests, these only run when asked for:
/// `TEST_RUNNER_UMEIL_HIL=1 xcodebuild test ...` with the board plugged in.
@MainActor
@Suite(.serialized)
struct DebugUXHardwareTests {
    private nonisolated static let hasBoard = ProcessInfo.processInfo.environment["UMEIL_HIL"] == "1"
        && ToolLocator.standard().locate(.compiler) != nil
        && ToolLocator.standard().locate(.debugger) != nil
        && ToolLocator.standard().locate(.openOCD) != nil

    /// Blinky with local variables, so there are values to print.
    private static let program = """
        #include <stdbool.h>
        #include <stdint.h>

        #include "inc/hw_memmap.h"
        #include "driverlib/gpio.h"
        #include "driverlib/sysctl.h"

        static uint32_t twice(uint32_t value)
        {
            uint32_t doubled = value * 2;
            return doubled;
        }

        int main(void)
        {
            uint32_t count = 0;
            uint32_t total = 0;

            SysCtlPeripheralEnable(SYSCTL_PERIPH_GPION);
            while (!SysCtlPeripheralReady(SYSCTL_PERIPH_GPION)) {
            }
            GPIOPinTypeGPIOOutput(GPIO_PORTN_BASE, GPIO_PIN_1);

            for (;;) {
                count++;
                total += twice(count);
                GPIOPinWrite(GPIO_PORTN_BASE, GPIO_PIN_1, (count & 1) ? GPIO_PIN_1 : 0);
                SysCtlDelay(16000000u / 3 / 4);
            }
        }

        """

    private static func line(containing text: String) -> Int {
        let lines = program.split(separator: "\n", omittingEmptySubsequences: false)
        return (lines.firstIndex { $0.contains(text) } ?? -1) + 1
    }

    private func makeWindow(in folder: TemporaryFolder) throws -> MainWindowController {
        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = MainWindowController(defaults: defaults, boardMonitor: FakeBoardMonitor())
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: false)
        try controller.createProject(named: "Blinky", in: folder.url)
        let mainC = try #require(controller.editor.document?.url)
        try Self.program.write(to: mainC, atomically: true, encoding: .utf8)
        #expect(controller.openFile(mainC))
        return controller
    }

    /// Clicks a button on the debug bar, which sends its action through the
    /// responder chain as a real click does.
    private func click(_ action: Selector, on controller: MainWindowController) throws {
        let button = try #require(controller.debugBar.button(for: action))
        #expect(!button.isHidden && button.isEnabled, "\(action) should be clickable")
        button.performClick(nil)
    }

    /// Steps into `twice()` from the bar, where its own values show and
    /// main's go, then picks main in Call Stack to show main's again.
    private func stepIntoTwiceAndBack(
        _ controller: MainWindowController, signature: Int, countLine: Int, doubledLine: Int
    ) async throws {
        try click(#selector(MainWindowController.debugStepInto(_:)), on: controller)
        await waitUntil("the program is in twice") {
            controller.editor.executionLine.map { $0 > signature && $0 <= doubledLine + 1 } ?? false
        }
        await waitUntil("twice's values are printed") { controller.editor.inlineValues[signature] != nil }
        #expect(controller.editor.inlineValues[signature] == "value = 2")
        #expect(controller.editor.inlineValues[countLine] == nil)

        // Picking main in Call Stack shows main's values again.
        await waitUntil("the call stack lists main") {
            controller.debugPanels.callStackLocals.frameNodes.count >= 2
        }
        let mainFrame = try #require(controller.debugPanels.callStackLocals.frameNodes[1].frame)
        controller.debugPanels.callStackLocals.onSelectFrame?(mainFrame)
        await waitUntil("main's values are printed") { controller.editor.inlineValues[countLine] == "count = 2" }

    }

    @Test(.enabled(if: hasBoard), .timeLimit(.minutes(3)))
    func onTheBoardTheBarStepsAndTheCodeShowsTheValues() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeWindow(in: folder)
        controller.window?.makeKeyAndOrderFront(nil)
        defer { controller.window?.orderOut(nil) }
        let countLine = Self.line(containing: "count++")
        let totalLine = Self.line(containing: "total += twice")
        let signature = Self.line(containing: "static uint32_t twice")
        let doubledLine = Self.line(containing: "uint32_t doubled")
        controller.editor.onClickGutterLine?(totalLine)
        await waitUntil("the breakpoint is set") { controller.editor.breakpointLines == [totalLine] }

        #expect(await controller.startDebugging())
        await waitUntil("the program stops at main") { controller.debugger.isStopped }
        #expect(!controller.debugBar.isHidden)

        // Run from the bar to the breakpoint: the first time round the loop.
        try click(#selector(MainWindowController.debugContinue(_:)), on: controller)
        await waitUntil("the breakpoint is hit") { controller.editor.executionLine == totalLine }
        await waitUntil("values are printed") { controller.editor.inlineValues[countLine] != nil }
        #expect(controller.editor.inlineValues[countLine] == "count = 1")
        #expect(controller.editor.inlineValues[totalLine] == "total = 0, count = 1")
        #expect(controller.editor.inlineValues[Self.line(containing: "uint32_t total = 0")] == "total = 0")
        #expect(controller.editor.inlineValues[doubledLine] == nil, "twice() is another function")

        // Step Over from the bar: total takes twice(1).
        try click(#selector(MainWindowController.debugStepOver(_:)), on: controller)
        await waitUntil("the program steps") { controller.editor.executionLine == totalLine + 1 }
        await waitUntil("values follow the step") {
            controller.editor.inlineValues[totalLine] == "total = 2, count = 1"
        }

        // Round the loop again.
        try click(#selector(MainWindowController.debugContinue(_:)), on: controller)
        await waitUntil("the breakpoint is hit again") {
            controller.editor.executionLine == totalLine
                && controller.editor.inlineValues[countLine] == "count = 2"
        }

        try await stepIntoTwiceAndBack(controller, signature: signature, countLine: countLine,
                                       doubledLine: doubledLine)

        // Step Out from the bar, back into main.
        try click(#selector(MainWindowController.debugStepOut(_:)), on: controller)
        await waitUntil("back in main") { controller.editor.executionLine == totalLine }

        // While running, Stop shows in Run's place and the values go.
        try click(#selector(MainWindowController.debugContinue(_:)), on: controller)
        controller.debugger.clearBreakpoints()
        await waitUntil("the program runs") { controller.debugger.state == .running }
        #expect(controller.editor.inlineValues.isEmpty)
        try click(#selector(MainWindowController.debugPause(_:)), on: controller)
        await waitUntil("the program stops") { controller.debugger.isStopped }

        // End the session from the bar.
        try click(#selector(MainWindowController.toggleDebugging(_:)), on: controller)
        await waitUntil("the session is over") { !controller.debugger.isActive }
        #expect(controller.debugBar.isHidden)
        #expect(controller.editor.inlineValues.isEmpty)
    }

    @Test(.enabled(if: hasBoard), .timeLimit(.minutes(1)))
    func onTheBoardTheSerialTabOpensTheLaunchPadsPort() async throws {
        let folder = try TemporaryFolder()
        let controller = try makeWindow(in: folder)

        controller.toggleSerialMonitor(nil)
        let serial = controller.bottomPanel.serial
        #expect(controller.isSerialMonitorVisible)
        serial.refreshPorts()
        let port = try #require(serial.selectedPort, "no serial port found")
        #expect(port.board != nil, "the LaunchPad's port is chosen first, not \(port.path)")

        serial.connect()
        #expect(serial.isConnected, "\(serial.statusLabel.stringValue)")
        #expect(serial.inputField.isEnabled)
        serial.disconnect()
        #expect(!serial.isConnected)
    }
}
