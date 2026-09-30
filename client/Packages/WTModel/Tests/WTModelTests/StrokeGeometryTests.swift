import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel

/// The stroke and cutting geometry the drawing tools share (D-073: in WTModel so the iPad app can
/// reuse it): path points from contours, the Variable Stroke and Calligraphic Pens' outlines
/// (DRAW-018, DRAW-019), cutting contours apart (DRAW-028), the Eraser's strip (DRAW-029) and the
/// Freeform tool's deformations (DRAW-027).
enum StrokeGeometry {
    /// Distances from y = 50 of the outline's points between `minX` and `maxX` (a stroke drawn
    /// along y = 50).
    static func halfWidths(_ contour: Contour, from minX: Double, to maxX: Double) -> [Double] {
        contour.segments.flatMap { segment in
            stride(from: 0.0, through: 1.0, by: 0.05).map { segment.evaluate($0) }
        }.filter { $0.x > minX && $0.x < maxX }.map { abs($0.y - 50) }
    }

    static func line(_ xs: [Double], y: Double = 0) -> [VectorPoint] {
        xs.map { VectorPoint(anchor: Point(x: $0, y: y)) }
    }

    static func square(replica: UInt64 = 3, size: Double = 10) -> [VectorPoint] {
        [Point(x: 0, y: 0), Point(x: size, y: 0), Point(x: size, y: size), Point(x: 0, y: size)].enumerated().map { index, point in
            VectorPoint(id: OpID(counter: UInt64(index + 1), replica: replica), anchor: point)
        }
    }
}

@Suite struct ContourPointsTests {
    @Test func contoursBecomePathPoints() {
        // A closed contour that does not end where it began gets its closing point.
        let open = Contour(segments: [CubicBezier(line: Line(start: .zero, end: Point(x: 10, y: 0))), CubicBezier(line: Line(start: Point(x: 10, y: 0), end: Point(x: 10, y: 10)))], closed: true)
        #expect(ContourPoints.points(open).count == 3)
        let degenerate = Contour(segments: [CubicBezier(line: Line(start: .zero, end: .zero)), CubicBezier(line: Line(start: .zero, end: Point(x: 5, y: 0)))], closed: false)
        #expect(ContourPoints.points(degenerate).count == 2, "a zero-length segment is dropped")
        #expect(ContourPoints.points(Contour(segments: [], closed: true)).isEmpty && ContourPoints.segments([], closed: false).isEmpty)
        // A closed ring ending where it began: one point per segment, the first taking its in
        // handle from the closing segment.
        let ring = Contour(segments: ContourPoints.segments(StrokeGeometry.square(), closed: true), closed: true)
        let points = ContourPoints.points(ring)
        #expect(points.map(\.anchor) == StrokeGeometry.square().map(\.anchor))
        #expect(points.allSatisfy { $0.kind == .corner })
    }

    @Test func collinearHandlesMakeCurvePoints() {
        let s = [CubicBezier(p0: .zero, p1: Point(x: 0, y: 10), p2: Point(x: 10, y: 10), p3: Point(x: 20, y: 10)),
                 CubicBezier(p0: Point(x: 20, y: 10), p1: Point(x: 30, y: 10), p2: Point(x: 40, y: 10), p3: Point(x: 40, y: 0))]
        let points = ContourPoints.points(Contour(segments: s, closed: false))
        #expect(points.map(\.kind) == [.corner, .curve, .corner])
        #expect(points[1].inHandle == Vector(dx: -10, dy: 0) && points[1].outHandle == Vector(dx: 10, dy: 0))
        #expect(ContourPoints.smooth(Vector(dx: -1, dy: 0), Vector(dx: 1, dy: 0)))
        #expect(!ContourPoints.smooth(.zero, Vector(dx: 1, dy: 0)) && !ContourPoints.smooth(Vector(dx: 0, dy: 1), Vector(dx: 1, dy: 0)))
        // Round trip: the segments of the points are the contour's.
        #expect(ContourPoints.segments(points, closed: false) == s)
        #expect(ContourPoints.segments(points, closed: true).count == 3)
        #expect(ContourPoints.segments([points[0]], closed: true).isEmpty)
    }
}

