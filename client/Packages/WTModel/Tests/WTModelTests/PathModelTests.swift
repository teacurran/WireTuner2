import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

private func id(_ n: UInt64) -> OpID { OpID(counter: n, replica: 1) }

private func point(_ n: UInt64, _ x: Double, _ y: Double, in inHandle: Vector = .zero, out outHandle: Vector = .zero,
                   kind: PointKind = .corner, automatic: Bool = false) -> VectorPoint {
    VectorPoint(id: id(n), anchor: Point(x: x, y: y), inHandle: inHandle, outHandle: outHandle, kind: kind, automatic: automatic)
}

@Suite struct PathModelTests {
    let square = [point(1, 0, 0), point(2, 10, 0), point(3, 10, 10), point(4, 0, 10)]

    @Test func pointKindsRoundTrip() {
        for kind in PointKind.allCases {
            #expect(PointKind(kind.proto) == kind)
        }
        #expect(PointKind(.unspecified) == .corner)
    }

    @Test func storedPointsReadWithRetractedNonFiniteHandles() {
        var stored = Wiretuner_Doc_V1_PathPoint()
        stored.id = id(9).elementID
        stored.anchor.x = 1
        stored.anchor.y = 2
        stored.inHandle.x = .nan
        stored.outHandle.x = 3
        stored.kind = .curve
        stored.automatic = true
        let point = VectorPoint(stored)
        #expect(point.id == id(9))
        #expect(point.anchor == Point(x: 1, y: 2))
        #expect(point.inHandle == .zero)
        #expect(point.outHandle == Vector(dx: 3, dy: 0))
        #expect(point.kind == .curve && point.automatic)
        #expect(point.outControl == Point(x: 4, y: 2) && point.inControl == Point(x: 1, y: 2))
        #expect(point.swapped.inHandle == Vector(dx: 3, dy: 0))
        #expect(VectorPoint(Wiretuner_Doc_V1_PathPoint()).id == .zero)
    }

    @Test func handlesUnlinkedOnlyForNonCollinearCurvePoints() {
        #expect(!point(1, 0, 0, in: Vector(dx: -1, dy: 0), out: Vector(dx: 2, dy: 0), kind: .curve).handlesUnlinked)
        #expect(point(1, 0, 0, in: Vector(dx: -1, dy: 1), out: Vector(dx: 2, dy: 0), kind: .curve).handlesUnlinked)
        #expect(point(1, 0, 0, in: Vector(dx: 1, dy: 0), out: Vector(dx: 2, dy: 0), kind: .curve).handlesUnlinked)
        #expect(!point(1, 0, 0, in: Vector(dx: -1, dy: 1), out: Vector(dx: 2, dy: 0), kind: .corner).handlesUnlinked)
        #expect(!point(1, 0, 0, out: Vector(dx: 2, dy: 0), kind: .curve).handlesUnlinked)
    }

    @Test func drawnOrderHonoursReversedAndStart() {
        let handled = [point(1, 0, 0, out: Vector(dx: 1, dy: 0)), point(2, 10, 0, in: Vector(dx: -1, dy: 0)), point(3, 20, 0)]
        let reversed = VectorContour(id: id(100), reversed: true, points: handled)
        #expect(reversed.drawn.map(\.id) == [id(3), id(2), id(1)])
        #expect(reversed.drawn[1].outHandle == Vector(dx: -1, dy: 0))
        let started = VectorContour(start: id(3), points: square)
        #expect(started.drawn.map(\.id) == [id(3), id(4), id(1), id(2)])
        #expect(started.drawnIndex(of: id(1)) == 2)
        // A closed contour ignores start.
        #expect(VectorContour(closed: true, start: id(3), points: square).drawn.map(\.id) == [id(1), id(2), id(3), id(4)])
        // Reversed then rotated to the start in reading order.
        #expect(VectorContour(reversed: true, start: id(2), points: square).drawn.map(\.id) == [id(2), id(1), id(4), id(3)])
    }

