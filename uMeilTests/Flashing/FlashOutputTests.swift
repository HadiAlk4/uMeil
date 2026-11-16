import Foundation
import Testing
@testable import uMeil

struct FlashOutputTests {
    private let plan = FlashPlan(
        openOCD: URL(filePath: "/tools/bin/openocd"),
        image: URL(filePath: "/tmp/Blinky/build/Blinky.elf"),
        chip: .tm4c1294ncpdt
    )

    // MARK: - Stages

    @Test func readsStagesFromMarkerLines() {
        #expect(FlashOutput.stage(announcedBy: "uMeil: connected") == .connected)
        #expect(FlashOutput.stage(announcedBy: "uMeil: verifying") == .verifying)
        #expect(FlashOutput.stage(announcedBy: "  uMeil: done  ") == .done)
    }

    @Test func ignoresLinesThatAreNotMarkers() {
        #expect(FlashOutput.stage(announcedBy: "Info : clock speed 500 kHz") == nil)
        #expect(FlashOutput.stage(announcedBy: "uMeil: wrong chip") == nil)
        #expect(FlashOutput.stage(announcedBy: "wrote 16384 bytes from file uMeil: done") == nil)
        #expect(FlashOutput.stage(announcedBy: "") == nil)
    }

    @Test func progressOnlyMovesForward() {
        let progress = FlashStage.allCases.map(\.progress)

        #expect(progress == progress.sorted())
        #expect(Set(progress).count == progress.count)
        #expect(progress.first.map { $0 > 0 } == true)
        #expect(progress.last == 1)
    }

    // MARK: - Details

    @Test func readsThePartNumberOpenOCDFound() {
        #expect(FlashOutput.chipName(in: FlashLog.success) == "TM4C1294NCPDT")
        #expect(FlashOutput.chipName(in: FlashLog.wrongChip) == "TM4C123GH6PM")
        #expect(FlashOutput.chipName(in: FlashLog.noBoard) == nil)
    }

    @Test func readsHowMuchWasWritten() {
        #expect(FlashOutput.bytesWritten(in: FlashLog.success) == 16384)
        #expect(FlashOutput.bytesWritten(in: FlashLog.noBoard) == nil)
    }

    // MARK: - Failures

    @Test func aFinishedFlashIsNotAFailure() {
        #expect(FlashOutput.failure(in: FlashLog.success, exitCode: 0, plan: plan) == nil)
    }

    @Test func noBoardIsReportedAsNotConnected() {
        #expect(FlashOutput.failure(in: FlashLog.noBoard, exitCode: 1, plan: plan) == .boardNotConnected)
    }

    @Test func aDifferentChipIsNamed() {
        #expect(FlashOutput.failure(in: FlashLog.wrongChip, exitCode: 1, plan: plan)
            == .wrongChip(found: "TM4C123GH6PM", expected: .tm4c1294ncpdt))
    }

    @Test func aChipOpenOCDCannotIdentifyIsTheWrongChip() {
        let log = "uMeil: connected\nError: Cannot identify target as a Stellaris\n"

        #expect(FlashOutput.failure(in: log, exitCode: 1, plan: plan)
            == .wrongChip(found: nil, expected: .tm4c1294ncpdt))
    }

    @Test func aMismatchAfterWritingIsAVerifyFailure() {
        #expect(FlashOutput.failure(in: FlashLog.verifyFailed, exitCode: 1, plan: plan) == .verifyFailed)
    }

    @Test func aLockedOrWriteProtectedChipIsExplained() {
        #expect(FlashOutput.failure(in: FlashLog.chipLocked, exitCode: 1, plan: plan) == .chipLocked)

        let lockedDebugPort = """
            Info : ICDI Firmware version: 1224
            Error: SRST error
            Error: [tm4c1294ncpdt.cpu] Examination failed
            """
        #expect(FlashOutput.failure(in: lockedDebugPort, exitCode: 1, plan: plan) == .chipLocked)
    }

    @Test func aMissingImageIsReported() {
        let log = "uMeil: connected\nuMeil: writing\nError: couldn't open /tmp/Blinky/build/Blinky.elf\n"

        #expect(FlashOutput.failure(in: log, exitCode: 1, plan: plan) == .imageNotFound(plan.image))
    }

    @Test func otherErrorsPassOnOpenOCDsFirstMessage() {
        #expect(FlashOutput.failure(in: FlashLog.writeFailed, exitCode: 1, plan: plan)
            == .other("error 4 executing stellaris flash write algorithm"))
    }

    @Test func theProbesResetComplaintIsNeverReportedAsTheCause() {
        let log = "Error: SRST error\nuMeil: connected\nError: SRST error\nuMeil: writing\n"

        let timedOut = log + "Error: timed out while waiting for target halted\n"

        #expect(FlashOutput.failure(in: timedOut, exitCode: 1, plan: plan)
            == .other("timed out while waiting for target halted"))
        #expect(FlashOutput.failure(in: log, exitCode: 1, plan: plan)
            == .other("OpenOCD stopped unexpectedly (exit code 1)."))
    }

    @Test func anOpenFailureAfterConnectingIsNotMistakenForAMissingBoard() {
        let log = "uMeil: connected\nuMeil: writing\nError: open failed\n"

        #expect(FlashOutput.failure(in: log, exitCode: 1, plan: plan) == .other("open failed"))
    }

    @Test func aRunThatStopsWithoutFinishingIsAFailureEvenWithNoErrorLine() {
        let unfinished = "uMeil: connected\nuMeil: writing\n"

        #expect(FlashOutput.failure(in: unfinished, exitCode: 0, plan: plan)
            == .other("OpenOCD stopped unexpectedly (exit code 0)."))
        #expect(FlashOutput.failure(in: "", exitCode: 139, plan: plan)
            == .other("OpenOCD stopped unexpectedly (exit code 139)."))
    }

    @Test func aNonZeroExitIsAFailureEvenIfEveryStageRan() {
        #expect(FlashOutput.failure(in: FlashLog.success, exitCode: 1, plan: plan) != nil)
    }

    // MARK: - Messages

    @Test func everyFailureExplainsItselfInPlainWords() {
        let failures: [FlashFailure] = [
            .openOCDNotFound,
            .boardNotConnected,
            .wrongChip(found: "TM4C123GH6PM", expected: .tm4c1294ncpdt),
            .wrongChip(found: nil, expected: .tm4c1294ncpdt),
            .verifyFailed,
            .chipLocked,
            .imageNotFound(plan.image),
            .stopped,
            .other("something odd")
        ]
        let messages = failures.map(\.localizedDescription)

        #expect(Set(messages).count == failures.count)
        #expect(messages[1].contains("DEBUG USB port"))
        #expect(messages[2].contains("TM4C123GH6PM") && messages[2].contains("TM4C1294NCPDT"))
        #expect(messages[5].contains("stellaris recover"))
        #expect(messages[6].contains("Blinky.elf"))
        #expect(messages[8] == "Flashing failed: something odd")
    }
}
