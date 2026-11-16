import Foundation
import Testing
@testable import uMeil

/// Hardware-in-the-loop test for the serial monitor on a real EK-TM4C1294XL.
///
/// Writes echo firmware to the board, so it only runs when `UMEIL_HIL=1` is
/// set (`TEST_RUNNER_UMEIL_HIL=1` with `xcodebuild`).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UMEIL_HIL"] == "1"), .serialized)
@MainActor
struct SerialHardwareTests {
    /// Firmware that echoes every byte received on UART0 back to the host at 115200 baud.
    private static let echoFirmware = """
        #include <stdbool.h>
        #include <stdint.h>

        #include "inc/hw_memmap.h"
        #include "driverlib/gpio.h"
        #include "driverlib/pin_map.h"
        #include "driverlib/sysctl.h"
        #include "driverlib/uart.h"

        #define CLOCK_HZ 16000000u

        int main(void)
        {
            SysCtlPeripheralEnable(SYSCTL_PERIPH_GPIOA);
            SysCtlPeripheralEnable(SYSCTL_PERIPH_UART0);
            while (!SysCtlPeripheralReady(SYSCTL_PERIPH_GPIOA) || !SysCtlPeripheralReady(SYSCTL_PERIPH_UART0)) {
            }

            GPIOPinConfigure(GPIO_PA0_U0RX);
            GPIOPinConfigure(GPIO_PA1_U0TX);
            GPIOPinTypeUART(GPIO_PORTA_BASE, GPIO_PIN_0 | GPIO_PIN_1);
            UARTClockSourceSet(UART0_BASE, UART_CLOCK_PIOSC);
            UARTConfigSetExpClk(UART0_BASE, CLOCK_HZ, 115200,
                                UART_CONFIG_WLEN_8 | UART_CONFIG_STOP_ONE | UART_CONFIG_PAR_NONE);

            for (;;) {
                int32_t byte = UARTCharGet(UART0_BASE);
                if (byte == '\\r') {
                    UARTCharPut(UART0_BASE, '\\r');
                    UARTCharPut(UART0_BASE, '\\n');
                } else {
                    UARTCharPut(UART0_BASE, (unsigned char)byte);
                }
            }
        }

        """

    @Test func echoFirmwareReturnsWhatTheSerialMonitorSends() async throws {
        let folder = try TemporaryDirectory()
        let template = try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
        let projectFile = try template.createProject(named: "SerialEcho", in: folder.url)
        let main = projectFile.deletingLastPathComponent().appending(path: "src/main.c")
        try Self.echoFirmware.write(to: main, atomically: true, encoding: .utf8)

        let build = try await BuildEngine().build(try BuildEngine.plan(forProjectFile: projectFile))
        try #require(build.succeeded, "Build failed:\n\(build.log)")
        let image = try #require(build.elf)

        let plan = try Flasher.plan(forProjectFile: projectFile, image: image)
        let flash = await Flasher().flash(plan) { _ in }
        try #require(flash.succeeded, "Flash failed:\n\(flash.log)")

        let suite = "uMeilTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let monitor = SerialMonitorViewController(defaults: defaults)
        monitor.loadViewIfNeeded()
        #expect(monitor.selectedPort?.board == .ekTM4C1294XL)

        monitor.connect()
        defer { monitor.disconnect() }
        try #require(monitor.isConnected, "Could not connect: \(monitor.statusLabel.stringValue)")

        let message = "uMeil echo \(UUID().uuidString)"
        let deadline = Date().addingTimeInterval(5)
        while !monitor.outputText.contains(message + "\n"), Date() < deadline {
            monitor.send(message)
            try await Task.sleep(for: .milliseconds(200))
        }

        #expect(monitor.outputText.contains(message + "\n"))
    }
}
