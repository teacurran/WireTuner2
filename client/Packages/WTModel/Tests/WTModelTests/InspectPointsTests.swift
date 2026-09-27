import Testing
import WTCRDT
import WTGeometry
@testable import WTModel

/// COLLAB-035's rest: the path point Inspect mode reads out under the pointer.
@Suite struct InspectPointsTests {
    @Test func theNearestAnchorWithinTheToleranceReadsOut() throws {
        var a = Replica(0xA)
        let rect = try CopiesBehindTests.rect(&a)
        let bounds = try #require(Objects.bounds(of: rect, in: a.state))
        let corner = Point(x: bounds.minX, y: bounds.minY)
        let found = try #require(InspectPoints.anchor(of: rect, near: Point(x: corner.x + 0.5, y: corner.y + 0.5), tolerance: 1, in: a.state))
        #expect(found.distance(to: corner) < 1e-9)
        #expect(InspectPoints.anchor(of: rect, near: bounds.center, tolerance: 1, in: a.state) == nil, "the middle is far from every anchor")
        #expect(InspectPoints.anchor(of: OpID(counter: 999, replica: 9), near: corner, tolerance: 5, in: a.state) == nil)
    }
}
