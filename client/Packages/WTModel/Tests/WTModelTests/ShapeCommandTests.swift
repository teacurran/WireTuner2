import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Polygons and stars (DRAW-010 to DRAW-012), rectangle corners and sizes (DRAW-009), spirals and
/// arcs (DRAW-013).
@Suite struct PolygonGeometryTests {
    @Test func outlinesMatchTheReferenceCoordinates() {
        for n in [3, 5, 6, 12, 360] {
            let path = ShapeGeometry.polygonPath(PolygonShape(sides: n, radius: 50))
            let points = path.contours[0].points
            #expect(points.count == n)
            #expect(path.contours[0].closed)
            for (k, point) in points.enumerated() {
                let angle = 2 * Double.pi * Double(k) / Double(n)
                #expect(point.anchor.distance(to: Point(x: 50 * cos(angle), y: 50 * sin(angle))) < 0.01)
                #expect(point.kind == .corner && point.id == OpID(counter: UInt64(k + 1), replica: 0))
            }
        }
        // Automatic 5- and 6-point stars.
        let five = ShapeGeometry.polygonPath(PolygonShape(sides: 5, star: true, radius: 50, autoInner: true)).contours[0].points
        #expect(five.count == 10)
        #expect(abs(five[1].anchor.distance(to: .zero) - 50 * cos(2 * .pi / 5) / cos(.pi / 5)) < 0.01)
        #expect(five[1].anchor.distance(to: Point(x: 19.098 * cos(.pi / 5), y: 19.098 * sin(.pi / 5))) < 0.01)
        let six = ShapeGeometry.polygonPath(PolygonShape(sides: 6, star: true, radius: 50, autoInner: true)).contours[0].points
        #expect(six.count == 12 && abs(six[1].anchor.distance(to: .zero) - 25) < 0.01)
    }

    @Test func readTimeRules() {
        #expect(PolygonShape(sides: 0, radius: 1).sides == 3)
        #expect(PolygonShape(sides: 1000, radius: 1).sides == 360)
        #expect(PolygonShape(sides: 5, radius: .nan).radius == 0)
        #expect(ShapeGeometry.polygonPath(PolygonShape(sides: 5, radius: 0)).contours.isEmpty)
        #expect(PolygonShape.automaticInnerRadius(sides: 3, radius: 10) == 0)
        let manual = PolygonShape(sides: 5, star: true, radius: 10, innerRadius: -3, sharpness: 2, rotation: .infinity, valleyOffset: .nan)
        #expect(manual.innerRadius == 0 && manual.sharpness == 1 && manual.rotation == 0 && manual.valleyOffset == 0)
        #expect(PolygonShape(sides: 5, radius: 10, innerRadius: .nan).innerRadius == 0)
        #expect(PolygonShape(sides: 5, radius: 10, sharpness: .nan).sharpness == 0)
        #expect(abs(PolygonShape.innerRadius(sharpness: 0, sides: 4, radius: 10) - 1) < 1e-9)
        #expect(abs(PolygonShape.innerRadius(sharpness: 1, sides: 4, radius: 10) - 10 * cos(.pi / 4)) < 1e-9)
        // A valley offset and rotation move the points.
        let turned = ShapeGeometry.polygonPath(PolygonShape(sides: 4, star: true, radius: 10, innerRadius: 5, rotation: .pi / 2, valleyOffset: 0.1))
        #expect(turned.contours[0].points[0].anchor.distance(to: Point(x: 0, y: 10)) < 1e-9)
        let valley = .pi / 2 + .pi / 4 + 0.1
        #expect(turned.contours[0].points[1].anchor.distance(to: Point(x: 5 * cos(valley), y: 5 * sin(valley))) < 1e-9)
    }
}

