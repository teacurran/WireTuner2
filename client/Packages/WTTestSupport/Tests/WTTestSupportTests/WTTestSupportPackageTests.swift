import Testing
@testable import WTTestSupport

@Suite struct WTTestSupportPackageTests {
    @Test func nameMatchesModule() {
        #expect(WTTestSupportPackage.name == "WTTestSupport")
        #expect(WTTestSupportPackage.matches("wttestsupport"))
        #expect(!WTTestSupportPackage.matches(""))
        #expect(!WTTestSupportPackage.matches("Other"))
    }
}
