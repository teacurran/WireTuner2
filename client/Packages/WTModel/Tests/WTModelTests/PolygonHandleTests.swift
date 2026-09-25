import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// The Subselect diamond and circle handles of polygons and stars (DRAW-010's remainder,
/// polygons-stars.adoc).
@Suite struct PolygonHandleTests {
    static func star(_ replica: inout Replica, at center: Point = Point(x: 100, y: 100)) throws -> OpID {
        try replica.perform(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 50, autoInner: true), center: center))!.createdObjects[0]
    }

    static func close(_ a: Point, _ b: Point) -> Bool { a.distance(to: b) < 1e-9 }

    @Test func handlesSitAtThePeakAndTheValleyInPasteboardSpace() throws {
        var a = Replica(0xA)
        let star = try Self.star(&a)
        let shape = PolygonShape(a.state.props(star).polygon)
        let positions = try #require(PolygonHandles.positions(of: star, in: a.state))
        let path = ShapeGeometry.polygonPath(shape).contours[0].drawn.map(\.anchor)
        #expect(Self.close(positions.peak, Point(x: 100 + path[0].x, y: 100 + path[0].y)))
        #expect(Self.close(try #require(positions.valley), Point(x: 100 + path[1].x, y: 100 + path[1].y)))
        #expect(PolygonHandles.hit(positions.peak, on: star, tolerance: 3, in: a.state) == .peak)
        #expect(PolygonHandles.hit(try #require(positions.valley), on: star, tolerance: 3, in: a.state) == .valley)
        #expect(PolygonHandles.hit(Point(x: 100, y: 100), on: star, tolerance: 3, in: a.state) == nil)
        // A plain polygon has no valley; anything else has no handles.
        let hexagon = try a.perform(CreatePolygon(PolygonShape(sides: 6, radius: 20), center: .zero))!.createdObjects[0]
        #expect(PolygonHandles.positions(of: hexagon, in: a.state)?.valley == nil)
        #expect(PolygonHandles.values(dragging: .valley, of: hexagon, to: .zero, keepAngle: false, in: a.state) == nil)
        #expect(PolygonHandles.positions(of: WellKnown.layers, in: a.state) == nil)
        #expect(PolygonHandles.hit(.zero, on: WellKnown.layers, tolerance: 3, in: a.state) == nil)
    }

    @Test func draggingTheDiamondSetsRadiusAndRotationAndShiftKeepsTheAngle() throws {
        var a = Replica(0xA)
        let star = try Self.star(&a)
        let command = try #require(PolygonHandles.drag(.peak, of: star, to: Point(x: 100, y: 180), keepAngle: false, in: a.state))
        let change = try #require(try a.perform(command))
        #expect(change.ops.count == 1 && change.label == "Change polygon")
        var props = a.state.props(star).polygon
        #expect(abs(props.radius - 80) < 1e-6 && abs(props.rotation - .pi / 2) < 1e-9)
        try a.perform(try #require(PolygonHandles.drag(.peak, of: star, to: Point(x: 130, y: 100), keepAngle: true, in: a.state)))
        props = a.state.props(star).polygon
        #expect(abs(props.radius - 30) < 1e-6 && abs(props.rotation - .pi / 2) < 1e-9, "Shift keeps the angle")
    }

    @Test func draggingTheCircleSetsTheInnerRadiusAndOffsetAndTurnsAutomaticOff() throws {
        var a = Replica(0xA)
        let star = try Self.star(&a)
        let shape = PolygonShape(a.state.props(star).polygon)
        // Straight out along valley 0's angle plus a tenth of a turn.
        let angle = shape.rotation + .pi / 5 + 0.2
        let target = Point(x: 100 + 10 * cos(angle), y: 100 + 10 * sin(angle))
        try a.perform(try #require(PolygonHandles.drag(.valley, of: star, to: target, keepAngle: false, in: a.state)))
        var props = a.state.props(star).polygon
        #expect(!props.autoInner && abs(props.innerRadius - 10) < 1e-6 && abs(props.valleyOffset - 0.2) < 1e-9)
        // Past the peaks: allowed.  With Shift the offset stays.
        try a.perform(try #require(PolygonHandles.drag(.valley, of: star, to: Point(x: 100, y: 190), keepAngle: true, in: a.state)))
        props = a.state.props(star).polygon
        #expect(abs(props.innerRadius - 90) < 1e-6 && abs(props.valleyOffset - 0.2) < 1e-9)
        #expect(abs(PolygonHandles.normalized(3 * .pi) - .pi) < 1e-12 && abs(PolygonHandles.normalized(-3 * .pi) - .pi) < 1e-12)
    }

    @Test func aTransformedPolygonDragsInItsLocalSpace() throws {
        var a = Replica(0xA)
        let star = try Self.star(&a, at: .zero)
        try a.perform(TransformObjects([star], matrix: .scale(x: 2, y: 2), about: .zero, kind: .scale))
        try a.perform(try #require(PolygonHandles.drag(.peak, of: star, to: Point(x: 100, y: 0), keepAngle: false, in: a.state)))
        #expect(abs(a.state.props(star).polygon.radius - 50) < 1e-6 && abs(a.state.props(star).polygon.rotation) < 1e-9)
    }

    @Test func diamondAndCircleDragsOnTwoReplicasBothStandAndUndoIsOneStep() throws {
        var pair = Pair()
        let star = try Self.star(&pair.a)
        pair.sync()
        try pair.a.perform(try #require(PolygonHandles.drag(.peak, of: star, to: Point(x: 170, y: 100), keepAngle: false, in: pair.a.state)))
        try pair.b.perform(try #require(PolygonHandles.drag(.valley, of: star, to: Point(x: 100, y: 112), keepAngle: true, in: pair.b.state)))
        pair.sync()
        #expect(StateHash.of(pair.a.state.store) == StateHash.of(pair.b.state.store))
        let props = pair.a.state.props(star).polygon
        #expect(abs(props.radius - 70) < 1e-6 && abs(props.innerRadius - 12) < 1e-6 && !props.autoInner)
        pair.a.undo()
        let undone = pair.a.state.props(star).polygon
        #expect(abs(undone.radius - 50) < 1e-6 && abs(undone.rotation - PolygonShape(sides: 5, radius: 50).rotation) < 1e-9 && abs(undone.innerRadius - 12) < 1e-6,
                "one undo restores the diamond's radius and rotation, leaving B's circle")
    }
}