    @Test func automaticHandlesComeFromTheNeighbours() {
        let points = [point(1, 0, 0, automatic: true), point(2, 6, 6, automatic: true), point(3, 12, 0, automatic: true)]
        let open = VectorContour(points: points).drawn
        #expect(open[0].inHandle == .zero && open[0].outHandle == Vector(dx: 2, dy: 2))
        #expect(open[1].outHandle == Vector(dx: 2, dy: 0) && open[1].inHandle == Vector(dx: -2, dy: 0))
        #expect(open[2].inHandle == Vector(dx: -2, dy: 2) && open[2].outHandle == .zero)
        let closed = VectorContour(closed: true, points: points).drawn
        #expect(closed[0].outHandle == Vector(dx: -1, dy: 1))
        #expect(VectorContour.automaticHandles([points[0]], 0, closed: false) == (Vector.zero, Vector.zero))
    }

    @Test func connectorsWithoutOneStraightSideReadAsCorners() {
        // Straight in, curved out: a valid connector.
        let valid = [point(1, 0, 0), point(2, 10, 0, out: Vector(dx: 3, dy: 0), kind: .connector), point(3, 20, 5, in: Vector(dx: -2, dy: 0))]
        #expect(VectorContour(points: valid).drawn[1].kind == .connector)
        // Both sides straight.
        let straight = [point(1, 0, 0), point(2, 10, 0, kind: .connector), point(3, 20, 5)]
        #expect(VectorContour(points: straight).drawn[1].kind == .corner)
        // At an open end there is only one side.
        let end = [point(1, 0, 0, kind: .connector), point(2, 10, 0)]
        #expect(VectorContour(points: end).drawn[0].kind == .corner)
        // Closed: the first point has two sides.
        let closed = [point(1, 0, 0, out: Vector(dx: 3, dy: 0), kind: .connector), point(2, 10, 0, in: Vector(dx: -1, dy: 0)), point(3, 5, 5)]
        #expect(VectorContour(closed: true, points: closed).drawn[0].kind == .connector)
    }

    @Test func segmentsEndsAndRenderability() {
        let open = VectorContour(points: square)
        #expect(open.segments.count == 3)
        #expect(open.ends?.first.id == id(1) && open.ends?.last.id == id(4))
        let closed = VectorContour(closed: true, points: square)
        #expect(closed.segments.count == 4)
        #expect(closed.segments.last?.from.id == id(4) && closed.segments.last?.to.id == id(1))
        #expect(closed.ends == nil)
        #expect(closed.segments[0].isStraight)
        let curve = VectorSegment(from: point(1, 0, 0, out: Vector(dx: 1, dy: 0)), to: point(2, 10, 0))
        #expect(!curve.isStraight)
        #expect(curve.cubic.p1 == Point(x: 1, y: 0))
        let single = VectorContour(points: [square[0]])
        #expect(!single.isRenderable && single.segments.isEmpty && !single.isFull)
        #expect(VectorContour(points: []).ends == nil)
    }

    @Test func pathSummaries() {
        let path = VectorPath(contours: [VectorContour(id: id(50), closed: true, points: square), VectorContour(id: id(51), points: [square[0]])])
        #expect(path.pointCount == 5)
        #expect(path.isRenderable)
        #expect(path.contour(id(51))?.points.count == 1)
        #expect(path.contour(id(52)) == nil)
        #expect(path.allPoints.count == 5 && path.allPoints[4].contour == id(51))
        #expect(path.controlBounds == Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(VectorPath(contours: [VectorContour(points: [square[0]])]).controlBounds == nil)
        #expect(!VectorPath(contours: []).isRenderable)
    }