@Suite struct PolygonCommandTests {
    @Test func createReadsBackAsAPolygonNode() throws {
        var a = Replica(0xA)
        let change = try a.perform(CreatePolygon(PolygonShape(sides: 6, radius: 20, rotation: 0.25), center: Point(x: 100, y: 50)))!
        #expect(change.label == "Polygon")
        #expect(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 1), center: .zero).label == "Star")
        let node = change.createdObjects[0]
        let props = a.state.props(node).polygon
        #expect(props.sides == 6 && props.radius == 20 && props.rotation == 0.25)
        #expect(Objects.transform(of: node, in: a.state) == .translation(x: 100, y: 50))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        #expect(scene.object(node)?.kind == .polygon)
        #expect(scene.object(node)?.path?.contours[0].points.count == 6)
        #expect(throws: PathEditError.invalidValue("radius")) { try a.perform(CreatePolygon(PolygonShape(sides: 5, radius: 0), center: .zero)) }
    }

    @Test func fieldEditsWriteOneRegisterEach() throws {
        var a = Replica(0xA)
        let node = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 5, radius: 10), center: .zero), on: &a)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let change = try a.perform(SetPolygonFields([node, rect], .init(sides: 400, star: true, radius: 12.0004, innerRadius: -1, autoInner: true,
                                                                         rotation: 1, valleyOffset: 0.2)))!
        #expect(change.label == "Change polygon of 2 objects")
        #expect(change.ops.count == 1)
        let props = a.state.props(node).polygon
        #expect(props.sides == 360 && props.star && props.radius == 12 && props.innerRadius == 0 && props.autoInner)
        #expect(props.rotation == 1 && props.valleyOffset == 0.2)
        #expect(SetPolygonFields([node], .init(sides: 3), label: "Change sides").label == "Change sides")
        #expect(SetPolygonFields([node], .init()).label == "Change polygon")
        #expect(try a.perform(SetPolygonFields([node], .init())) == nil)
        #expect(throws: PathEditError.invalidValue("polygon")) { try a.perform(SetPolygonFields([node], .init(radius: .nan))) }
        // Undo of a handle drag restores both registers it wrote.
        try a.perform(SetPolygonFields([node], .init(radius: 30, rotation: 2)))
        a.undo()
        #expect(a.state.props(node).polygon.radius == 12 && a.state.props(node).polygon.rotation == 1)
    }
}

@Suite struct RectangleCommandTests {
    @Test func cornerRadiiUniformAndSize() throws {
        var a = Replica(0xA)
        let rects = try (0..<3).map { i in
            try LayerFixture.object(CreateShape(.rectangle(.uniform(Double(i))), size: Size(width: 20, height: 20)), on: &a)
        }
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 5, height: 5)), on: &a)
        let change = try a.perform(SetCornerRadius(rects + [ellipse], radius: 4, uniform: true))!
        #expect(change.label == "Change corner radius of 4 objects")
        #expect(change.ops.count == 3)
        #expect(rects.allSatisfy { a.state.props($0).rect.corners.topLeft == 4 && a.state.props($0).rect.corners.bottomLeft == 4 })
        try a.perform(SetCornerRadius([rects[0]], radius: 1, corners: [.topRight], uniform: false))
        let corners = a.state.props(rects[0]).rect.corners
        #expect(!corners.uniform && corners.topRight == 1 && corners.topLeft == 4)
        #expect(SetCornerRadius([rects[0]], radius: 1).label == "Change corner radius")
        #expect(try a.perform(SetCornerRadius([rects[0]], radius: nil)) == nil)
        try a.perform(SetCornerRadius([rects[1]], radius: nil, uniform: false))
        #expect(throws: PathEditError.invalidValue("radius")) { try a.perform(SetCornerRadius(rects, radius: -1)) }
        // Sizes: W alone keeps H.
        let resize = try a.perform(SetShapesSize([rects[0], ellipse], width: 30.00049))!
        #expect(resize.label == "Resize 2 objects")
        #expect(SetShapesSize([ellipse]).label == "Resize")
        #expect(a.state.props(rects[0]).rect.size.width == 30 && a.state.props(rects[0]).rect.size.height == 20)
        try a.perform(SetShapesSize([ellipse], height: 9))
        #expect(a.state.props(ellipse).ellipse.size.height == 9 && a.state.props(ellipse).ellipse.size.width == 30)
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (1, 1)]), on: &a)
        #expect(try a.perform(SetShapesSize([path], width: 3)) == nil)
    }
}

