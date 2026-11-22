import Foundation

/// Finds tool executables by looking through a list of directories in order.
struct ToolLocator: Sendable {
    /// Directories to search, highest priority first.
    var searchDirectories: [URL]
    /// Extra directories searched after `searchDirectories` for a specific tool.
    var extraDirectories: [Tool: [URL]] = [:]
    /// Executable paths to skip for a tool (such as macOS's `/usr/bin/clangd` shim).
    var excludedPaths: [Tool: Set<String>] = [:]

    /// The first usable executable for `tool`, or `nil` if there is none.
    func locate(_ tool: Tool) -> URL? {
        candidates(for: tool).first
    }

    /// Every executable for `tool` in the search directories, in priority order.
    func candidates(for tool: Tool) -> [URL] {
        let directories = Self.deduplicated(searchDirectories + (extraDirectories[tool] ?? []))
        let excluded = excludedPaths[tool] ?? []
        return directories
            .map { $0.appending(path: tool.executableName, directoryHint: .notDirectory) }
            .filter { url in
                !excluded.contains(url.standardizedFileURL.path(percentEncoded: false))
                    && Self.isExecutableFile(url)
            }
    }

    /// `directories` in the same order, keeping only the first of any that
    /// name the same folder.
    private static func deduplicated(_ directories: [URL]) -> [URL] {
        var seen = Set<String>()
        return directories.filter { directory in
            seen.insert(directory.standardizedFileURL.path(percentEncoded: false)).inserted
        }
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
        ToolLocator(
            searchDirectories: defaultSearchDirectories(),
            extraDirectories: [.clangd: clangdSearchDirectories()],
            // /usr/bin/clangd is an xcrun trampoline that pops up an OS install prompt
            // or fails when Xcode and the Command Line Tools are absent.
            excludedPaths: [.clangd: ["/usr/bin/clangd"]]
        )
    }

    /// Extra places `clangd` lives on macOS: Xcode's toolchain, the Command
    /// Line Tools, and Homebrew's keg-only `llvm` formula.
    static func clangdSearchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        xcodeToolchainDirectory: URL = URL(
            filePath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin",
            directoryHint: .isDirectory
        ),
        commandLineToolsDirectory: URL = URL(
            filePath: "/Library/Developer/CommandLineTools/usr/bin",
            directoryHint: .isDirectory
        )
    ) -> [URL] {
        var directories: [URL] = []
        if let developerDir = environment["DEVELOPER_DIR"], !developerDir.isEmpty {
            directories.append(
                URL(filePath: developerDir, directoryHint: .isDirectory)
                    .appending(path: "Toolchains/XcodeDefault.xctoolchain/usr/bin", directoryHint: .isDirectory)
            )
        }
        directories.append(xcodeToolchainDirectory)
        directories.append(commandLineToolsDirectory)
        directories.append(contentsOf: ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        })

        return deduplicated(directories)
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
            .filter { $0.hasPrefix("/") }
            .map { URL(filePath: String($0), directoryHint: .isDirectory) }

        let homebrew = ["/opt/homebrew/bin", "/usr/local/bin"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }

        let armInstaller = subdirectories(
            of: applicationsDirectory.appending(path: "ArmGNUToolchain", directoryHint: .isDirectory)
        ).map { $0.appending(path: "arm-none-eabi/bin", directoryHint: .isDirectory) }

        return deduplicated(managed + path + homebrew + armInstaller)
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
