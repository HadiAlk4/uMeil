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

    // The pieces below were captured on 16 November 2026 from xPack OpenOCD
    // 0.12.0-7 running uMeil's flash command against an EK-TM4C1294XL
    // (TM4C1294NCPDT rev A2, ICDI firmware 1224). Only the image path was
    // shortened. Each log says which of its lines are real.

    /// Everything up to the chip being stopped. The ICDI probe prints
    /// "Error: SRST error" at every reset, including in flashes that work.
    private static let banner = """
        xPack Open On-Chip Debugger 0.12.0+dev-02228-ge5888bda3-dirty (2025-10-04-22:45)
        Licensed under GNU GPL v2
        For bug reports, read
        \thttp://openocd.org/doc/doxygen/bugs.html
        WARNING: board/ek-tm4c1294xl.cfg is deprecated, please switch to board/ti_ek-tm4c1294xl.cfg
        Info : The selected transport took over low-level target control. \
        The results might differ compared to plain JTAG/SWD
        Info : clock speed 1 kHz
        Info : ICDI Firmware version: 1224
        Error: SRST error
        Info : [tm4c1294ncpdt.cpu] Cortex-M4 r0p1 processor detected
        Info : [tm4c1294ncpdt.cpu] target has 6 breakpoints, 4 watchpoints
        Info : [tm4c1294ncpdt.cpu] Examination succeed
        Info : [tm4c1294ncpdt.cpu] starting gdb server on 3333
        Info : Listening on port 3333 for gdb connections
        uMeil: connected
        Error: SRST error
        [tm4c1294ncpdt.cpu] halted due to debug-request, current mode: Thread\u{20}
        xPSR: 0x01000000 pc: 0x000002a0 msp: 0x20000278

        """

    /// What `flash info 0` answers: one line per 16 kB page, then the chip.
    private static let chipInfo: String = {
        let pages = (0..<64).map { page in
            let number = String(page).leftPadded(to: 2)
            let address = String(page * 0x4000, radix: 16).leftPadded(to: 8, with: "0")
            return "\t# \(number): 0x\(address) (0x4000 16kB) not protected\n"
        }
        return "#0 : stellaris at 0x00000000, size 0x00100000, buswidth 0, chipwidth 0\n"
            + pages.joined()
            + """

            TI/LMI Stellaris information: Chip is class 10 (Snowflake) TM4C1294NCPDT rev A2
            did1: 0x101fc06e, arch: 0x101fc06e, eproc: ARMv7M, ramsize: 256k, flashsize: 1024k
            master clock: 200000kHz, rcc is 0x0, rcc2 is 0x0, pagesize: 16384, pages: 64

            """
    }()

    /// A flash of Blinky that worked. Exit code 0. A real capture.
    static let success = banner + chipInfo + """
        uMeil: writing
        auto erase enabled
        wrote 16384 bytes from file /tmp/Blinky/build/Blinky.elf in 1.313867s (12.178 KiB/s)
        uMeil: verifying
        verified 1144 bytes in 0.263020s (4.248 KiB/s)
        uMeil: resetting
        Error: SRST error
        uMeil: done
        shutdown command invoked

        """

    /// A LaunchPad with a different Tiva chip. Exit code 1.
    ///
    /// The shape is a real capture of the chip check refusing a board. No
    /// TM4C123 board was to hand, so its two chip lines are written from
    /// OpenOCD's message format.
    static let wrongChip = banner + """
        #0 : stellaris at 0x00000000, size 0x00040000, buswidth 0, chipwidth 0

        TI/LMI Stellaris information: Chip is class 5 (Blizzard/TM4C123x) TM4C123GH6PM rev A1
        did1: 0x10a1606e, arch: 0x10a1606e, eproc: ARMv7M, ramsize: 32k, flashsize: 256k
        uMeil: wrong chip
        shutdown command invoked

        """

    /// The chip's contents did not match the image afterwards. Exit code 1.
    ///
    /// The lines from "uMeil: verifying" on are a real capture of
    /// `verify_image` finding a different program on the chip.
    static let verifyFailed = banner + chipInfo + """
        uMeil: writing
        auto erase enabled
        wrote 16384 bytes from file /tmp/Blinky/build/Blinky.elf in 1.313867s (12.178 KiB/s)
        uMeil: verifying
        Error: checksum mismatch - attempting binary compare
        diff 0 address 0x00000250. Was 0xaa instead of 0x2a
        diff 1 address 0x00000251. Was 0xb0 instead of 0x2c
        diff 2 address 0x00000252. Was 0x28 instead of 0x0a
        No more differences found.

        """

    /// The probe answered but the write did not go through. Exit code 1.
    ///
    /// The two errors after "auto erase enabled" were not captured: a failed
    /// write could not be provoked on a healthy board. They are written from
    /// the message formats in OpenOCD's source.
    static let writeFailed = banner + chipInfo + """
        uMeil: writing
        auto erase enabled
        Error: error 4 executing stellaris flash write algorithm
        Error: error writing to flash at address 0x00000000 at offset 0x00000000

        """
}

private extension String {
    func leftPadded(to length: Int, with pad: Character = " ") -> String {
        String(repeating: pad, count: max(length - count, 0)) + self
    }
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
