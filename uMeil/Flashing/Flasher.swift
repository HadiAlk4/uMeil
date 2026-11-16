import Foundation

/// What a flash did.
struct FlashResult: Equatable, Sendable {
    /// `nil` when the firmware was written, verified, and started.
    var failure: FlashFailure?
    /// How many bytes OpenOCD wrote, when it got that far.
    var bytesWritten: Int?
    /// The command that ran, with its output, for showing to the user.
    var log: String

    var succeeded: Bool { failure == nil }
}

/// Writes firmware to a board by running OpenOCD.
struct Flasher: Sendable {
    var runner: any LineStreamingProcessRunning = StreamingProcessRunner()

    /// Works out how to flash `image` for the project at `projectFile`.
    static func plan(
        forProjectFile projectFile: URL,
        image: URL,
        locator: ToolLocator = .standard()
    ) throws -> FlashPlan {
        let project = try ProjectFile.load(from: projectFile)
        guard let openOCD = locator.locate(.openOCD) else {
            throw FlashFailure.openOCDNotFound
        }
        return FlashPlan(openOCD: openOCD, image: image, chip: project.target.chip)
    }

    /// Works out how to flash `image`, a firmware file built somewhere else
    /// (for example Keil's `.axf`), with no uMeil project to say which chip
    /// it is for.
    static func plan(
        forImage image: URL,
        chip: Chip = .tm4c1294ncpdt,
        locator: ToolLocator = .standard()
    ) throws -> FlashPlan {
        guard FileManager.default.fileExists(atPath: image.path(percentEncoded: false)) else {
            throw FlashFailure.imageNotFound(image)
        }
        guard FirmwareImage.isArmProgram(image) else {
            throw FlashFailure.notAnImage(image)
        }
        guard let openOCD = locator.locate(.openOCD) else {
            throw FlashFailure.openOCDNotFound
        }
        return FlashPlan(openOCD: openOCD, image: image, chip: chip)
    }

    /// Runs the flash. `onStage` is called as each stage begins, from a
    /// background thread. Cancelling the calling task stops OpenOCD and
    /// gives a result that failed with `.stopped`.
    func flash(_ plan: FlashPlan, onStage: @escaping @Sendable (FlashStage) -> Void) async -> FlashResult {
        let command = "$ " + ([plan.openOCD.lastPathComponent] + plan.arguments).joined(separator: " ") + "\n"

        // Checked here, not left to OpenOCD, so the board is not reset for nothing.
        guard FileManager.default.fileExists(atPath: plan.image.path(percentEncoded: false)) else {
            return FlashResult(failure: .imageNotFound(plan.image), log: command)
        }

        // Stopped during the build that came first: do not start at all.
        guard !Task.isCancelled else {
            return FlashResult(failure: .stopped, log: command)
        }

        onStage(.connecting)
        let output: ProcessOutput
        do {
            output = try await runner.run(plan.openOCD, arguments: plan.arguments, currentDirectory: nil) { line in
                if let stage = FlashOutput.stage(announcedBy: line) {
                    onStage(stage)
                }
            }
        } catch {
            return FlashResult(failure: .other(error.localizedDescription), log: command)
        }

        let text = output.combinedOutput
        let bytesWritten = FlashOutput.bytesWritten(in: text)
        var failure = FlashOutput.failure(in: text, exitCode: output.exitCode, plan: plan)
        if failure != nil, Task.isCancelled {
            failure = .stopped
        }
        return FlashResult(failure: failure, bytesWritten: bytesWritten, log: command + text)
    }
}

/// Checks on a firmware file before it is sent to a board.
enum FirmwareImage {
    /// The file name endings offered when choosing an image to flash.
    /// Keil names its output `.axf`; GNU tools use `.elf`. Both are ELF files.
    static let fileExtensions = ["axf", "elf"]

    /// Whether `file` is an ELF program for a 32-bit Arm chip.
    ///
    /// OpenOCD writes anything it does not recognise as raw bytes at address
    /// zero, so a wrong file would overwrite the board's program with junk.
    static func isArmProgram(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        let bytes = [UInt8](header)

        let isELF = bytes[0...3].elementsEqual([0x7F, 0x45, 0x4C, 0x46]) // "\u{7F}ELF"
        let is32Bit = bytes[4] == 1
        let isLittleEndian = bytes[5] == 1
        // Bytes 16-17: the kind of file. 2 is a program, as opposed to an
        // object file or a library.
        let isProgram = bytes[16] == 2 && bytes[17] == 0
        // Bytes 18-19: the processor. 40 is Arm.
        let isArm = bytes[18] == 40 && bytes[19] == 0
        return isELF && is32Bit && isLittleEndian && isProgram && isArm
    }
}