@Suite struct VariableStrokeOutlineTests {
    typealias Sample = VariableStrokeOutline.Sample

    @Test func widthsInterpolateAlongTheSamples() {
        let samples = [Sample(point: Point(x: 0, y: 0), width: 2), Sample(point: Point(x: 10, y: 0), width: 12)]
        #expect(VariableStrokeOutline.width(at: 0.5, samples: samples) == 7)
        #expect(VariableStrokeOutline.width(at: 2, samples: samples) == 12 && VariableStrokeOutline.width(at: 0, samples: []) == 0)
        #expect(VariableStrokeOutline.width(at: -1, samples: samples) == 2)
        #expect(VariableStrokeOutline.width(at: 0.3, samples: [samples[0]]) == 2)
        #expect(VariableStrokeOutline.width(at: 0.3, samples: [samples[0], samples[0]]) == 2)
        // A repeated sample (a zero-length span) is passed over.
        let repeated = [samples[0], samples[0], samples[1]]
        #expect(VariableStrokeOutline.width(at: 0.5, samples: repeated) == 7)
        #expect(VariableStrokeOutline.width(at: 0, samples: repeated) == 2)
    }

    @Test func aConstantWidthHoldsAlongTheStroke() throws {
        let centerline = StrokeGeometry.line([0, 200], y: 50)
        let samples = [Sample(point: Point(x: 0, y: 50), width: 6), Sample(point: Point(x: 200, y: 50), width: 6)]
        let outline = try #require(VariableStrokeOutline.outline(centerline: centerline, samples: samples))
        #expect(outline.isClosed)
        let widths = StrokeGeometry.halfWidths(outline, from: 10, to: 190).map { $0 * 2 }
        #expect(!widths.isEmpty && widths.allSatisfy { abs($0 - 6) < 0.1 })
        // The round caps reach half a width past each end.
        let xs = outline.segments.flatMap { s in stride(from: 0.0, through: 1.0, by: 0.05).map { s.evaluate($0).x } }
        #expect(abs(xs.min()! + 3) < 0.1 && abs(xs.max()! - 203) < 0.1)
        // A widening stroke is wider at its end.
        let widening = [Sample(point: Point(x: 0, y: 50), width: 2), Sample(point: Point(x: 200, y: 50), width: 12)]
        let wide = try #require(VariableStrokeOutline.outline(centerline: centerline, samples: widening))
        #expect(StrokeGeometry.halfWidths(wide, from: 170, to: 190).allSatisfy { $0 > 4.5 })
        #expect(StrokeGeometry.halfWidths(wide, from: 10, to: 30).allSatisfy { $0 < 2 })
    }

    @Test func strokesThatCannotBeDrawn() {
        let samples = [Sample(point: .zero, width: 4), Sample(point: Point(x: 50, y: 0), width: 4)]
        let point = VectorPoint(anchor: Point(x: 5, y: 5))
        #expect(VariableStrokeOutline.outline(centerline: [], samples: samples) == nil)
        #expect(VariableStrokeOutline.outline(centerline: [point, point], samples: samples) == nil, "no length")
        #expect(VariableStrokeOutline.outline(centerline: StrokeGeometry.line([0, 50]), samples: samples.map { Sample(point: $0.point, width: 0) }) == nil, "no width")
        let kinked = StrokeGeometry.line([0, 20, 20, 40])
        #expect(VariableStrokeOutline.outline(centerline: kinked, samples: samples) != nil, "a zero-length segment inside is skipped")
    }

