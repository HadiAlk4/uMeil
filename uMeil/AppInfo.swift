import Foundation

/// Static facts about the app, read from the bundle where possible.
enum AppInfo {
    static let name = "uMeil"

    /// The chip uMeil targets. Only one is supported for now.
    static let targetChip = "TM4C129"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
