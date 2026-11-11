import Foundation
import Testing
@testable import uMeil

struct ToolchainCatalogTests {
    private func installed(_ tool: Tool) -> ToolStatus {
        let url = URL(filePath: "/bin/\(tool.executableName)")
        return .installed(InstalledTool(tool: tool, url: url, version: ToolVersion(1, 0)))
    }

    @Test func everyToolIsProvidedByExactlyOnePackage() {
        let provided = ToolchainCatalog.entries.flatMap(\.provides)

        #expect(provided.count == Tool.allCases.count)
        #expect(Set(provided) == Set(Tool.allCases))
    }

    @Test func packagesArePinnedToSecureAppleSiliconDownloads() {
        for entry in ToolchainCatalog.entries {
            let package = entry.package
            #expect(package.url.scheme == "https")
            #expect(package.url.lastPathComponent.contains("darwin-arm64"))
            #expect(package.url.lastPathComponent.contains(package.version))
            #expect(package.sha256.wholeMatch(of: #/[0-9a-f]{64}/#) != nil)
            #expect(entry.downloadSize > 0)
        }
    }

    @Test func packagesInstallIntoSeparateFolders() {
        let folders = ToolchainCatalog.entries.map(\.package.installDirectoryName)

        #expect(folders == ["arm-gnu-toolchain-15.2.rel1", "xpack-openocd-0.12.0-7"])
    }

    @Test func nothingIsNeededWhenEverythingIsInstalled() {
        let statuses = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, installed($0)) })

        #expect(ToolchainCatalog.entriesNeeded(for: statuses).isEmpty)
    }

    @Test func everythingIsNeededWhenNothingIsKnown() {
        #expect(ToolchainCatalog.entriesNeeded(for: [:]) == ToolchainCatalog.entries)
    }

    @Test func onlyThePackageForAMissingToolIsNeeded() {
        let statuses: [Tool: ToolStatus] = [
            .compiler: installed(.compiler),
            .debugger: installed(.debugger),
            .openOCD: .missing
        ]

        #expect(ToolchainCatalog.entriesNeeded(for: statuses) == [ToolchainCatalog.openOCD])
    }

    @Test func aPackageIsNeededIfAnyOfItsToolsIsMissingOrBroken() {
        let broken = ToolStatus.notWorking(url: URL(filePath: "/bin/arm-none-eabi-gdb"), reason: "Exited with code 1")
        let statuses: [Tool: ToolStatus] = [
            .compiler: installed(.compiler),
            .debugger: broken,
            .openOCD: installed(.openOCD)
        ]

        #expect(ToolchainCatalog.entriesNeeded(for: statuses) == [ToolchainCatalog.armGNUToolchain])
    }

    @Test func describesADownloadWithItsSize() {
        let name = ToolchainCatalog.armGNUToolchain.displayNameWithSize

        #expect(name.hasPrefix("Arm GNU Toolchain (14"))
        #expect(name.hasSuffix("MB)"))
    }
}
