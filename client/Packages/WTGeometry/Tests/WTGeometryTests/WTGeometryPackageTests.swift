import Testing
@testable import WTGeometry

@Suite struct WTGeometryPackageTests {
    @Test func nameMatchesModule() {
        #expect(WTGeometryPackage.name == "WTGeometry")
        #expect(WTGeometryPackage.matches("wtgeometry"))
        #expect(!WTGeometryPackage.matches(""))
        #expect(!WTGeometryPackage.matches("Other"))
    }
}
