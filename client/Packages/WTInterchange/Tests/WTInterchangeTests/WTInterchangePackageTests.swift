import Testing
@testable import WTInterchange

@Suite struct WTInterchangePackageTests {
    @Test func nameMatchesModule() {
        #expect(WTInterchangePackage.name == "WTInterchange")
        #expect(WTInterchangePackage.matches("wtinterchange"))
        #expect(!WTInterchangePackage.matches(""))
        #expect(!WTInterchangePackage.matches("Other"))
    }
}
