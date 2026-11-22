import Foundation

extension MainWindowController {
    /// Shows under the editor how much of the chip's flash and RAM the
    /// program takes. A failed build leaves the last good numbers showing.
    func showMemoryUsage(of result: BuildResult, projectFile: URL) {
        guard result.succeeded, let size = result.size,
              let chip = try? ProjectFile.load(from: projectFile).target.chip
        else { return }
        editor.memoryUsageBar.show(MemoryUsage(size: size, chip: chip))
    }
}
