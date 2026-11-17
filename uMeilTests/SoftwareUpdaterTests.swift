import AppKit
import Testing
@testable import uMeil

/// Tests for turning Sparkle's updates on only in builds that can verify them (M10).
@MainActor
struct SoftwareUpdaterTests {
    /// A real Ed25519 public key's length: 32 bytes, 44 characters of Base64.
    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed = URL(string: "https://hadialk4.github.io/uMeil/appcast.xml")

    @Test func updatesNeedAKeyAndAnHTTPSFeed() {
        #expect(SoftwareUpdater.Configuration(feedURL: feed, publicKey: key).isComplete)
        #expect(!SoftwareUpdater.Configuration(feedURL: feed, publicKey: "").isComplete)
        // An unexpanded build setting, as when the Info.plist is not processed.
        #expect(!SoftwareUpdater.Configuration(feedURL: feed, publicKey: "$(SPARKLE_PUBLIC_ED_KEY)").isComplete)
        #expect(!SoftwareUpdater.Configuration(feedURL: feed, publicKey: "c2hvcnQ=").isComplete)
        let plainHTTP = URL(string: "http://hadialk4.github.io/uMeil/appcast.xml")
        #expect(!SoftwareUpdater.Configuration(feedURL: plainHTTP, publicKey: key).isComplete)
        #expect(!SoftwareUpdater.Configuration(feedURL: nil, publicKey: key).isComplete)
    }

    @Test func theAppPointsSparkleAtTheProjectWebsite() {
        let configuration = SoftwareUpdater.Configuration(bundle: .main)
        #expect(configuration.feedURL == feed)
    }

    @Test func aBuildWithoutTheKeyNeverChecksAndShowsNoMenuItem() {
        let updater = SoftwareUpdater(configuration: .init(feedURL: feed, publicKey: ""))
        #expect(!updater.isAvailable)
        #expect(updater.makeMenuItem() == nil)

        let appMenu = MainMenu.make(appName: "uMeil", updater: updater).items.first?.submenu
        #expect(appMenu?.items.contains { $0.title == "Check for Updates…" } == false)
    }
}
