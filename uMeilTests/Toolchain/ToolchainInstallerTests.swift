import CryptoKit
import Foundation
import Testing
@testable import uMeil

/// These download from `file://` URLs, so they exercise the real download,
/// checksum, and unpacking code without needing the network.
struct ToolchainInstallerTests {
    private let gccScript = FakeTool.versionScript("arm-none-eabi-gcc (GCC) 14.2.0")

    @Test func installsAVerifiedArchiveWhereTheLocatorFindsIt() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        // Like Arm's archives: everything inside one top-level folder.
        let bin = try temp.directory("source/arm-gnu-toolchain-14.2.rel1-darwin-arm64/bin")
        try FakeTool.install(.compiler, in: bin, script: gccScript)
        let package = try makePackage(archiving: "arm-gnu-toolchain-14.2.rel1-darwin-arm64", in: temp)

        let installed = try await ToolchainInstaller(toolchainsDirectory: toolchains).install(package)

        #expect(installed.lastPathComponent == "arm-gnu-toolchain-14.2.1")
        #expect(try visibleItems(in: toolchains) == ["arm-gnu-toolchain-14.2.1"])

        let locator = ToolLocator(searchDirectories: ToolLocator.defaultSearchDirectories(
            environment: [:],
            managedToolchainsDirectory: toolchains,
            applicationsDirectory: temp.url.appending(path: "Applications")
        ))
        let status = await ToolchainChecker(locator: locator).status(of: .compiler)
        guard case .installed(let gcc) = status else {
            Issue.record("Expected the installed compiler to be found and working, got \(status)")
            return
        }
        #expect(gcc.version == ToolVersion(14, 2, 0))
        #expect(gcc.url.deletingLastPathComponent().lastPathComponent == "bin")
    }

    @Test func installsAnArchiveWithoutATopLevelFolder() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let bin = try temp.directory("source/bin")
        _ = try temp.directory("source/share")
        try FakeTool.install(.compiler, in: bin, script: gccScript)
        let package = try makePackage(archiving: "bin", "share", in: temp)

        let installed = try await ToolchainInstaller(toolchainsDirectory: toolchains).install(package)

        let gcc = installed.appending(path: "bin/arm-none-eabi-gcc")
        #expect(FileManager.default.isExecutableFile(atPath: gcc.path(percentEncoded: false)))
    }

    @Test func refusesAnArchiveWithTheWrongChecksum() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let bin = try temp.directory("source/toolchain/bin")
        try FakeTool.install(.compiler, in: bin, script: gccScript)
        let good = try makePackage(archiving: "toolchain", in: temp)
        let wrongChecksum = String(repeating: "0", count: 64)
        let tampered = ToolchainPackage(name: good.name, version: good.version, url: good.url, sha256: wrongChecksum)

        await #expect(throws: ToolchainInstallError.checksumMismatch(expected: wrongChecksum, actual: good.sha256)) {
            try await ToolchainInstaller(toolchainsDirectory: toolchains).install(tampered)
        }
        #expect(try visibleAndHiddenItems(in: toolchains).isEmpty)
    }

    @Test func acceptsAnUppercaseChecksum() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let bin = try temp.directory("source/toolchain/bin")
        try FakeTool.install(.compiler, in: bin, script: gccScript)
        let good = try makePackage(archiving: "toolchain", in: temp)
        let package = ToolchainPackage(
            name: good.name,
            version: good.version,
            url: good.url,
            sha256: good.sha256.uppercased()
        )

        try await ToolchainInstaller(toolchainsDirectory: toolchains).install(package)

        #expect(try visibleItems(in: toolchains) == ["arm-gnu-toolchain-14.2.1"])
    }

    @Test func leavesNothingBehindWhenTheArchiveIsCorrupt() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let garbage = Data("this is not an archive".utf8)
        let archive = temp.url.appending(path: "broken.tar.gz")
        try garbage.write(to: archive)
        let package = ToolchainPackage(
            name: "arm-gnu-toolchain",
            version: "14.2.1",
            url: archive,
            sha256: Self.sha256(of: garbage)
        )

        await #expect {
            try await ToolchainInstaller(toolchainsDirectory: toolchains).install(package)
        } throws: { error in
            guard case ToolchainInstallError.extractionFailed = error else { return false }
            return true
        }
        #expect(try visibleAndHiddenItems(in: toolchains).isEmpty)
    }

    @Test func replacesAnExistingInstallOfTheSameVersion() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let stale = try temp.directory("Toolchains/arm-gnu-toolchain-14.2.1")
        try Data("old".utf8).write(to: stale.appending(path: "leftover.txt"))
        let bin = try temp.directory("source/toolchain/bin")
        try FakeTool.install(.compiler, in: bin, script: gccScript)
        let package = try makePackage(archiving: "toolchain", in: temp)

        let installed = try await ToolchainInstaller(toolchainsDirectory: toolchains).install(package)

        #expect(try visibleItems(in: installed) == ["bin"])
    }

    @Test func hashesFilesTheSameWayAsHashingTheirData() throws {
        let temp = try TemporaryDirectory()
        // Bigger than one read chunk (1 MB), to cover the chunked loop.
        let data = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let file = temp.url.appending(path: "blob.bin")
        try data.write(to: file)

        #expect(try ToolchainInstaller.sha256(ofFileAt: file) == Self.sha256(of: data))
    }

    // MARK: - Helpers

    /// Archives the named items from `temp`'s `source` folder into a `.tar.gz`
    /// and returns a package pointing at it with the correct checksum.
    private func makePackage(archiving items: String..., in temp: TemporaryDirectory) throws -> ToolchainPackage {
        let archive = temp.url.appending(path: "toolchain.tar.gz")
        let source = temp.url.appending(path: "source", directoryHint: .isDirectory)

        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = [
            "-czf", archive.path(percentEncoded: false),
            "-C", source.path(percentEncoded: false)
        ] + items
        try tar.run()
        tar.waitUntilExit()
        try #require(tar.terminationStatus == 0)

        return ToolchainPackage(
            name: "arm-gnu-toolchain",
            version: "14.2.1",
            url: archive,
            sha256: Self.sha256(of: try Data(contentsOf: archive))
        )
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func visibleItems(in directory: URL) throws -> [String] {
        try visibleAndHiddenItems(in: directory).filter { !$0.hasPrefix(".") }
    }

    /// Everything in `directory`, or nothing if it was never created.
    private func visibleAndHiddenItems(in directory: URL) throws -> [String] {
        let path = directory.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: path).sorted()
    }
}
