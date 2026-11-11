import Foundation
import Testing
@testable import uMeil

/// These run real (fake) executables through the real `ProcessRunner`, so
/// they cover process launching and output capture as well as the checker.
struct ToolchainCheckerTests {
    @Test func reportsAnInstalledToolWithItsVersion() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let gcc = try FakeTool.install(
            .compiler,
            in: bin,
            script: FakeTool.versionScript("arm-none-eabi-gcc (GCC) 14.2.0")
        )
        let checker = ToolchainChecker(locator: ToolLocator(searchDirectories: [bin]))

        let status = await checker.status(of: .compiler)

        #expect(status == .installed(InstalledTool(tool: .compiler, url: gcc, version: ToolVersion(14, 2, 0))))
    }

    @Test func readsVersionsPrintedToStandardError() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let openOCD = try FakeTool.install(
            .openOCD,
            in: bin,
            script: FakeTool.versionScript("Open On-Chip Debugger 0.12.0", toStandardError: true)
        )
        let checker = ToolchainChecker(locator: ToolLocator(searchDirectories: [bin]))

        let status = await checker.status(of: .openOCD)

        #expect(status == .installed(InstalledTool(tool: .openOCD, url: openOCD, version: ToolVersion(0, 12, 0))))
    }

    @Test func reportsMissingTools() async throws {
        let temp = try TemporaryDirectory()
        let checker = ToolchainChecker(locator: ToolLocator(searchDirectories: [temp.url]))

        #expect(await checker.status(of: .debugger) == .missing)
    }

    @Test func reportsAToolThatExitsWithAnError() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let gcc = try FakeTool.install(.compiler, in: bin, script: "exit 3")
        let checker = ToolchainChecker(locator: ToolLocator(searchDirectories: [bin]))

        #expect(await checker.status(of: .compiler) == .notWorking(url: gcc, reason: "Exited with code 3"))
    }

    @Test func reportsAToolWhoseVersionCannotBeRead() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let gcc = try FakeTool.install(.compiler, in: bin, script: "echo hello")
        let checker = ToolchainChecker(locator: ToolLocator(searchDirectories: [bin]))

        #expect(await checker.status(of: .compiler) == .notWorking(url: gcc, reason: "Could not read its version"))
    }

    @Test func fallsBackToAWorkingCopyWhenTheFirstIsBroken() async throws {
        let temp = try TemporaryDirectory()
        let broken = try temp.directory("broken")
        let working = try temp.directory("working")
        try FakeTool.install(.compiler, in: broken, script: "exit 1")
        let gcc = try FakeTool.install(
            .compiler,
            in: working,
            script: FakeTool.versionScript("arm-none-eabi-gcc (GCC) 14.2.0")
        )
        let checker = ToolchainChecker(locator: ToolLocator(searchDirectories: [broken, working]))

        let status = await checker.status(of: .compiler)

        #expect(status == .installed(InstalledTool(tool: .compiler, url: gcc, version: ToolVersion(14, 2, 0))))
    }

    @Test func checksEveryTool() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        try FakeTool.install(.compiler, in: bin, script: FakeTool.versionScript("arm-none-eabi-gcc (GCC) 14.2.0"))
        try FakeTool.install(.debugger, in: bin, script: FakeTool.versionScript("GNU gdb (GDB) 15.2"))
        let checker = ToolchainChecker(locator: ToolLocator(searchDirectories: [bin]))

        let statuses = await checker.checkAll()

        #expect(Set(statuses.keys) == Set(Tool.allCases))
        #expect(statuses[.openOCD] == .missing)
        guard case .installed(let debugger) = statuses[.debugger] else {
            Issue.record("Expected the debugger to be installed, got \(String(describing: statuses[.debugger]))")
            return
        }
        #expect(debugger.version == ToolVersion(15, 2, 0))
    }

    @Test func collectsLargeOutputOnBothStreamsWithoutDeadlocking() async throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        // Far more than a pipe buffer (64 KB) on each stream.
        let script = """
        i=0
        while [ $i -lt 4000 ]; do
          echo "standard output line $i padded to make it reasonably long ............"
          echo "standard error line $i padded to make it reasonably long ............." >&2
          i=$((i + 1))
        done
        """
        let tool = try FakeTool.install(.compiler, in: bin, script: script)

        let output = try await ProcessRunner().run(tool, arguments: [])

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.split(separator: "\n").count == 4000)
        #expect(output.standardError.split(separator: "\n").count == 4000)
    }
}
