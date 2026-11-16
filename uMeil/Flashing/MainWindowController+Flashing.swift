import AppKit

/// Turns flash results into the one-line status under the issues list.
enum FlashSummary {
    /// For example "Flashed: 1.4 KB written to the board" or "Flash failed".
    static func statusText(for result: FlashResult) -> String {
        guard result.succeeded else {
            return result.failure == .stopped ? "Flash stopped" : "Flash failed"
        }
        guard let bytes = result.bytesWritten else {
            return "Flashed: the board is running the new firmware"
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        return "Flashed: \(size) written to the board"
    }
}

extension MainWindowController {
    /// Product > Build and Flash, and the toolbar's Flash button.
    @objc func flashProject(_ sender: Any?) {
        guard !isFlashing else { return }
        flashTask = Task { await buildAndFlash() }
    }

    /// Product > Stop
    @objc func stopFlashing(_ sender: Any?) {
        flashTask?.cancel()
    }

    /// Builds the project in the open folder and, if that worked, writes the
    /// firmware to the board. Progress and the outcome go to the issues panel.
    ///
    /// Returns `nil` when the build failed, so nothing was flashed.
    @discardableResult
    func buildAndFlash() async -> FlashResult? {
        guard !isFlashing, let folder else { return nil }
        isFlashing = true
        defer {
            isFlashing = false
            flashTask = nil
        }

        guard let build = await build(), build.succeeded, let image = build.elf,
              let projectFile = BuildSummary.projectFile(in: folder)
        else { return nil }

        let result: FlashResult
        do {
            let plan = try Flasher.plan(forProjectFile: projectFile, image: image, locator: makeToolLocator())
            result = await flasher.flash(plan) { [weak self] stage in
                // Stages are announced from a background thread.
                Task { @MainActor in self?.flashReached(stage) }
            }
        } catch let failure as FlashFailure {
            result = FlashResult(failure: failure, log: "")
        } catch {
            result = FlashResult(failure: .other(error.localizedDescription), log: "")
        }
        // Set before showing the result, so a stage that arrives late cannot replace it.
        isFlashing = false
        issues.show(result)
        return result
    }

    private func flashReached(_ stage: FlashStage) {
        guard isFlashing else { return }
        issues.showFlashing(stage)
    }

    // MARK: - Board status

    /// Shows in the toolbar whether a board is plugged in, and keeps it up to date.
    func startWatchingForBoard() {
        boardMonitor.onChange = { [weak self] isConnected in
            self?.toolbar.showBoard(isConnected: isConnected)
        }
        boardMonitor.start()
        toolbar.showBoard(isConnected: boardMonitor.isBoardConnected)
    }
}