    @Test func propsReadWithoutStateLeaveADanglingStartUnset() {
        var props = Wiretuner_Doc_V1_PathProps()
        var contour = Wiretuner_Doc_V1_Contour()
        contour.id = id(50).elementID
        contour.start = id(99).elementID
        var p = Wiretuner_Doc_V1_PathPoint()
        p.id = id(1).elementID
        contour.points = [p]
        props.contours = [contour]
        props.evenOdd = true
        props.flatness = 2
        props.fillWhenOpen = true
        let path = VectorPath(props)
        #expect(path.contours[0].start == nil)
        #expect(path.evenOdd && path.flatness == 2 && path.fillWhenOpen)
    }

    @Test func aDeletedStartReadsAsTheNextSurvivor() throws {
        var replica = Replica(3)
        let (node, contour) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0), (20, 0), (30, 0)])), in: replica.state)
        let points = replica.path(node).contours[0].points.map(\.id)
        try replica.perform(DeleteSegment(node: node, contour: contour, from: points[2]))   // open contour: removes the end point
        try replica.perform(SetClosed(node: node, closed: true))
        try replica.perform(DeleteSegment(node: node, contour: contour, from: points[1]))   // closed: start = points[2]
        #expect(replica.path(node).contours[0].start == points[2])
        try replica.perform(DeletePoints(node: node, points: [(contour, points[2])]))
        let read = replica.path(node).contours[0]
        // points[3] was deleted too, so the survivor after points[2] cycles round to points[0].
        #expect(read.start == points[0])
        #expect(read.drawn.map(\.id) == [points[0], points[1]])
        // Every point but one gone: no survivor.
        try replica.perform(DeletePoints(node: node, points: [(contour, points[0])]))
        try replica.perform(DeletePoints(node: node, points: [(contour, points[1])]))
        #expect(replica.path(node).contours[0].start == nil)
    }

    @Test func anUnknownStartIsUnset() throws {
        var replica = Replica(3)
        let (node, contour) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0)])), in: replica.state)
        var value = Wiretuner_Doc_V1_Contour()
        value.start = OpID(counter: 999, replica: 9).elementID
        try replica.perform(OpsCommand("x", ops: [Ops.set(node, [PathFields.start(contour)], values: PathEditing.contourValues(value))]))
        #expect(replica.path(node).contours[0].start == nil)
    }
}

@Suite struct ShapeGeometryTests {
    static func close(_ a: Point, _ b: Point) -> Bool { a.distance(to: b) < 0.01 }

    @Test func squareRectangleIsFourCornersClockwiseFromTopLeft() {
        let path = ShapeGeometry.rectPath(size: Size(width: 40, height: 20))
        let contour = path.contours[0]
        #expect(contour.closed)
        #expect(contour.points.map(\.anchor) == [Point(x: 0, y: 0), Point(x: 40, y: 0), Point(x: 40, y: 20), Point(x: 0, y: 20)])
        #expect(contour.points.map(\.id) == (1...4).map { OpID(counter: UInt64($0), replica: 0) })
        #expect(contour.segments.allSatisfy { $0.isStraight })
    }

    @Test func roundedCornersAreQuarterCircleCubics() {
        let path = ShapeGeometry.rectPath(size: Size(width: 40, height: 20), radii: .uniform(5))
        let points = path.contours[0].points
        let expected = [(0.0, 5.0), (5.0, 0.0), (35.0, 0.0), (40.0, 5.0), (40.0, 15.0), (35.0, 20.0), (5.0, 20.0), (0.0, 15.0)]
        #expect(points.count == 8)
        for (point, (x, y)) in zip(points, expected) {
            #expect(Self.close(point.anchor, Point(x: x, y: y)))
        }
        let k = ShapeGeometry.kappa * 5
        #expect(Self.close(points[0].outControl, Point(x: 0, y: 5 - k)))
        #expect(Self.close(points[1].inControl, Point(x: 5 - k, y: 0)))
        // The arc's midpoint lies on the circle.
        let mid = VectorSegment(from: points[0], to: points[1]).cubic.evaluate(0.5)
        #expect(abs(mid.distance(to: Point(x: 5, y: 5)) - 5) < 0.01)
        // Mixed: one rounded corner.
        #expect(ShapeGeometry.rectPath(size: Size(width: 40, height: 20), radii: CornerRadii(topRight: 3)).contours[0].points.count == 5)
    }

