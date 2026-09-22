import Testing
@testable import WTSync

@Suite struct WTSyncPackageTests {
    @Test func nameMatchesModule() {
        #expect(WTSyncPackage.name == "WTSync")
        #expect(WTSyncPackage.matches("wtsync"))
        #expect(!WTSyncPackage.matches(""))
        #expect(!WTSyncPackage.matches("Other"))
    }
}
