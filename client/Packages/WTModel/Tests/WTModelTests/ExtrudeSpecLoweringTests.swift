import Testing
import WTGeometry
import WTRender
@testable import WTModel

/// `ExtrudeFields.spec`: a new extrusion's settings lowered exactly as the scene lowers them, so the
/// Extrude tool's preview draws what its release writes (extrude.adoc, "Extruding").
@Suite struct ExtrudeSpecLoweringTests {
    @Test func theDefaultsLowerToTheSpecTheSceneDraws() {
        let props = ExtrudeFields.defaults(length: Extrude.defaultLength, vanishingPoint: Point(x: 320, y: 40))
        let spec = ExtrudeFields.spec(props)
        #expect(spec == Wrappers.extrude(props))
        #expect(spec.length == 36 && spec.vanishingPoint == Point(x: 320, y: 40) && spec.surface == .shaded && spec.ambient == 30)
        #expect(spec.light1 == ExtrudeSpec.Light(direction: .topLeft, intensity: 80) && spec.light2.direction == .none && spec.profile.kind == .none)
        #expect(Extrude([], vanishingPoint: .zero).length == Extrude.defaultLength)
    }
}
