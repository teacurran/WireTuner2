import Testing
@testable import WTModel

@Suite struct WTModelPackageTests {
    @Test func nameMatchesModule() {
        #expect(WTModelPackage.name == "WTModel")
        #expect(WTModelPackage.matches("wtmodel"))
        #expect(!WTModelPackage.matches(""))
        #expect(!WTModelPackage.matches("Other"))
    }
}
