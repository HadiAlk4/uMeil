import CryptoKit
import Darwin
import Foundation
import os

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
    case invalidPackage(String)
    case downloadFailed(statusCode: Int)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let details):
            "The toolchain package cannot be installed. \(details)"
        case .downloadFailed(let statusCode):
            "The download failed (HTTP \(statusCode))."
        case .checksumMismatch:
            "The downloaded file is damaged or is not the expected file, so it was not installed."
        case .extractionFailed(let details):
            "The downloaded archive could not be unpacked. \(details)"
        }
    }
}

/// How far an install has got, for showing progress to the user.
enum ToolchainInstallProgress: Equatable, Sendable {
    /// Downloading; `fraction` runs from 0 to 1.
    case downloading(fraction: Double)
    case verifying
    case unpacking
}

/// Downloads a toolchain package, verifies it, and unpacks it where
/// `ToolLocator` will find it.
struct ToolchainInstaller: Sendable {
    var toolchainsDirectory: URL = AppPaths.toolchainsDirectory
    var session: URLSession = .shared
    var runner: any ProcessRunning = ProcessRunner()
    /// Tests use `file://` archives to exercise downloading without the network.
    var allowInsecureURLsForTesting: Bool = false

    /// Installs `package` and returns the folder it was installed into.
    ///
    /// Nothing is left behind in the toolchains directory if any step fails,
    /// and an existing install of the same version is only replaced once the
    /// new one has been verified and unpacked.
    ///
    /// `progress` is called as the install advances. It may be called from
    /// any thread.
    @discardableResult
    func install(
        _ package: ToolchainPackage,
        progress: @escaping @Sendable (ToolchainInstallProgress) -> Void = { _ in }
    ) async throws -> URL {
        try validate(package)
        let fileManager = FileManager.default

        let (archive, response) = try await download(package.url) { fraction in
            progress(.downloading(fraction: fraction))
        }
        defer { try? fileManager.removeItem(at: archive) }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ToolchainInstallError.downloadFailed(statusCode: http.statusCode)
        }

        progress(.verifying)
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

        progress(.unpacking)
        try await extract(archive, into: staging)

        let destination = toolchainsDirectory.appending(path: package.installDirectoryName, directoryHint: .isDirectory)
        let source = try Self.contentRoot(of: staging)
        var statInfo = stat()
        if lstat(destination.path(percentEncoded: false), &statInfo) == 0 {
            if (statInfo.st_mode & S_IFMT) == S_IFLNK {
                try fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: source, to: destination)
            } else {
                _ = try fileManager.replaceItemAt(destination, withItemAt: source)
            }
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
        return destination
    }

    private func validate(_ package: ToolchainPackage) throws {
        guard Self.isSafePathComponent(package.name),
              Self.isSafePathComponent(package.version)
        else {
            throw ToolchainInstallError.invalidPackage("Package name and version must be safe single path components.")
        }
        let scheme = package.url.scheme?.lowercased()
        let isValidHTTPS = scheme == "https" && !(package.url.host ?? "").isEmpty
        let isAllowedTestFile = allowInsecureURLsForTesting && scheme == "file"
        guard isValidHTTPS || isAllowedTestFile else {
            throw ToolchainInstallError.invalidPackage("Package URLs must use HTTPS.")
        }
    }

    static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains(".."),
              !component.hasPrefix(".")
        else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 0x30 && value <= 0x39)
                || (value >= 0x41 && value <= 0x5A)
                || (value >= 0x61 && value <= 0x7A)
                || value == 0x2D
                || value == 0x5F
                || value == 0x2E
        }
    }

    /// Downloads `url` to a temporary file, reporting the fraction completed
    /// each time it advances by at least one percent.
    private func download(
        _ url: URL,
        reportFraction: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let observation = OSAllocatedUnfairLock<NSKeyValueObservation?>(uncheckedState: nil)
        defer { observation.withLockUnchecked { $0 = nil } }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url) { location, response, error in
                guard let location, let response else {
                    continuation.resume(throwing: error ?? URLError(.unknown))
                    return
                }
                // The system deletes the downloaded file as soon as this
                // handler returns, so move it somewhere of our own first.
                let kept = FileManager.default.temporaryDirectory
                    .appending(path: "uMeil-download-\(UUID().uuidString)", directoryHint: .notDirectory)
                continuation.resume(with: Result {
                    try FileManager.default.moveItem(at: location, to: kept)
                    return (kept, response)
                })
            }

            let lastPercent = OSAllocatedUnfairLock(initialState: -1)
            let token = task.progress.observe(\.fractionCompleted, options: [.initial]) { taskProgress, _ in
                let fraction = min(max(taskProgress.fractionCompleted, 0), 1)
                let percent = Int(fraction * 100)
                let advanced = lastPercent.withLock { last in
                    guard percent > last else { return false }
                    last = percent
                    return true
                }
                if advanced {
                    reportFraction(fraction)
                }
            }
            observation.withLockUnchecked { $0 = token }
            task.resume()
        }
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
