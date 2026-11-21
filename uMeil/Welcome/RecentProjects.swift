import Foundation

/// The project folders opened most recently, newest first, kept between
/// launches for the welcome screen.
struct RecentProjects {
    static let defaultsKey = "RecentProjects"
    /// How many folders are remembered.
    static let limit = 8

    let defaults: UserDefaults

    /// The remembered folders that still exist, newest first.
    var folders: [URL] {
        let paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        return paths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
    }

    /// Moves `folder` to the top of the list, dropping the oldest past the limit.
    func add(_ folder: URL) {
        let path = Self.path(of: folder)
        var paths = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        paths.removeAll { Self.path(of: URL(filePath: $0)) == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(Self.limit)), forKey: Self.defaultsKey)
    }

    /// Forgets `folder`, for one the user removed from the list.
    func remove(_ folder: URL) {
        let path = Self.path(of: folder)
        let paths = (defaults.stringArray(forKey: Self.defaultsKey) ?? [])
            .filter { Self.path(of: URL(filePath: $0)) != path }
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    /// The path without a trailing slash, so one folder is stored only once.
    private static func path(of url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