    @Test func ellipseIsFourCurvePointsClockwiseFromTheTop() {
        let points = ShapeGeometry.ellipsePath(size: Size(width: 20, height: 10)).contours[0].points
        #expect(points.map(\.anchor) == [Point(x: 10, y: 0), Point(x: 20, y: 5), Point(x: 10, y: 10), Point(x: 0, y: 5)])
        #expect(points.allSatisfy { $0.kind == .curve })
        let mid = VectorSegment(from: points[0], to: points[1]).cubic.evaluate(0.5)
        let angle = Double.pi / 4
        #expect(Self.close(mid, Point(x: 10 + 10 * cos(angle), y: 5 - 5 * sin(angle))) || mid.distance(to: Point(x: 10 + 10 * cos(angle), y: 5 - 5 * sin(angle))) < 0.02)
    }

    @Test func degenerateSizesRenderNothing() {
        #expect(ShapeGeometry.rectPath(size: Size(width: 0, height: 5)).contours.isEmpty)
        #expect(ShapeGeometry.rectPath(size: Size(width: .infinity, height: 5)).contours.isEmpty)
        #expect(ShapeGeometry.ellipsePath(size: Size(width: 5, height: -1)).contours.isEmpty)
        #expect(ShapeGeometry.ellipsePath(size: Size(width: 5, height: .nan)).contours.isEmpty)
    }

    @Test func radiiClampAndUniformRule() {
        var corners = Wiretuner_Doc_V1_CornerRadii()
        corners.uniform = true
        corners.topLeft = 50
        corners.topRight = 1
        #expect(CornerRadii(corners, size: Size(width: 40, height: 20)) == .uniform(10))
        corners.uniform = false
        corners.bottomRight = -3
        corners.bottomLeft = .nan
        #expect(CornerRadii(corners, size: Size(width: 40, height: 20)) == CornerRadii(topLeft: 10, topRight: 1, bottomRight: 0, bottomLeft: 0))
        var rect = Wiretuner_Doc_V1_RectProps()
        rect.size.width = 10
        rect.size.height = 10
        #expect(ShapeGeometry.path(rect).contours[0].points.count == 4)
        var ellipse = Wiretuner_Doc_V1_EllipseProps()
        ellipse.size.width = 10
        ellipse.size.height = 10
        #expect(ShapeGeometry.path(ellipse).contours[0].points.count == 4)
    }

    @Test func mergedRadiiLargerThanTheShapeAreClamped() throws {
        var pair = Pair()
        let change = try pair.a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 100, height: 100)))
        let node = change!.createdObjects[0]
        pair.sync()
        // A shrinks the rectangle while B rounds a corner hard.
        try pair.a.perform(SetShapeSize(node: node, size: Size(width: 20, height: 10)))
        var corners = Wiretuner_Doc_V1_NodeProps()
        corners.rect.corners.topLeft = 40
        try pair.b.perform(OpsCommand("Radius", ops: [Ops.set(node, [ShapeFields.corners.child(2)], values: corners)]))
        pair.sync()
        for replica in [pair.a, pair.b] {
            let rect = replica.state.props(node).rect
            #expect(rect.size.width == 20 && rect.corners.topLeft == 40)
            #expect(CornerRadii(rect.corners, size: Size(width: 20, height: 10)).topLeft == 5)
            #expect(rect.corners.uniform && ShapeGeometry.path(rect).contours[0].points.count == 8)
        }
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }
}

@Suite struct AppearanceTests {
    @Test func standardIsABlackPointStroke() {
        let resolved = Appearances.resolve(Appearances.standard)
        guard case .stroke(let stroke) = resolved.items.first else { Issue.record("no stroke"); return }
        #expect(resolved.items.count == 1)
        #expect(stroke.paint == .solid(Color(red: 0, green: 0, blue: 0)))
        #expect(stroke.style.width == 1 && stroke.style.cap == .butt && stroke.style.join == .miter && stroke.style.miterLimit == 10)
    }