    @Test func capsBulgeForwardAndCuspsKeepTheirDirection() {
        let forward = VariableStrokeOutline.cap(center: .zero, from: Point(x: 0, y: 5), forward: Vector(dx: 1, dy: 0))
        let backward = VariableStrokeOutline.cap(center: .zero, from: Point(x: 0, y: 5), forward: Vector(dx: -1, dy: 0))
        #expect(!forward.isEmpty && forward.allSatisfy { $0.x >= -1e-9 } && backward.allSatisfy { $0.x <= 1e-9 })
        #expect(forward.allSatisfy { abs($0.distance(to: .zero) - 5) < 1e-9 })
        #expect(VariableStrokeOutline.cap(center: .zero, from: .zero, forward: Vector(dx: 1, dy: 0)).isEmpty)
        #expect(VariableStrokeOutline.direction(.zero, otherwise: Vector(dx: 0, dy: 1)) == Vector(dx: 0, dy: 1))
        #expect(VariableStrokeOutline.direction(Vector(dx: 3, dy: 4), otherwise: .zero) == Vector(dx: 0.6, dy: 0.8))
    }

    @Test func overlapRemovalRedrawsASelfCrossingOutline() throws {
        // A stroke that doubles back across itself: its outline overlaps and normalizes to one
        // region's contours.
        let centerline = [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 40), Point(x: 50, y: 40), Point(x: 50, y: -40)].map { VectorPoint(anchor: $0) }
        let samples = centerline.map { Sample(point: $0.anchor, width: 8) }
        let outline = try #require(VariableStrokeOutline.outline(centerline: centerline, samples: samples))
        let cleaned = VariableStrokeOutline.removingOverlap(outline)
        #expect(!cleaned.isEmpty && cleaned.allSatisfy { !$0.isEmpty })
        let square = Contour(segments: ContourPoints.segments(StrokeGeometry.square(), closed: true), closed: true)
        #expect(VariableStrokeOutline.removingOverlap(square).count == 1)
    }
}

@Suite struct CalligraphicOutlineTests {
    @Test func theNibAngleSetsTheWidth() {
        // Along a 45° nib: the minimum; across it: the full width.
        #expect(CalligraphicOutline.width(base: 10, direction: Vector(dx: 1, dy: -1), nibAngle: 45) == CalligraphicOutline.minimumWidth)
        #expect(abs(CalligraphicOutline.width(base: 10, direction: Vector(dx: 1, dy: 1), nibAngle: 45) - 10) < 1e-9)
        #expect(CalligraphicOutline.width(base: 10, direction: .zero, nibAngle: 45) == 10)
        #expect(CalligraphicOutline.width(base: 0.1, direction: .zero, nibAngle: 45) == CalligraphicOutline.minimumWidth)
    }

