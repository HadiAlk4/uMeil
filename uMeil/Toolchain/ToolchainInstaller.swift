import CryptoKit
import Foundation

/// A downloadable archive of tools, with the checksum it must match.
struct ToolchainPackage: Codable, Equatable, Sendable {
    /// A short identifier such as `arm-gnu-toolchain`.
    let name: String
    let version: String
    /// Where to download the archive (`.tar.xz`, `.tar.gz`, or `.zip`).
    let url: URL
    /// The archive's SHA-256, as hexadecimal.
    let sha256: String

    /// The folder this package is installed into, inside the toolchains directory.
    var installDirectoryName: String { "\(name)-\(version)" }
}

enum ToolchainInstallError: Error, Equatable, LocalizedError {
    case downloadFailed(statusCode: Int)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let statusCode):
            "The download failed (HTTP \(statusCode))."
        case .checksumMismatch:
            "The downloaded file is damaged or is not the expected file, so it was not installed."
        case .extractionFailed(let details):
            "The downloaded archive could not be unpacked. \(details)"
        }
    }
}

/// Downloads a toolchain package, verifies it, and unpacks it where
/// `ToolLocator` will find it.
struct ToolchainInstaller: Sendable {
    var toolchainsDirectory: URL = AppPaths.toolchainsDirectory
    var session: URLSession = .shared
    var runner: any ProcessRunning = ProcessRunner()

    /// Installs `package` and returns the folder it was installed into.
    ///
    /// Nothing is left behind in the toolchains directory if any step fails,
    /// and an existing install of the same version is only replaced once the
    /// new one has been verified and unpacked.
    @discardableResult
    func install(_ package: ToolchainPackage) async throws -> URL {
        let fileManager = FileManager.default

        let (archive, response) = try await session.download(from: package.url)
        defer { try? fileManager.removeItem(at: archive) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ToolchainInstallError.downloadFailed(statusCode: http.statusCode)
        }

        let expected = package.sha256.lowercased()
        let actual = try Self.sha256(ofFileAt: archive)
        guard actual == expected else {
            throw ToolchainInstallError.checksumMismatch(expected: expected, actual: actual)
        }

        // Unpack into a hidden folder next to the final location, so the move
        // into place stays on one volume and the locator never sees a
        // half-unpacked toolchain.
        try fileManager.createDirectory(at: toolchainsDirectory, withIntermediateDirectories: true)
        let staging = toolchainsDirectory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        try await extract(archive, into: staging)

        let destination = toolchainsDirectory.appending(path: package.installDirectoryName, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: Self.contentRoot(of: staging), to: destination)
        return destination
    }

    private func extract(_ archive: URL, into directory: URL) async throws {
        // The system `tar` is bsdtar, which detects the format itself and
        // handles .tar.xz, .tar.gz, and .zip.
        let output = try await runner.run(
            URL(filePath: "/usr/bin/tar"),
            arguments: [
                "-xf", archive.path(percentEncoded: false),
                "-C", directory.path(percentEncoded: false)
            ]
        )
        guard output.exitCode == 0 else {
            throw ToolchainInstallError.extractionFailed(
                output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Archives usually wrap everything in one top-level folder. If so, that
    /// folder is the toolchain; otherwise the unpacked folder itself is.
    private static func contentRoot(of directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if contents.count == 1,
           let only = contents.first,
           try only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            return only
        }
        return directory
    }

    /// Hashes a file in chunks, so a large toolchain archive never has to fit in memory.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
