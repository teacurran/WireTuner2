import Testing
@testable import WTRender

@Suite struct WTRenderPackageTests {
    @Test func nameMatchesModule() {
        #expect(WTRenderPackage.name == "WTRender")
        #expect(WTRenderPackage.matches("wtrender"))
        #expect(!WTRenderPackage.matches(""))
        #expect(!WTRenderPackage.matches("Other"))
    }
}
