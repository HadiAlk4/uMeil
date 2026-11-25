import Foundation

/// A settings store of its own for one test, deleted, file and all, when
/// the last thing using it lets go of it.
///
/// `removePersistentDomain(forName:)` empties a suite but leaves its plist
/// in ~/Library/Preferences, so every test that made its own suite used to
/// leave a file behind.
final class TestDefaults: UserDefaults, @unchecked Sendable {
    /// Suites start with this, so leftovers are easy to find.
    static let prefix = "uMeilTests-"

    /// Leftovers older than this are from runs that have finished.
    static let staleAge: TimeInterval = 60 * 60

    let name: String

    init() {
        Self.removeStaleSuitesOnce
        name = Self.prefix + UUID().uuidString
        super.init(suiteName: name)!
    }

    deinit {
        removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: Self.file(for: name))
    }

    static func file(for name: String) -> URL {
        URL.libraryDirectory.appending(path: "Preferences/\(name).plist", directoryHint: .notDirectory)
    }

    /// Clears up after runs that stopped before their stores were freed,
    /// such as a crash or a test that leaks its window. Only old files are
    /// touched, so a run going on at the same time keeps its own.
    private static let removeStaleSuitesOnce: Void = {
        removeStaleSuites(olderThan: Date.now.addingTimeInterval(-staleAge))
    }()

    static func removeStaleSuites(
        olderThan cutoff: Date,
        in folder: URL = URL.libraryDirectory.appending(path: "Preferences")
    ) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.pathExtension == "plist" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