    @Test func samplesTakeTheirDirectionFromTheirNeighbours() {
        let points = [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 20, y: 0)]
        let across = CalligraphicOutline.samples(points, bases: [10], nibAngle: 90)
        #expect(across.map(\.point) == points && across.allSatisfy { abs($0.width - 10) < 1e-9 })
        let along = CalligraphicOutline.samples(points, bases: [10, 20, 30], nibAngle: 0)
        #expect(along.allSatisfy { $0.width == CalligraphicOutline.minimumWidth })
        let bases = CalligraphicOutline.samples(points, bases: [10, 20], nibAngle: 90).map(\.width)
        #expect(abs(bases[0] - 10) < 1e-9 && abs(bases[1] - 20) < 1e-9 && abs(bases[2] - 20) < 1e-9, "the last base carries on")
    }

    @Test func aStraightStrokeAlongAndAcrossTheNib() throws {
        let points = stride(from: 0.0, through: 200, by: 5).map { Point(x: $0, y: 50) }
        let centerline = StrokeGeometry.line([0, 200], y: 50)
        for (angle, expected) in [(0.0, CalligraphicOutline.minimumWidth), (90.0, 10.0)] {
            let samples = CalligraphicOutline.samples(points, bases: [10], nibAngle: angle)
            let outline = try #require(CalligraphicOutline.outline(centerline: centerline, samples: samples))
            let widths = StrokeGeometry.halfWidths(outline, from: 20, to: 180).map { $0 * 2 }
            #expect(!widths.isEmpty && widths.allSatisfy { abs($0 - expected) < 0.1 }, "angle \(angle)")
            // A flat start: nothing reaches back past the stroke's first sample.
            let xs = outline.segments.flatMap { s in stride(from: 0.0, through: 1.0, by: 0.05).map { s.evaluate($0).x } }
            #expect(xs.min()! > -0.1, "angle \(angle)")
        }
        // Both ends flat at their samples with the nib across (the end used to bulge about 1 pt).
        let across = try #require(CalligraphicOutline.outline(centerline: centerline, samples: CalligraphicOutline.samples(points, bases: [10], nibAngle: 90)))
        #expect(abs(across.bounds.maxX - 200) < 0.05 && abs(across.bounds.minX) < 0.05, "\(across.bounds)")
        #expect(abs(across.bounds.minY - 45) < 0.05 && abs(across.bounds.maxY - 55) < 0.05, "\(across.bounds)")
        // A repeated sample at a cap corner still leaves that corner sharp.
        let box = CalligraphicOutline.flatEnded(left: [Point(x: 0, y: 45), Point(x: 100, y: 45), Point(x: 100, y: 45)],
                                                right: [Point(x: 0, y: 55), Point(x: 50, y: 55), Point(x: 100, y: 55)]).bounds
        #expect(box.minX == 0 && box.maxX == 100 && box.minY == 45 && box.maxY == 55, "\(box)")
        let kinked = StrokeGeometry.line([0, 20, 20, 40], y: 50)
        #expect(CalligraphicOutline.outline(centerline: kinked, samples: CalligraphicOutline.samples(points, bases: [10], nibAngle: 90)) != nil)
        #expect(CalligraphicOutline.outline(centerline: [], samples: []) == nil)
        #expect(CalligraphicOutline.outline(centerline: [VectorPoint(anchor: .zero), VectorPoint(anchor: .zero)], samples: []) == nil)
    }
}

