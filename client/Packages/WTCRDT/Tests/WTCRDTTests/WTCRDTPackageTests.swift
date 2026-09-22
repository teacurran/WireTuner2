import Testing
@testable import WTCRDT

@Suite struct WTCRDTPackageTests {
    @Test func nameMatchesModule() {
        #expect(WTCRDTPackage.name == "WTCRDT")
        #expect(WTCRDTPackage.matches("wtcrdt"))
        #expect(!WTCRDTPackage.matches(""))
        #expect(!WTCRDTPackage.matches("Other"))
    }
}
