import Foundation
import Testing
@testable import uMeil

struct ToolLocatorTests {
    @Test func findsAToolInASearchDirectory() throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        let gcc = try FakeTool.install(.compiler, in: bin, script: "exit 0")

        let locator = ToolLocator(searchDirectories: [bin])

        #expect(locator.locate(.compiler) == gcc)
        #expect(locator.locate(.debugger) == nil)
    }

    @Test func earlierDirectoriesWin() throws {
        let temp = try TemporaryDirectory()
        let first = try temp.directory("first")
        let second = try temp.directory("second")
        let preferred = try FakeTool.install(.compiler, in: first, script: "exit 0")
        let fallback = try FakeTool.install(.compiler, in: second, script: "exit 0")

        let locator = ToolLocator(searchDirectories: [first, second])

        #expect(locator.locate(.compiler) == preferred)
        #expect(locator.candidates(for: .compiler) == [preferred, fallback])
    }

    @Test func ignoresFilesThatAreNotExecutable() throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        try FakeTool.install(.compiler, in: bin, script: "exit 0", executable: false)

        #expect(ToolLocator(searchDirectories: [bin]).locate(.compiler) == nil)
    }

    @Test func ignoresDirectoriesNamedLikeATool() throws {
        let temp = try TemporaryDirectory()
        let bin = try temp.directory("bin")
        _ = try temp.directory("bin/\(Tool.compiler.executableName)")

        #expect(ToolLocator(searchDirectories: [bin]).locate(.compiler) == nil)
    }

    @Test func ignoresSearchDirectoriesThatDoNotExist() throws {
        let temp = try TemporaryDirectory()
        let missing = temp.url.appending(path: "nope", directoryHint: .isDirectory)

        #expect(ToolLocator(searchDirectories: [missing]).locate(.compiler) == nil)
    }

    @Test func defaultSearchOrderIsManagedThenPathThenHomebrewThenArmInstaller() throws {
        let temp = try TemporaryDirectory()
        let managed = try temp.directory("Toolchains")
        _ = try temp.directory("Toolchains/arm-gnu-13.2")
        _ = try temp.directory("Toolchains/arm-gnu-14.2")
        let applications = try temp.directory("Applications")
        _ = try temp.directory("Applications/ArmGNUToolchain/13.2.Rel1/arm-none-eabi/bin")
        _ = try temp.directory("Applications/ArmGNUToolchain/9.3.Rel1/arm-none-eabi/bin")

        let directories = ToolLocator.defaultSearchDirectories(
            environment: ["PATH": "/custom/bin:/opt/homebrew/bin"],
            managedToolchainsDirectory: managed,
            applicationsDirectory: applications
        )
        let paths = directories.map(Self.normalizedPath)
        let root = Self.normalizedPath(temp.url)

        #expect(paths == [
            // Managed toolchains, newest first.
            root + "/Toolchains/arm-gnu-14.2/bin",
            root + "/Toolchains/arm-gnu-13.2/bin",
            // PATH, in order.
            "/custom/bin",
            "/opt/homebrew/bin",
            // Homebrew, without repeating what PATH already listed.
            "/usr/local/bin",
            // Arm's installer, newest first (13.2 sorts after 9.3 numerically).
            root + "/Applications/ArmGNUToolchain/13.2.Rel1/arm-none-eabi/bin",
            root + "/Applications/ArmGNUToolchain/9.3.Rel1/arm-none-eabi/bin"
        ])
    }

    @Test func defaultSearchOrderCopesWithNothingInstalled() throws {
        let temp = try TemporaryDirectory()

        let directories = ToolLocator.defaultSearchDirectories(
            environment: [:],
            managedToolchainsDirectory: temp.url.appending(path: "Toolchains"),
            applicationsDirectory: temp.url.appending(path: "Applications")
        )

        #expect(directories.map(Self.normalizedPath) == ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test func clangdSearchOrderIncludesDeveloperDirXcodeCommandLineToolsAndHomebrewLLVM() throws {
        let temp = try TemporaryDirectory()
        let devDir = temp.url.appending(path: "CustomXcode.app/Contents/Developer", directoryHint: .isDirectory)
        let xcodeBin = temp.url.appending(
            path: "Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        )
        let cltBin = temp.url.appending(path: "CommandLineTools/usr/bin")

        let directories = ToolLocator.clangdSearchDirectories(
            environment: ["DEVELOPER_DIR": devDir.path(percentEncoded: false)],
            xcodeToolchainDirectory: xcodeBin,
            commandLineToolsDirectory: cltBin
        )

        #expect(directories.map(Self.normalizedPath) == [
            Self.normalizedPath(devDir.appending(path: "Toolchains/XcodeDefault.xctoolchain/usr/bin")),
            Self.normalizedPath(xcodeBin),
            Self.normalizedPath(cltBin),
            "/opt/homebrew/opt/llvm/bin",
            "/usr/local/opt/llvm/bin"
        ])
    }

    @Test func skipsExcludedStubPathsForClangd() throws {
        let temp = try TemporaryDirectory()
        let stubBin = try temp.directory("stub")
        let realBin = try temp.directory("real")
        let stub = try FakeTool.install(.clangd, in: stubBin, script: "exit 1")
        let real = try FakeTool.install(.clangd, in: realBin, script: "exit 0")

        let locator = ToolLocator(
            searchDirectories: [stubBin],
            extraDirectories: [.clangd: [realBin]],
            excludedPaths: [.clangd: [stub.standardizedFileURL.path(percentEncoded: false)]]
        )

        #expect(locator.locate(.clangd) == real)
        #expect(locator.candidates(for: .clangd) == [real])
    }

    /// A path with no trailing slash and no `/private` prefix, so that
    /// `/var/...` and `/private/var/...` (the same folder) compare equal.
    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