@Suite struct SpiralArcTests {
    @Test func aThreeRotationSpiralHasThirteenPointsFromTheCentre() {
        let center = Point(x: 100, y: 100), outer = Point(x: 160, y: 100)
        let path = ShapeGeometry.spiralPath(SpiralOptions(), center: center, outer: outer)
        let points = path.contours[0].drawn
        #expect(points.count == 13)
        #expect(!path.contours[0].closed)
        #expect(points[0].anchor.distance(to: center) < 1e-9)
        #expect(points[12].anchor.distance(to: outer) < 1e-9)
        // Archimedean: the radius at quarter turn k is k/12 of the outer radius.
        for (k, point) in points.enumerated() {
            let expected = 60 * Double(k) / 12
            #expect(abs(point.anchor.distance(to: center) - expected) <= max(expected * 0.001, 1e-9))
        }
        #expect(points.dropFirst().dropLast().allSatisfy { $0.kind == .curve })
    }

    @Test func expandingSpiralsGrowByTheRate() {
        let center = Point.zero, outer = Point(x: 0, y: 80)
        let options = SpiralOptions(kind: .expanding, rotations: 2, expansion: 50, clockwise: false)
        let points = ShapeGeometry.spiralPath(options, center: center, outer: outer).contours[0].drawn
        #expect(points.count == 9)
        let radii = points.map { $0.anchor.distance(to: center) }
        #expect(abs(radii[8] - 80) < 1e-9)
        for k in 0..<4 {
            #expect(abs(radii[k + 4] / radii[k] - 1.5) < 0.001)   // one turn is 50% wider
        }
    }

    @Test func drawingByIncrementsAddsTurnsWithDistance() {
        let concentric = ShapeGeometry.spiralPath(SpiralOptions(drawBy: .increments, incrementWidth: 10), center: .zero, outer: Point(x: 30, y: 0))
        #expect(concentric.contours[0].points.count == 13)   // three turns of 10 pt
        let partial = ShapeGeometry.spiralPath(SpiralOptions(drawBy: .increments, incrementWidth: 10), center: .zero, outer: Point(x: 35, y: 0))
        #expect(partial.contours[0].points.count == 15)      // 3.5 turns: 14 quarter turns, 15 points
        let expanding = ShapeGeometry.spiralPath(SpiralOptions(kind: .expanding, drawBy: .increments, startingRadius: 5, expansion: 100),
                                                 center: .zero, outer: Point(x: 40, y: 0))
        let radii = expanding.contours[0].drawn.map { $0.anchor.distance(to: .zero) }
        #expect(abs(radii[0] - 5) < 1e-6 && abs(radii.last! - 40) < 1e-9)
        #expect(ShapeGeometry.spiralPath(SpiralOptions(), center: .zero, outer: .zero).contours.isEmpty)
    }

    @Test func quarterTurnHandlesFollowACircleOfConstantRadius() {
        // Far from the centre an Archimedean turn is nearly circular: the handles approach kappa × r.
        let path = ShapeGeometry.spiralPath(SpiralOptions(rotations: 100), center: .zero, outer: Point(x: 1000, y: 0))
        let last = path.contours[0].drawn.last!
        #expect(abs(last.inHandle.length / 1000 - ShapeGeometry.kappa) < 0.01)
    }

