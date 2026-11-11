import Foundation
@testable import uMeil

/// A scratch folder that is deleted when the test that owns it finishes.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "uMeilTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates (if needed) and returns a folder inside this one.
    func directory(_ path: String) throws -> URL {
        let directory = url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Stand-ins for real tools: small shell scripts with the right file names.
enum FakeTool {
    /// Writes an executable script named after `tool` into `directory`.
    @discardableResult
    static func install(
        _ tool: Tool,
        in directory: URL,
        script: String,
        executable: Bool = true
    ) throws -> URL {
        let url = directory.appending(path: tool.executableName, directoryHint: .notDirectory)
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        return url
    }

    /// A script that prints `line` the way the real tool prints its version.
    static func versionScript(_ line: String, toStandardError: Bool = false) -> String {
        "echo '\(line)'" + (toStandardError ? " >&2" : "")
    }
}
