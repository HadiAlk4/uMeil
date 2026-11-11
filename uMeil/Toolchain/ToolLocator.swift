import Foundation

/// Finds tool executables by looking through a list of directories in order.
struct ToolLocator: Sendable {
    /// Directories to search, highest priority first.
    var searchDirectories: [URL]

    /// The first usable executable for `tool`, or `nil` if there is none.
    func locate(_ tool: Tool) -> URL? {
        candidates(for: tool).first
    }

    /// Every executable for `tool` in the search directories, in priority order.
    func candidates(for tool: Tool) -> [URL] {
        searchDirectories
            .map { $0.appending(path: tool.executableName, directoryHint: .notDirectory) }
            .filter(Self.isExecutableFile)
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

extension ToolLocator {
    /// A locator that searches the places tools normally live on a Mac.
    static func standard() -> ToolLocator {
        ToolLocator(searchDirectories: defaultSearchDirectories())
    }

    /// The default search order:
    /// 1. Toolchains uMeil downloaded itself (newest first).
    /// 2. The `PATH` the app was launched with.
    /// 3. Homebrew. Apps launched from Finder do not inherit the shell's
    ///    `PATH`, so these are listed explicitly.
    /// 4. Arm's official installer location (newest first).
    static func defaultSearchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        managedToolchainsDirectory: URL = AppPaths.toolchainsDirectory,
        applicationsDirectory: URL = URL(filePath: "/Applications", directoryHint: .isDirectory)
    ) -> [URL] {
        let managed = subdirectories(of: managedToolchainsDirectory)
            .map { $0.appending(path: "bin", directoryHint: .isDirectory) }

        let path = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(filePath: String($0), directoryHint: .isDirectory) }

        let homebrew = ["/opt/homebrew/bin", "/usr/local/bin"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }

        let armInstaller = subdirectories(
            of: applicationsDirectory.appending(path: "ArmGNUToolchain", directoryHint: .isDirectory)
        ).map { $0.appending(path: "arm-none-eabi/bin", directoryHint: .isDirectory) }

        var seen = Set<String>()
        return (managed + path + homebrew + armInstaller).filter { directory in
            seen.insert(directory.standardizedFileURL.path(percentEncoded: false)).inserted
        }
    }

    /// The folders directly inside `directory`, newest version name first.
    private static func subdirectories(of directory: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return (contents ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
    }
}
