import Darwin
import Foundation
import Testing
@testable import uMeil

/// Reads what a board sends over its USB serial port.
private final class SerialPort {
    private let descriptor: Int32

    /// The LaunchPad's serial ports. The debug probe shows up as one
    /// `/dev/cu.usbmodem…` device, wired to the chip's UART0.
    static func launchPadPorts() -> [String] {
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return devices.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
    }

    /// Opens `path` for raw reading at `baudRate`, 8 data bits, no parity.
    init(path: String, baudRate: speed_t) throws {
        // Non-blocking, so opening does not wait for a modem that is not there.
        descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var settings = termios()
        tcgetattr(descriptor, &settings)
        cfmakeraw(&settings)
        cfsetspeed(&settings, baudRate)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(descriptor, TCSANOW, &settings)
        tcflush(descriptor, TCIFLUSH)
    }

    deinit {
        close(descriptor)
    }

    /// Whatever has arrived since the last call. Empty if nothing has.
    func readAvailable() -> String {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return "" }
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: buffer[..<count], as: UTF8.self)
    }
}

enum HardwareTestEnvironment {
    /// Whether tests that write to a real board should run.
    static let isEnabled = ProcessInfo.processInfo.environment["UMEIL_HIL"] == "1"
}

/// Tests that use a real EK-TM4C1294XL plugged into this Mac.
///
/// They write to the board, so they only run when asked for: set
/// `UMEIL_HIL=1` (with `xcodebuild`, `TEST_RUNNER_UMEIL_HIL=1`). If the Mac
/// has more than one USB serial device, name the board's with
/// `UMEIL_HIL_SERIAL_PORT=/dev/cu.usbmodem…`.
@Suite(.enabled(if: HardwareTestEnvironment.isEnabled), .serialized)
struct HardwareInTheLoopTests {
    /// Firmware that sends `message` over UART0 ten times a second, at
    /// 115200 baud. UART0 is the one wired to the debug probe's serial port.
    private func uartFirmware(sending message: String) -> String {
        """
        #include <stdbool.h>
        #include <stdint.h>

        #include "inc/hw_memmap.h"
        #include "driverlib/gpio.h"
        #include "driverlib/pin_map.h"
        #include "driverlib/sysctl.h"
        #include "driverlib/uart.h"

        // The internal oscillator, which also clocks the UART below.
        #define CLOCK_HZ 16000000u

        static const char message[] = "\(message)\\r\\n";

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
                for (const char *next = message; *next != 0; next++) {
                    UARTCharPut(UART0_BASE, *next);
                }
                SysCtlDelay(CLOCK_HZ / 3 / 10);
            }
        }

        """
    }

    @Test func theBoardIsSeenOnUSB() async {
        #expect(USBBoardMonitor.isPresent(Board.ekTM4C1294XL.debugProbe))

        let isConnected = await MainActor.run {
            let monitor = USBBoardMonitor()
            monitor.start()
            return monitor.isBoardConnected
        }
        #expect(isConnected)
    }

    /// The README's M5 test: flash firmware that prints a known message over
    /// UART, and read the message back to prove the new firmware is running.
    @Test func flashedFirmwareRunsAndTalksOverUART() async throws {
        let folder = try TemporaryFolder()
        let template = try #require(try ProjectTemplate.all().first { $0.identifier == "Blinky" })
        let projectFile = try template.createProject(named: "HILTest", in: folder.url)

        // A message no earlier firmware on the board could have sent.
        let message = "uMeil HIL \(UUID().uuidString)"
        let main = projectFile.deletingLastPathComponent().appending(path: "src/main.c")
        try uartFirmware(sending: message).write(to: main, atomically: true, encoding: .utf8)

        let build = try await BuildEngine().build(try BuildEngine.plan(forProjectFile: projectFile))
        try #require(build.succeeded, "Build failed:\n\(build.log)")
        let image = try #require(build.elf)

        let plan = try Flasher.plan(forProjectFile: projectFile, image: image)
        let result = await Flasher().flash(plan) { _ in }
        try #require(result.succeeded, "Flash failed:\n\(result.log)")
        #expect(result.bytesWritten ?? 0 > 0)

        let path = try #require(
            ProcessInfo.processInfo.environment["UMEIL_HIL_SERIAL_PORT"] ?? SerialPort.launchPadPorts().first,
            "No /dev/cu.usbmodem… serial port was found for the board."
        )
        let port = try SerialPort(path: path, baudRate: 115200)
        var received = ""
        let deadline = Date().addingTimeInterval(10)
        while !received.contains(message), Date() < deadline {
            received += port.readAvailable()
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(received.contains(message), "The board sent:\n\(received.suffix(400))")
    }
}
