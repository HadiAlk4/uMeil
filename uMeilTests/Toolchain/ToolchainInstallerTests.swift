import CryptoKit
import Foundation
import os
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

        let installed = try await ToolchainInstaller(
            toolchainsDirectory: toolchains,
            allowInsecureURLsForTesting: true
        ).install(package)

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

        let installed = try await ToolchainInstaller(
            toolchainsDirectory: toolchains,
            allowInsecureURLsForTesting: true
        ).install(package)

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
            try await ToolchainInstaller(
                toolchainsDirectory: toolchains,
                allowInsecureURLsForTesting: true
            ).install(tampered)
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

        try await ToolchainInstaller(
            toolchainsDirectory: toolchains,
            allowInsecureURLsForTesting: true
        ).install(package)

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
            try await ToolchainInstaller(
                toolchainsDirectory: toolchains,
                allowInsecureURLsForTesting: true
            ).install(package)
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

        let installed = try await ToolchainInstaller(
            toolchainsDirectory: toolchains,
            allowInsecureURLsForTesting: true
        ).install(package)

        #expect(try visibleItems(in: installed) == ["bin"])
    }

    @Test func preservesExistingInstallIfNewArchiveFailsExtraction() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let existing = try temp.directory("Toolchains/arm-gnu-toolchain-14.2.1")
        try Data("keep-me".utf8).write(to: existing.appending(path: "marker.txt"))
        let garbage = Data("corrupt".utf8)
        let archive = temp.url.appending(path: "broken.tar.gz")
        try garbage.write(to: archive)
        let package = ToolchainPackage(
            name: "arm-gnu-toolchain",
            version: "14.2.1",
            url: archive,
            sha256: Self.sha256(of: garbage)
        )

        await #expect {
            try await ToolchainInstaller(
                toolchainsDirectory: toolchains,
                allowInsecureURLsForTesting: true
            ).install(package)
        } throws: { error in
            guard case ToolchainInstallError.extractionFailed = error else { return false }
            return true
        }
        #expect(try visibleItems(in: existing) == ["marker.txt"])
    }

    @Test func reportsProgressThroughEachStage() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let bin = try temp.directory("source/toolchain/bin")
        try FakeTool.install(.compiler, in: bin, script: gccScript)
        let package = try makePackage(archiving: "toolchain", in: temp)
        let reported = OSAllocatedUnfairLock(initialState: [ToolchainInstallProgress]())

        try await ToolchainInstaller(
            toolchainsDirectory: toolchains,
            allowInsecureURLsForTesting: true
        ).install(package) { progress in
            reported.withLock { $0.append(progress) }
        }

        let events = reported.withLock { $0 }
        let fractions = events.compactMap { event -> Double? in
            if case .downloading(let fraction) = event { fraction } else { nil }
        }
        // Downloading comes first and only ever moves forward, within 0...1.
        #expect(!fractions.isEmpty)
        #expect(fractions == fractions.sorted())
        #expect(fractions.allSatisfy { (0...1).contains($0) })
        // Then verifying, then unpacking, once each and in that order.
        #expect(Array(events.dropFirst(fractions.count)) == [.verifying, .unpacking])
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

extension ToolchainInstallerTests {
    @Test(arguments: [
        ("", "1.0.0"),
        ("..", "1.0.0"),
        (".", "1.0.0"),
        ("../escape", "1.0.0"),
        ("bad/name", "1.0.0"),
        ("bad:name", "1.0.0"),
        ("bad\0name", "1.0.0"),
        ("bad\nname", "1.0.0"),
        (".hidden", "1.0.0"),
        ("tool", ""),
        ("tool", "1..0"),
        ("tool", "1/0"),
        ("tool", "1:0"),
        ("tool", "1\0"),
        ("tool", "1\r\n0")
    ])
    func rejectsUnsafePackageNamesAndVersions(name: String, version: String) async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let package = ToolchainPackage(
            name: name,
            version: version,
            url: URL(string: "https://example.com/toolchain.tar.gz")!,
            sha256: String(repeating: "a", count: 64)
        )

        await #expect {
            try await ToolchainInstaller(toolchainsDirectory: toolchains).install(package)
        } throws: { error in
            guard case ToolchainInstallError.invalidPackage = error else { return false }
            return true
        }
    }

    @Test(arguments: [
        "http://example.com/toolchain.tar.gz",
        "file:///tmp/toolchain.tar.gz",
        "ftp://example.com/toolchain.tar.gz"
    ])
    func refusesNonHTTPSDownloadsByDefault(urlString: String) async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let package = ToolchainPackage(
            name: "arm-gnu-toolchain",
            version: "14.2.1",
            url: try #require(URL(string: urlString)),
            sha256: String(repeating: "a", count: 64)
        )

        await #expect {
            try await ToolchainInstaller(toolchainsDirectory: toolchains).install(package)
        } throws: { error in
            guard case ToolchainInstallError.invalidPackage = error else { return false }
            return true
        }
    }

    @Test func installsFromHTTPSUsingMockSession() async throws {
        let temp = try TemporaryDirectory()
        let toolchains = temp.url.appending(path: "Toolchains", directoryHint: .isDirectory)
        let bin = try temp.directory("source/toolchain/bin")
        try FakeTool.install(.compiler, in: bin, script: gccScript)
        let localPackage = try makePackage(archiving: "toolchain", in: temp)
        let archiveData = try Data(contentsOf: localPackage.url)

        let httpsURL = try #require(URL(string: "https://downloads.example.com/\(UUID().uuidString)/toolchain.tar.gz"))
        MockHTTPSProtocol.register(url: httpsURL, data: archiveData)
        defer { MockHTTPSProtocol.unregister(url: httpsURL) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTPSProtocol.self]
        let session = URLSession(configuration: config)

        let httpsPackage = ToolchainPackage(
            name: localPackage.name,
            version: localPackage.version,
            url: httpsURL,
            sha256: localPackage.sha256
        )

        let installed = try await ToolchainInstaller(toolchainsDirectory: toolchains, session: session)
            .install(httpsPackage)

        #expect(try visibleItems(in: installed) == ["bin"])
    }
}

private final class MockHTTPSProtocol: URLProtocol, @unchecked Sendable {
    private static let responses = OSAllocatedUnfairLock(initialState: [URL: Data]())

    static func register(url: URL, data: Data) {
        responses.withLock { $0[url] = data }
    }

    static func unregister(url: URL) {
        responses.withLock { _ = $0.removeValue(forKey: url) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return responses.withLock { $0[url] != nil }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let data = Self.responses.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(data.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