@Suite struct PathCuttingTests {
    @Test func piecesAtCutsKeepTheShape() throws {
        let curve = [VectorPoint(anchor: Point(x: 0, y: 0), outHandle: Vector(dx: 30, dy: 40)), VectorPoint(anchor: Point(x: 100, y: 0), inHandle: Vector(dx: -30, dy: 40))]
        let pieces = try #require(PathCutting.split(curve, closed: false, at: [PathCutting.Location(segment: 0, t: 0.25), PathCutting.Location(segment: 0, t: 0.75)]))
        #expect(pieces.count == 3 && pieces[0].keepsStart && !pieces[1].keepsStart)
        let original = CubicBezier(from: curve[0].anchor, outHandle: curve[0].outHandle, inHandle: curve[1].inHandle, to: curve[1].anchor)
        let middle = ContourPoints.segments(pieces[1].points, closed: false)[0]
        #expect(middle.evaluate(0).distance(to: original.evaluate(0.25)) < 1e-9 && middle.evaluate(1).distance(to: original.evaluate(0.75)) < 1e-9)
        #expect(middle.evaluate(0.5).distance(to: original.evaluate(0.5)) < 1e-6)
        #expect(PathCutting.split(curve, closed: false, at: []) == nil && PathCutting.split([curve[0]], closed: true, at: [.init(segment: 0, t: 0)]) == nil)
        // A closed contour cut once opens there.
        let triangle = [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10)].map { VectorPoint(anchor: $0) }
        let opened = try #require(PathCutting.split(triangle, closed: true, at: [.init(segment: 1, t: 0.5)]))
        #expect(opened.count == 1 && opened[0].keepsStart && opened[0].points.count == 5)
        #expect(PathCutting.Location(segment: 0, t: 0.5) < PathCutting.Location(segment: 1, t: 0))
    }

    @Test func crossingsAreFoundInContourOrder() {
        let square = StrokeGeometry.square()
        // A cutter short of the contour crosses nothing (its line would).
        #expect(PathCutting.crossings(square, closed: true, cutter: [Point(x: 5, y: -20), Point(x: 5, y: -10)]).isEmpty)
        let through = PathCutting.crossings(square, closed: true, cutter: [Point(x: 5, y: -5), Point(x: 5, y: 15)])
        #expect(through.map(\.segment) == [0, 2] && through.allSatisfy { abs($0.t - 0.5) < 1e-6 })
        // Through a corner: counted once, at the start of the next segment.
        let corner = PathCutting.crossings(square, closed: true, cutter: [Point(x: 15, y: -5), Point(x: 5, y: 5)])
        #expect(corner.contains(.init(segment: 1, t: 0)))
        // Through the start of a closed contour: the wrap to segment 0.
        let start = PathCutting.crossings(square, closed: true, cutter: [Point(x: -5, y: -5), Point(x: 5, y: 5)])
        #expect(start.contains(.init(segment: 0, t: 0)))
        // An open contour's own end is not a cut; a zero-length cutter step is skipped.
        #expect(PathCutting.crossings(square, closed: false, cutter: [Point(x: -5, y: 15), Point(x: -5, y: 15), Point(x: 5, y: 5)]).isEmpty)
    }

    @Test func splittingRules() throws {
        let square = StrokeGeometry.square()
        // A cut at the start point: the piece starting there keeps it.
        let atStart = try #require(PathCutting.split(square, closed: true, at: [.init(segment: 0, t: 0), .init(segment: 2, t: 0)]))
        #expect(atStart.count == 2 && atStart[0].keepsStart && !atStart[1].keepsStart)
        // Cuts not at the start: the piece that wraps past it keeps it.
        let wrapped = try #require(PathCutting.split(square, closed: true, at: [.init(segment: 1, t: 0), .init(segment: 2, t: 0)]))
        #expect(wrapped.map(\.keepsStart) == [false, true] && wrapped[1].points.first?.anchor == Point(x: 10, y: 10))
        // An open contour cut at its own end is not cut; out-of-range cuts are dropped.
        #expect(PathCutting.split(square, closed: false, at: [.init(segment: 3, t: 0)]) == nil)
        #expect(PathCutting.split(square, closed: false, at: [.init(segment: 7, t: 0), .init(segment: -1, t: 0)]) == nil)
        // An open contour cut at a point shares it.
        let open = try #require(PathCutting.split(square, closed: false, at: [.init(segment: 2, t: 0)]))
        #expect(open.count == 2 && open[0].points.last == open[1].points.first)
        #expect(open.allSatisfy { $0.points.first?.inHandle == .zero && $0.points.last?.outHandle == .zero })
    }

    @Test func stripsAndDistances() {
        #expect(PathCutting.distance(.zero, to: []) == .infinity && PathCutting.distance(Point(x: 3, y: 4), to: [.zero]) == 5)
        #expect(PathCutting.distance(Point(x: 5, y: 5), to: [.zero, .zero, Point(x: 10, y: 0)]) == 5)
        #expect(PathCutting.strip([.zero], width: 3).left == [.zero])
        #expect(PathCutting.strip([.zero, Point(x: 10, y: 0)], width: 0).left == [.zero, Point(x: 10, y: 0)])
        let strip = PathCutting.strip([.zero, Point(x: 10, y: 0)], width: 2)
        #expect(strip.left.count == 2 && abs(strip.left[0].x + 1) < 1e-9 && abs(strip.left[1].x - 11) < 1e-9)
        #expect(abs(abs(strip.left[0].y - strip.right[0].y) - 2) < 1e-9)
        // Strip normals: a repeated point and a U-turn.
        #expect(PathCutting.strip([.zero, .zero, Point(x: 10, y: 0)], width: 2).left.count == 3)
        #expect(PathCutting.strip([.zero, Point(x: 10, y: 0), .zero], width: 2).left.count == 3)
    }

    @Test func theKnife() throws {
        // A strip over the start: the remaining first piece keeps it; closing two-point pieces of
        // an open contour leaves them open.
        let line = StrokeGeometry.line([0, 10, 20, 30])
        let pieces = try #require(PathCutting.knife(line, closed: false, cutter: [Point(x: 5, y: -10), Point(x: 5, y: 10)], width: 4, close: true))
        #expect(pieces.contains { $0.keepsStart })
        #expect(pieces.allSatisfy { $0.points.count >= 3 || !$0.closed })
        let twoSegments = try #require(PathCutting.knife(line, closed: false, cutter: [Point(x: 25, y: -10), Point(x: 25, y: 10)], width: 2, close: false))
        #expect(twoSegments.count == 2)
        let straight = try #require(PathCutting.knife(line, closed: false, cutter: [Point(x: 2, y: -10), Point(x: 2, y: 10)], width: 10, close: false))
        #expect(straight.count == 1 && straight[0].keepsStart && straight[0].points.first?.anchor.x ?? 0 > 6)
        // A thin cut: pieces either side, nothing removed.
        let thin = try #require(PathCutting.knife(line, closed: false, cutter: [Point(x: 15, y: -10), Point(x: 15, y: 10)], width: 0, close: false))
        #expect(thin.count == 2 && thin[0].points.last?.anchor == Point(x: 15, y: 0))
        #expect(PathCutting.knife(line, closed: false, cutter: [Point(x: 15, y: 10), Point(x: 15, y: 20)], width: 0, close: false) == nil)
        // A closed contour's pieces close when asked.
        let square = StrokeGeometry.square()
        let halves = try #require(PathCutting.knife(square, closed: true, cutter: [Point(x: 5, y: -5), Point(x: 5, y: 15)], width: 0, close: true))
        #expect(halves.count == 2 && halves.allSatisfy(\.closed))
    }

    @Test func theChangeKeepsTheStartsContour() throws {
        let square = StrokeGeometry.square()
        let node = OpID(counter: 1, replica: 1), contour = OpID(counter: 2, replica: 1)
        #expect(PathCutting.command(node: node, cut: [], label: "x") == nil)
        #expect(PathCutting.command(node: node, cut: [(contour, [])], label: "x") == nil)
        let removed = PathCutting.command(node: node, cut: [(contour, [PathCutting.Piece(points: square, closed: false, keepsStart: false)])], label: "x")
        #expect(removed?.removed.count == 1 && removed?.pieces.count == 1)
        let pieces = try #require(PathCutting.split(square, closed: true, at: [.init(segment: 0, t: 0), .init(segment: 2, t: 0)]))
        let kept = try #require(PathCutting.command(node: node, cut: [(contour, pieces)], label: "Split"))
        #expect(kept.edits.count == 1 && kept.edits[0].contour == contour && kept.pieces.count == 1 && kept.removed.isEmpty)
    }
}

