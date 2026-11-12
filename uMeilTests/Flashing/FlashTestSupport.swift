import Foundation
import os
@testable import uMeil

/// What OpenOCD prints while flashing, for tests to parse.
enum FlashLog {
    /// Captured from xPack OpenOCD 0.12.0-7 running uMeil's flash command
    /// with no board plugged in. It exits with code 1.
    static let noBoard = """
        xPack Open On-Chip Debugger 0.12.0+dev-02228-ge5888bda3-dirty (2025-10-04-22:45)
        Licensed under GNU GPL v2
        For bug reports, read
        \thttp://openocd.org/doc/doxygen/bugs.html
        WARNING: board/ek-tm4c1294xl.cfg is deprecated, please switch to board/ti_ek-tm4c1294xl.cfg
        Info : The selected transport took over low-level target control. \
        The results might differ compared to plain JTAG/SWD
        Info : clock speed 1 kHz
        Error: open failed


        """

    // The logs below were not captured from a board. They are put together
    // from uMeil's marker lines and the message formats in OpenOCD's source,
    // and should be replaced with real captures once a board is available.

    private static let banner = """
        Open On-Chip Debugger 0.12.0
        Licensed under GNU GPL v2
        Info : The selected transport took over low-level target control. \
        The results might differ compared to plain JTAG/SWD
        Info : clock speed 500 kHz
        Info : ICDI Firmware version: 12659
        Info : [tm4c1294ncpdt.cpu] Cortex-M4 r0p1 processor detected
        Info : [tm4c1294ncpdt.cpu] target has 6 breakpoints, 4 watchpoints
        uMeil: connected

        """

    private static func chipInfo(_ part: String) -> String {
        """
        TI/LMI Stellaris information: Chip is class 10 (Snowflake) \(part) rev A2
        did1: 0x101f0000, arch: 0x0005, eproc: ARMv7M, ramsize: 256k, flashsize: 1024k
        master clock: 16000kHz, rcc is 0x7803ad1, rcc2 is 0x7c06810, pagesize: 16384, pages: 64

        """
    }

    /// A flash that worked. Exit code 0.
    static let success = banner + chipInfo("TM4C1294NCPDT") + """
        uMeil: writing
        auto erase enabled
        wrote 16384 bytes from file /tmp/Blinky/build/Blinky.elf in 0.612345s (26.130 KiB/s)
        uMeil: verifying
        verified 1396 bytes from file /tmp/Blinky/build/Blinky.elf in 0.051234s (26.609 KiB/s)
        uMeil: resetting
        uMeil: done
        shutdown command invoked

        """

    /// A LaunchPad with a different Tiva chip. Exit code 1.
    static let wrongChip = banner + """
        TI/LMI Stellaris information: Chip is class 5 (Blizzard/TM4C123x) TM4C123GH6PM rev A1
        did1: 0x10a1606e, arch: 0x0005, eproc: ARMv7M, ramsize: 32k, flashsize: 256k
        uMeil: wrong chip
        shutdown command invoked

        """

    /// The chip's contents did not match the image afterwards. Exit code 1.
    static let verifyFailed = banner + chipInfo("TM4C1294NCPDT") + """
        uMeil: writing
        auto erase enabled
        wrote 16384 bytes from file /tmp/Blinky/build/Blinky.elf in 0.612345s (26.130 KiB/s)
        uMeil: verifying
        Error: checksum mismatch - attempting binary compare
        diff 0 address 0x00000004. Was 0xff instead of 0x09
        diff 1 address 0x00000005. Was 0xff instead of 0x02

        """

    /// The probe answered but the write did not go through. Exit code 1.
    static let writeFailed = banner + chipInfo("TM4C1294NCPDT") + """
        uMeil: writing
        auto erase enabled
        Error: error 4 executing stellaris flash write algorithm
        Error: error writing to flash at address 0x00000000 at offset 0x00000000

        """
}

/// Stands in for OpenOCD: "prints" a saved log and exits with a set code.
struct FakeOpenOCD: LineStreamingProcessRunning {
    var log: String
    var exitCode: Int32 = 0
    /// When true, the run does not finish until the calling task is cancelled.
    var hangsUntilStopped = false
    /// The arguments of each run, for tests to look at.
    let calls = OSAllocatedUnfairLock(initialState: [[String]]())

    func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL?,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessOutput {
        calls.withLock { $0.append(arguments) }
        if hangsUntilStopped {
            try? await Task.sleep(for: .seconds(60))
            // What `Process` reports for a tool ended by `terminate()`.
            return ProcessOutput(exitCode: 15, standardOutput: "", standardError: log)
        }
        for line in log.split(whereSeparator: \.isNewline) {
            onLine(String(line))
        }
        return ProcessOutput(exitCode: exitCode, standardOutput: "", standardError: log)
    }
}

/// Collects the stages a flash reports, from whatever thread reports them.
final class StageRecorder: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: [FlashStage]())

    var stages: [FlashStage] { recorded.withLock { $0 } }

    func record(_ stage: FlashStage) {
        recorded.withLock { $0.append(stage) }
    }
}

/// A board monitor that tests plug and unplug by hand.
@MainActor
final class FakeBoardMonitor: BoardMonitoring {
    private(set) var isBoardConnected = false
    var onChange: ((Bool) -> Void)?
    private(set) var isStarted = false

    func start() {
        isStarted = true
    }

    func setConnected(_ isConnected: Bool) {
        isBoardConnected = isConnected
        onChange?(isConnected)
    }
}