    @Test func arcsOpenClosedFlippedAndConcave() {
        let start = Point(x: 0, y: 0), end = Point(x: 40, y: 20)
        for open in [true, false] {
            for flipped in [true, false] {
                for concave in [true, false] {
                    let path = ShapeGeometry.arcPath(from: start, to: end, open: open, flipped: flipped, concave: concave)
                    let contour = path.contours[0]
                    #expect(contour.points.count == (open ? 2 : 3))
                    #expect(contour.closed == !open)
                    #expect(contour.points[0].anchor == start && contour.points[1].anchor == end)
                    // The curve's tangents run along the box sides.
                    let out = contour.points[0].outHandle, arriving = contour.points[1].inHandle
                    #expect((out.dx == 0) != (out.dy == 0) && (arriving.dx == 0) != (arriving.dy == 0))
                    #expect(abs(max(abs(out.dx), abs(out.dy)) - ShapeGeometry.kappa * (out.dx == 0 ? 20 : 40)) < 1e-9)
                    if !open {
                        #expect(contour.points[2].anchor == (flipped ? Point(x: 40, y: 0) : Point(x: 0, y: 20)))
                    }
                }
            }
        }
        // Unflipped and convex: from the start horizontally, arriving vertically (bulging away from
        // the corner below the start).
        let plain = ShapeGeometry.arcPath(from: start, to: end, open: true, flipped: false, concave: false).contours[0]
        #expect(plain.points[0].outHandle.dy == 0 && plain.points[0].outHandle.dx > 0)
        let concave = ShapeGeometry.arcPath(from: start, to: end, open: true, flipped: false, concave: true).contours[0]
        #expect(concave.points[0].outHandle.dx == 0 && concave.points[0].outHandle.dy > 0)
        #expect(ShapeGeometry.arcPath(from: start, to: Point(x: 0, y: 5), open: true, flipped: false, concave: false).contours.isEmpty)
    }
}

/// The merge tests of DRAW-011, DRAW-012, DRAW-014 and DRAW-015.
@Suite struct ShapeMergeTests {
    @Test func sidesAndRadiusChangedConcurrentlyAreBothPresent() throws {
        var pair = Pair()
        let node = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 5, radius: 10), center: .zero), on: &pair.a)
        pair.sync()
        try pair.a.perform(SetPolygonFields([node], .init(sides: 8)))
        try pair.b.perform(SetPolygonFields([node], .init(radius: 25)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let props = pair.b.state.props(node).polygon
        #expect(props.sides == 8 && props.radius == 25)
    }

    @Test func diamondAndCircleDragsBothSurvive() throws {
        var pair = Pair()
        let node = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 10, innerRadius: 4), center: .zero), on: &pair.a)
        pair.sync()
        try pair.a.perform(SetPolygonFields([node], .init(radius: 12, rotation: 0.1)))
        try pair.b.perform(SetPolygonFields([node], .init(innerRadius: 6, valleyOffset: 0.2)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let props = pair.a.state.props(node).polygon
        #expect(props.radius == 12 && props.rotation == 0.1 && props.innerRadius == 6 && props.valleyOffset == 0.2)
    }

    @Test func concurrentSpiralsAndArcsBothExist() throws {
        var pair = Pair()
        let spiral = ShapeGeometry.spiralPath(SpiralOptions(), center: .zero, outer: Point(x: 50, y: 0))
        let arc = ShapeGeometry.arcPath(from: .zero, to: Point(x: 10, y: 10), open: false, flipped: false, concave: false)
        let a = try pair.a.perform(CreatePath(label: "Draw spiral", contours: spiral.contours.map { NewContour(closed: $0.closed, points: $0.points) }))!
        let b = try pair.b.perform(CreatePath(label: "Arc", contours: arc.contours.map { NewContour(closed: $0.closed, points: $0.points) }))!
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.isLive(a.createdObjects[0]) && pair.a.state.isLive(b.createdObjects[0]))
        #expect(a.label == "Draw spiral")
    }
}