@Suite struct EraserStripTests {
    typealias Sample = VariableStrokeOutline.Sample

    @Test func theStripsEdgesFollowEachSamplesWidth() {
        #expect(EraserStrip.edges([Sample(point: .zero, width: 2)]).left == [.zero])
        let coincident = EraserStrip.edges([Sample(point: .zero, width: 2), Sample(point: .zero, width: 2), Sample(point: Point(x: 1, y: 0), width: 2)])
        #expect(coincident.left.count == 3)
        let widening = EraserStrip.edges([Sample(point: .zero, width: 2), Sample(point: Point(x: 10, y: 0), width: 6)])
        #expect(abs(widening.left[0].x + 1) < 1e-9 && abs(widening.left[1].x - 13) < 1e-9)
        #expect(abs(abs(widening.left[1].y - widening.right[1].y) - 6) < 1e-9)
        #expect(EraserStrip.halfWidth(near: .zero, samples: []) == 0)
        #expect(EraserStrip.halfWidth(near: Point(x: 9, y: 0), samples: [Sample(point: .zero, width: 2), Sample(point: Point(x: 10, y: 0), width: 6)]) == 3)
    }

    @Test func erasingThroughAPathLeavesItsPieces() throws {
        let line = StrokeGeometry.line([0, 100])
        #expect(EraserStrip.erase(line, closed: false, samples: []) == nil)
        #expect(EraserStrip.erase(line, closed: false, samples: [Sample(point: Point(x: 50, y: 20), width: 4), Sample(point: Point(x: 50, y: 30), width: 4)]) == nil, "a miss")
        let through = [Sample(point: Point(x: 50, y: -10), width: 4), Sample(point: Point(x: 50, y: 10), width: 4)]
        let pieces = try #require(EraserStrip.erase(line, closed: false, samples: through))
        #expect(pieces.count == 2 && pieces[0].keepsStart && !pieces[1].keepsStart)
        #expect(abs(pieces[0].points.last!.anchor.x - 48) < 1e-6 && abs(pieces[1].points.first!.anchor.x - 52) < 1e-6)
        // Over the start: the remaining piece keeps it.
        let start = [Sample(point: Point(x: 2, y: -10), width: 10), Sample(point: Point(x: 2, y: 10), width: 10)]
        let rest = try #require(EraserStrip.erase(line, closed: false, samples: start))
        #expect(rest.count == 1 && rest[0].keepsStart && rest[0].points.first!.anchor.x > 6)
    }
}

