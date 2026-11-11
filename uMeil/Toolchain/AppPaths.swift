import Foundation

/// Locations on disk that belong to uMeil.
enum AppPaths {
    /// `~/Library/Application Support/uMeil`
    static var applicationSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: AppInfo.name, directoryHint: .isDirectory)
    }

    /// Where toolchains downloaded by uMeil are installed, one folder each.
    static var toolchainsDirectory: URL {
        applicationSupportDirectory.appending(path: "Toolchains", directoryHint: .isDirectory)
    }
}
