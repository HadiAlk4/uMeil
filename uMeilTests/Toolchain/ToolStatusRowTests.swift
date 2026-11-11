import Foundation
import Testing
@testable import uMeil

struct ToolStatusRowTests {
    private let gcc = InstalledTool(
        tool: .compiler,
        url: URL(filePath: "/opt/homebrew/bin/arm-none-eabi-gcc"),
        version: ToolVersion(14, 2, 0)
    )

    @Test func describesAnInstalledTool() {
        let row = ToolStatusRow(tool: .compiler, status: .installed(gcc))

        #expect(row.name == "Compiler (GCC)")
        #expect(row.state == "Installed")
        #expect(row.version == "14.2.0")
        #expect(row.location == "/opt/homebrew/bin/arm-none-eabi-gcc")
    }

    @Test func describesAMissingTool() {
        let row = ToolStatusRow(tool: .openOCD, status: .missing)

        #expect(row.state == "Not found")
        #expect(row.version == "—")
        #expect(row.location == "—")
    }

    @Test func describesABrokenToolAndWhereItIs() {
        let url = URL(filePath: "/usr/local/bin/arm-none-eabi-gdb")
        let row = ToolStatusRow(tool: .debugger, status: .notWorking(url: url, reason: "Exited with code 1"))

        #expect(row.state == "Not working: Exited with code 1")
        #expect(row.version == "—")
        #expect(row.location == "/usr/local/bin/arm-none-eabi-gdb")
    }

    @Test func shortensTheHomeFolder() {
        let url = URL.homeDirectory.appending(path: "tools/bin/arm-none-eabi-gcc")
        let installed = InstalledTool(tool: .compiler, url: url, version: ToolVersion(14, 2, 0))

        let row = ToolStatusRow(tool: .compiler, status: .installed(installed))

        #expect(row.location == "~/tools/bin/arm-none-eabi-gcc")
    }

    @Test func listsEveryToolInOrderAndTreatsUnknownAsMissing() {
        let rows = ToolStatusRow.rows(for: [.compiler: .installed(gcc)])

        #expect(rows.map(\.name) == ["Compiler (GCC)", "Debugger (GDB)", "OpenOCD"])
        #expect(rows.map(\.state) == ["Installed", "Not found", "Not found"])
    }

    @Test func describesEachStageOfAnInstall() {
        let entry = ToolchainCatalog.armGNUToolchain
        let halfway = ToolStatusRow.installMessage(for: entry, progress: .downloading(fraction: 0.5))

        #expect(halfway.hasPrefix("Downloading Arm GNU Toolchain: 7"))
        #expect(halfway.hasSuffix("MB of 142 MB"))
        #expect(ToolStatusRow.installMessage(for: entry, progress: .verifying) == "Verifying Arm GNU Toolchain…")
        #expect(ToolStatusRow.installMessage(for: entry, progress: .unpacking) == "Unpacking Arm GNU Toolchain…")
    }

    @Test func summarizesHowManyToolsWereFound() {
        #expect(ToolStatusRow.summary(for: [:]) == "0 of 3 tools found")
        #expect(ToolStatusRow.summary(for: [.compiler: .installed(gcc)]) == "1 of 3 tools found")

        let all = Dictionary(uniqueKeysWithValues: Tool.allCases.map { tool in
            (tool, ToolStatus.installed(InstalledTool(tool: tool, url: gcc.url, version: gcc.version)))
        })
        #expect(ToolStatusRow.summary(for: all) == "All 3 tools found")
    }
}
