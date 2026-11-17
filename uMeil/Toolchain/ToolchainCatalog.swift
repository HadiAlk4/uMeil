import Foundation

/// A package uMeil knows how to download, and what it is for.
struct ToolchainCatalogEntry: Equatable, Sendable {
    /// A name suitable for showing to the user.
    let displayName: String
    /// The tools this package contains.
    let provides: [Tool]
    /// The size of the download in bytes, for telling the user what to expect.
    let downloadSize: Int64
    let package: ToolchainPackage

    /// For example "Arm GNU Toolchain (142 MB)".
    var displayNameWithSize: String {
        "\(displayName) (\(ByteCountFormatter.string(fromByteCount: downloadSize, countStyle: .file)))"
    }
}

/// The official downloads uMeil installs when tools are missing.
///
/// These are the publishers' own unmodified archives for Apple Silicon, pinned
/// to an exact version and checksum. To move to a new release, update the
/// version, URL, size, and SHA-256 together.
enum ToolchainCatalog {
    /// Arm's full GNU toolchain: compiler, debugger, and libraries for every Cortex-M core.
    static let armGNUToolchain = ToolchainCatalogEntry(
        displayName: "Arm GNU Toolchain",
        provides: [.compiler, .debugger],
        downloadSize: 141_961_944,
        package: ToolchainPackage(
            name: "arm-gnu-toolchain",
            version: "15.2.rel1",
            url: URL(string: "https://developer.arm.com/-/media/Files/downloads/gnu/15.2.rel1/binrel/"
                + "arm-gnu-toolchain-15.2.rel1-darwin-arm64-arm-none-eabi.tar.xz")!,
            sha256: "1938a84b7105c192e3fb4fa5e893ba25f425f7ddab40515ae608cd40f68669a8"
        )
    )

    /// OpenOCD, from the xPack project's prebuilt binaries.
    static let openOCD = ToolchainCatalogEntry(
        displayName: "OpenOCD",
        provides: [.openOCD],
        downloadSize: 2_385_815,
        package: ToolchainPackage(
            name: "xpack-openocd",
            version: "0.12.0-7",
            url: URL(string: "https://github.com/xpack-dev-tools/openocd-xpack/releases/download/v0.12.0-7/"
                + "xpack-openocd-0.12.0-7-darwin-arm64.tar.gz")!,
            sha256: "667342c086984f3e5a55b4e0d5f711add13fb04de040fca493303000e6c19327"
        )
    )

    /// `clangd`, downloaded on demand when neither Xcode nor the Command Line Tools is installed.
    static let clangd = ToolchainCatalogEntry(
        displayName: "clangd",
        provides: [.clangd],
        downloadSize: 100_060_151,
        package: ToolchainPackage(
            name: "clangd",
            version: "23.1.0",
            url: URL(string: "https://github.com/clangd/clangd/releases/download/23.1.0/clangd-mac-23.1.0.zip")!,
            sha256: "1082e6638223b785ca2daf0939f13afcd0bb95c84ee9a4bbaff4745365159253"
        )
    )

    static let entries = [armGNUToolchain, openOCD, clangd]

    /// The packages to download so that every tool is installed. A package is
    /// needed if any tool it provides is not currently installed and working.
    static func entriesNeeded(for statuses: [Tool: ToolStatus]) -> [ToolchainCatalogEntry] {
        entries.filter { entry in
            entry.provides.contains { tool in
                if case .installed = statuses[tool] { false } else { true }
            }
        }
    }
}
