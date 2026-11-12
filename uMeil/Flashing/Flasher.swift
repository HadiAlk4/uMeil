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