@Suite struct FreeformContourTests {
    @Test func samplingFollowsTheContour() {
        let line = StrokeGeometry.line([0, 100])
        let contour = FreeformContour(node: .zero, contour: .zero, closed: false, points: line)
        #expect(abs(contour.totalLength - 100) < 1e-6 && contour.samples.count == 101)
        #expect(contour.samples.first?.owner == 0 && contour.samples.last?.owner == 1 && contour.samples[1].owner == nil)
        #expect(contour.nearest(contour.samples[40].point + Vector(dx: 0, dy: 0.1))?.index == 40)
        #expect(!contour.hasMoved && contour.result(tolerance: 1) == nil)
        #expect(contour.preview.count == contour.samples.count)
        let closed = FreeformContour(node: .zero, contour: .zero, closed: true, points: [VectorPoint(anchor: .zero), VectorPoint(anchor: Point(x: 10, y: 0)), VectorPoint(anchor: Point(x: 5, y: 8))])
        #expect(closed.preview.count == closed.samples.count + 1 && closed.preview.last == closed.preview.first)
        let sample = FreeformContour.Sample(point: .zero, original: .zero, owner: nil, arc: 0)
        #expect(sample.point == sample.original)
    }

    @Test func aPullMovesTheStretchAndKeepsThePointsOutsideIt() throws {
        let line = [0.0, 100, 200, 300].enumerated().map { VectorPoint(id: OpID(counter: UInt64($0.offset + 1), replica: 4), anchor: Point(x: $0.element, y: 0)) }
        var contour = FreeformContour(node: .zero, contour: .zero, closed: false, points: line)
        contour.pull(from: contour.nearest(Point(x: 150, y: 0))!.index, by: Vector(dx: 0, dy: 20), length: 60)
        #expect(contour.hasMoved)
        let result = try #require(contour.result(tolerance: 0.5))
        #expect(result.first?.id == line[0].id && result.last?.id == line[3].id)
        #expect(result.contains { $0.anchor.y > 15 })
        #expect(result.first { $0.id == line[1].id }?.anchor == line[1].anchor, "a point outside the stretch keeps its place")
    }

