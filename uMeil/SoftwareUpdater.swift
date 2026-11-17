import AppKit
import Sparkle

/// App > Check for Updates…, through Sparkle.
///
/// Sparkle only installs an update whose archive is signed with the
/// project's EdDSA key, so it is started only when the app was built with
/// the public half of that key (`SUPublicEDKey`, from the
/// `SPARKLE_PUBLIC_ED_KEY` build setting) and an HTTPS feed. Development
/// builds have neither, never check for updates, and show no menu item.
@MainActor
final class SoftwareUpdater: NSObject, NSMenuItemValidation {
    /// Where updates are described and who signs them, from the Info.plist.
    struct Configuration: Equatable {
        var feedURL: URL?
        var publicKey: String

        init(feedURL: URL?, publicKey: String) {
            self.feedURL = feedURL
            self.publicKey = publicKey
        }

        init(bundle: Bundle) {
            feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init(string:))
            publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        }

        /// An Ed25519 public key is 32 bytes, written in Base64.
        var hasValidKey: Bool {
            Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespaces))?.count == 32
        }

        var isComplete: Bool {
            hasValidKey && feedURL?.scheme == "https"
        }
    }

    let configuration: Configuration
    private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    init(configuration: Configuration = Configuration(bundle: .main)) {
        self.configuration = configuration
        controller = configuration.isComplete
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// The menu item, or `nil` when updates are off in this build.
    func makeMenuItem() -> NSMenuItem? {
        guard isAvailable else { return nil }
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return controller?.updater.canCheckForUpdates ?? false
    }
}
