import Foundation
import Testing
@testable import WireTuner

/// When the app starts Sparkle (releasing.adoc): only with a public key and an https feed.
struct UpdaterConfigurationTests {
    private let feed = "https://updates.villagecompute.com/wiretuner/beta/appcast.xml"
    private let key = "pP6Q93Once0gckZgszsvLb1bgz16PXvZxMizsYaqxCQ="

    @Test func aKeyAndAnHTTPSFeedConfigureUpdates() {
        #expect(AppDelegate.updatesConfigured(["SUPublicEDKey": key, "SUFeedURL": feed]))
    }

    @Test func anEmptyOrMissingKeyLeavesTheUpdaterOff() {
        #expect(!AppDelegate.updatesConfigured(["SUPublicEDKey": "", "SUFeedURL": feed]))
        #expect(!AppDelegate.updatesConfigured(["SUPublicEDKey": "  ", "SUFeedURL": feed]))
        #expect(!AppDelegate.updatesConfigured(["SUFeedURL": feed]))
        #expect(!AppDelegate.updatesConfigured(nil))
    }

    @Test func aFeedThatIsNotHTTPSLeavesTheUpdaterOff() {
        #expect(!AppDelegate.updatesConfigured(["SUPublicEDKey": key]))
        #expect(!AppDelegate.updatesConfigured(["SUPublicEDKey": key, "SUFeedURL": ""]))
        #expect(!AppDelegate.updatesConfigured(["SUPublicEDKey": key, "SUFeedURL": "http://example.com/appcast.xml"]))
        #expect(!AppDelegate.updatesConfigured(["SUPublicEDKey": key, "SUFeedURL": "https:///appcast.xml"]))
    }

    /// The test host is a Debug build, whose key is empty: it must not be checking for updates.
    @Test func theDebugBuildCarriesNoKey() {
        #expect(!AppDelegate.updatesConfigured(Bundle.main.infoDictionary))
    }
}
