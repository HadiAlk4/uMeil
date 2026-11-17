import Foundation
import Testing
@testable import uMeil

/// Integration tests against the real tools on this machine.
///
/// A test is skipped when its tool is not installed, so the suite still passes
/// on a Mac with no toolchain. CI installs the tools and sets
/// `UMEIL_REQUIRE_TOOLS=1`, which turns a missing tool into a failure.
struct RealToolchainTests {
    private static let toolsAreRequired = ProcessInfo.processInfo.environment["UMEIL_REQUIRE_TOOLS"] == "1"

    private static func shouldTest(_ tool: Tool) -> Bool {
        toolsAreRequired || ToolLocator.standard().locate(tool) != nil
    }

    @Test(.enabled(if: shouldTest(.compiler)))
    func compilerRunsAndReportsItsVersion() async {
        await expectInstalled(.compiler)
    }

    @Test(.enabled(if: shouldTest(.debugger)))
    func debuggerRunsAndReportsItsVersion() async {
        await expectInstalled(.debugger)
    }

    @Test(.enabled(if: shouldTest(.openOCD)))
    func openOCDRunsAndReportsItsVersion() async {
        await expectInstalled(.openOCD)
    }

    @Test(.enabled(if: shouldTest(.clangd)))
    func clangdRunsAndReportsItsVersion() async {
        await expectInstalled(.clangd)
    }

    private func expectInstalled(_ tool: Tool) async {
        let status = await ToolchainChecker(locator: .standard()).status(of: tool)

        guard case .installed(let installed) = status else {
            Issue.record("Expected \(tool.executableName) to be installed and working, got \(status)")
            return
        }
        #expect(installed.url.lastPathComponent == tool.executableName)
        #expect(installed.version > ToolVersion(0, 0, 0))
    }
}
