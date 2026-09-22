import Testing
@testable import WTText

@Suite struct WTTextPackageTests {
    @Test func nameMatchesModule() {
        #expect(WTTextPackage.name == "WTText")
        #expect(WTTextPackage.matches("wttext"))
        #expect(!WTTextPackage.matches(""))
        #expect(!WTTextPackage.matches("Other"))
    }
}