    @Test func fillsAndStrokesResolveBottomFirst() {
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        var hidden = Appearances.basicFill(red: 1, green: 0, blue: 0)
        hidden.hidden = true
        var gradient = Wiretuner_Doc_V1_Fill()
        gradient.settings.kind = .gradient
        var overprint = Appearances.basicFill(red: 0, green: 1, blue: 0)
        overprint.settings.basic.overprint = true
        appearance.fills = [hidden, gradient, overprint]
        var stroke = Appearances.basicStroke(red: 0, green: 0, blue: 1, width: .infinity)
        stroke.settings.basic.cap = .round
        stroke.settings.basic.join = .bevel
        stroke.settings.basic.miterLimit = 4
        stroke.settings.basic.dash.lengths = [2, 1]
        var square = Appearances.basicStroke(red: 0, green: 0, blue: 0, width: -1)
        square.settings.basic.cap = .square
        square.settings.basic.join = .round
        var hiddenStroke = square
        hiddenStroke.hidden = true
        var brush = Wiretuner_Doc_V1_Stroke()
        brush.settings.kind = .brush
        appearance.strokes = [stroke, square, hiddenStroke, brush]
        let resolved = Appearances.resolve(appearance, evenOdd: true)
        #expect(resolved.items.count == 3)
        guard case .fill(let fill) = resolved.items[0], case .stroke(let first) = resolved.items[1], case .stroke(let second) = resolved.items[2] else {
            Issue.record("order"); return
        }
        #expect(fill.rule == .evenOdd && fill.overprint && fill.paint == .solid(Color(red: 0, green: 1, blue: 0)))
        #expect(first.style.width == 1 && first.style.cap == .round && first.style.join == .bevel && first.style.miterLimit == 4 && first.style.dash == [2, 1])
        #expect(second.style.width == 0 && second.style.cap == .square && second.style.join == .round)
        #expect(Appearances.resolve(appearance, paintsFill: false).items.count == 2)
        guard case .fill(let nonZero) = Appearances.resolve(appearance).items[0] else { return }
        #expect(nonZero.rule == .nonZero)
    }

    @Test func colourReferencesResolve() throws {
        var none = Wiretuner_Doc_V1_ColorRef()
        none.none = true
        #expect(Appearances.paint(none) == .none)
        #expect(Appearances.paint(Wiretuner_Doc_V1_ColorRef()) == .solid(.black))
        var cached = Wiretuner_Doc_V1_Color()
        cached.rgb.r = 1
        var swatch = Wiretuner_Doc_V1_ColorRef()
        swatch.swatch.cached = try cached.serializedData()
        #expect(Appearances.paint(swatch) == .solid(Color(red: 1, green: 0, blue: 0)))
        var badSwatch = Wiretuner_Doc_V1_ColorRef()
        badSwatch.swatch.cached = Data([0xFF, 0xFF])
        #expect(Appearances.paint(badSwatch) == .solid(.black))
        var tint = Wiretuner_Doc_V1_ColorRef()
        tint.tint.base.cached = try cached.serializedData()
        tint.tint.percent = 50
        #expect(Appearances.paint(tint) == .solid(Color(red: 1, green: 0.5, blue: 0.5)))
        var cmyk = Wiretuner_Doc_V1_Color()
        cmyk.cmyk.c = 1
        cmyk.cmyk.k = 0.5
        #expect(Appearances.color(cmyk) == Color(red: 0, green: 0.5, blue: 0.5))
        var lab = Wiretuner_Doc_V1_Color()
        lab.lab.l = 50
        #expect(Appearances.color(lab) == Color(white: 0.5))
        #expect(Appearances.color(Wiretuner_Doc_V1_Color()) == .black)
    }
}
