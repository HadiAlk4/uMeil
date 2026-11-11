import Foundation

/// A tool that was found on disk and confirmed to run.
struct InstalledTool: Equatable, Sendable {
    let tool: Tool
    let url: URL
    let version: ToolVersion
}

/// The result of looking for one tool.
enum ToolStatus: Equatable, Sendable {
    /// Found, and it reported a version.
    case installed(InstalledTool)
    /// An executable exists but it failed to run or printed nothing usable.
    case notWorking(url: URL, reason: String)
    /// No executable in any search directory.
    case missing
}

/// Finds each tool and confirms it works by asking for its version.
struct ToolchainChecker: Sendable {
    var locator: ToolLocator
    var runner: any ProcessRunning = ProcessRunner()

    /// Checks one tool. If several copies exist, the first one that works wins.
    func status(of tool: Tool) async -> ToolStatus {
        var firstFailure: ToolStatus?

        for url in locator.candidates(for: tool) {
            switch await check(tool, at: url) {
            case .installed(let installed):
                return .installed(installed)
            case let failure:
                firstFailure = firstFailure ?? failure
            }
        }
        return firstFailure ?? .missing
    }

    /// Checks every tool at the same time.
    func checkAll() async -> [Tool: ToolStatus] {
        await withTaskGroup(of: (Tool, ToolStatus).self) { group in
            for tool in Tool.allCases {
                group.addTask { (tool, await status(of: tool)) }
            }
            var statuses: [Tool: ToolStatus] = [:]
            for await (tool, status) in group {
                statuses[tool] = status
            }
            return statuses
        }
    }

    private func check(_ tool: Tool, at url: URL) async -> ToolStatus {
        let output: ProcessOutput
        do {
            output = try await runner.run(url, arguments: tool.versionArguments)
        } catch {
            return .notWorking(url: url, reason: error.localizedDescription)
        }

        guard output.exitCode == 0 else {
            return .notWorking(url: url, reason: "Exited with code \(output.exitCode)")
        }
        guard let version = ToolVersion.parse(versionOutput: output.combinedOutput, for: tool) else {
            return .notWorking(url: url, reason: "Could not read its version")
        }
        return .installed(InstalledTool(tool: tool, url: url, version: version))
    }
}