    @Test func closedContoursRefitAroundAnUnmovedPoint() throws {
        let square = StrokeGeometry.square(replica: 7, size: 100)
        var contour = FreeformContour(node: .zero, contour: .zero, closed: true, points: square)
        #expect(contour.result(tolerance: 1) == nil)
        contour.pull(from: contour.nearest(Point(x: 50, y: 100))!.index, by: Vector(dx: 0, dy: 30), length: 60)
        let result = try #require(contour.result(tolerance: 0.5))
        #expect(result.first { $0.id == square[0].id }?.anchor == Point(x: 0, y: 0))
        #expect(result.contains { $0.anchor.y > 120 })
        // A pull near a corner of a closed contour wraps around it.
        var wrap = FreeformContour(node: .zero, contour: .zero, closed: true, points: square)
        wrap.pull(from: 0, by: Vector(dx: -10, dy: -10), length: 40)
        #expect(wrap.samples.last!.point != wrap.samples.last!.original)
        // Everything moved: the whole ring is refitted.
        var all = FreeformContour(node: .zero, contour: .zero, closed: true, points: square)
        all.reshape(at: Point(x: 50, y: 50), by: Vector(dx: 5, dy: 0), radius: 1000, strength: 1)
        #expect(all.result(tolerance: 0.5)?.allSatisfy { $0.id == .zero } == true)
    }

    @Test func pushAndReshape() {
        let square = StrokeGeometry.square(replica: 7, size: 100)
        var shoved = FreeformContour(node: .zero, contour: .zero, closed: false, points: Array(square.prefix(2)))
        shoved.push(at: Point(x: 50, y: 0), radius: 10)
        #expect(shoved.hasMoved)
        #expect(shoved.samples.allSatisfy { $0.point.distance(to: Point(x: 50, y: 0)) >= 10 - 1e-9 })
        let before = shoved.samples
        shoved.push(at: .zero, radius: 0)
        shoved.reshape(at: .zero, by: .zero, radius: 0, strength: 1)
        #expect(shoved.samples == before)
        // A sample exactly at the centre goes up.
        var centred = FreeformContour(node: .zero, contour: .zero, closed: false, points: Array(square.prefix(2)))
        centred.push(at: Point(x: 50, y: 0), radius: 5)
        #expect(centred.samples.contains { abs($0.point.y + 5) < 1e-9 && abs($0.point.x - 50) < 1e-9 })
        var reshaped = FreeformContour(node: .zero, contour: .zero, closed: false, points: Array(square.prefix(2)))
        reshaped.reshape(at: Point(x: 50, y: 0), by: Vector(dx: 0, dy: 10), radius: 20, strength: 0.5)
        let centre = reshaped.samples[reshaped.nearest(Point(x: 50, y: 5))!.index]
        #expect(abs(centre.point.y - 5) < 1e-9)
    }

    @Test func refittingAndPointKinds() {
        #expect(FreeformContour.fixKind(VectorPoint(anchor: .zero, inHandle: Vector(dx: 1, dy: 0), outHandle: Vector(dx: 0, dy: 1), kind: .curve)).kind == .corner)
        let smooth = VectorPoint(anchor: .zero, inHandle: Vector(dx: -1, dy: 0), outHandle: Vector(dx: 1, dy: 0), kind: .curve)
        #expect(FreeformContour.fixKind(smooth) == smooth)
        // Samples collapsed onto one place leave a straight segment.
        let points = StrokeGeometry.line([0, 10])
        let collapsed = [FreeformContour.Sample(point: Point(x: 5, y: 5), original: .zero, owner: 0, arc: 0),
                         FreeformContour.Sample(point: Point(x: 5, y: 5), original: Point(x: 5, y: 0), owner: nil, arc: 5),
                         FreeformContour.Sample(point: Point(x: 5, y: 5), original: Point(x: 10, y: 0), owner: 1, arc: 10)]
        let refit = FreeformContour.refit(collapsed, points: points, fitter: CurveFitter(maxError: 0.5))
        #expect(refit.count == 2 && refit.allSatisfy { $0.anchor == Point(x: 5, y: 5) })
        // A curved stretch refits with curve points between the unmoved ends.
        let line = StrokeGeometry.line([0, 300])
        var contour = FreeformContour(node: .zero, contour: .zero, closed: false, points: line)
        contour.reshape(at: Point(x: 150, y: 0), by: Vector(dx: 0, dy: 60), radius: 150, strength: 1)
        let result = contour.result(tolerance: 0.05) ?? []
        #expect(result.count >= 2)
    }
}
