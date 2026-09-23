import Foundation
import Testing
@testable import WTGeometry

@Suite struct BooleanOperationTests {
    let a = rectPath(0, 0, 10, 10)
    let b = rectPath(5, 5, 10, 10)
    let c = rectPath(2, 8, 4, 10)

    @Test func operationTruthTables() {
        for (x, y) in [(false, false), (false, true), (true, false), (true, true)] {
            #expect(BooleanOperation.union.includes(x, y) == (x || y))
            #expect(BooleanOperation.intersection.includes(x, y) == (x && y))
            #expect(BooleanOperation.subtraction.includes(x, y) == (x && !y))
            #expect(BooleanOperation.exclusiveOr.includes(x, y) == (x != y))
        }
    }

    @Test func rectangleResultsAreClean() {
        let union = Boolean.union(a, b)
        #expect(union.contours.count == 1 && union.contours[0].segments.count == 8)
        #expect(approx(union.signedArea(), 175))
        let intersection = Boolean.intersection(a, b)
        #expect(intersection.contours.count == 1 && intersection.contours[0].segments.count == 4)
        #expect(intersection.bounds == Rect(minX: 5, minY: 5, maxX: 10, maxY: 10))
        // Edge-sharing rectangles merge into one rectangle: collinear pieces are rejoined.
        let merged = Boolean.union(a, rectPath(10, 0, 10, 10))
        #expect(merged.contours.count == 1 && merged.contours[0].segments.count == 4)
        #expect(merged.bounds == Rect(minX: 0, minY: 0, maxX: 20, maxY: 10))
        // A hole: outer contour positive, hole negative.
        let ring = Boolean.subtracting(a, rectPath(3, 3, 4, 4))
        #expect(ring.contours.count == 2)
        #expect(ring.contours.map { $0.signedArea() > 0 }.sorted { !$0 && $1 } == [false, true])
        #expect(ring.pieces().count == 1)
        // Corner-touching squares stay two contours meeting at a point.
        let touching = Boolean.union(a, rectPath(10, 10, 5, 5))
        #expect(touching.contours.count == 2 && approx(touching.signedArea(), 125))
        #expect(touching.pieces().count == 2)
    }

    @Test func naryOperations() {
        let union = Boolean.union([a, b, c])
        let pairwise = Boolean.union(Boolean.union(a, b), c)
        #expect(approx(union.signedArea(), pairwise.signedArea(), 1e-9))
        let all = Boolean.intersection([a, b, c])
        #expect(approx(all.signedArea(), 1 * 2, 1e-9))  // x 5…6, y 8…10
        #expect(Boolean.intersection([FilledPath]()).isEmpty)
        #expect(Boolean.intersection([a, rectPath(50, 50, 1, 1)]).isEmpty)
        #expect(Boolean.union([FilledPath]()).isEmpty)
    }

    @Test func punchCropAndTransparency() {
        let cutter = rectPath(8, -1, 4, 12)
        let punched = Boolean.punch([a, b], with: cutter)
        #expect(punched.count == 2)
        #expect(approx(punched[0].signedArea(), 80) && approx(punched[1].signedArea(), 76))
        let cropped = Boolean.crop([a, b], with: cutter)
        #expect(approx(cropped[0].signedArea(), 20) && approx(cropped[1].signedArea(), 24))
        // A cutter covering the target completely punches it away.
        #expect(Boolean.punch([rectPath(1, 1, 2, 2)], with: a)[0].isEmpty)
        // A hole entirely inside makes the target a composite.
        #expect(Boolean.punch([a], with: rectPath(4, 4, 2, 2))[0].contours.count == 2)
        let overlap = Boolean.transparency(a, b)
        #expect(approx(overlap.signedArea(), 25))
        #expect(Boolean.transparency(a, rectPath(20, 20, 1, 1)).isEmpty)
    }

    @Test func divideThreePaths() {
        let pieces = Boolean.divide([a, b, c])
        let union = Boolean.union([a, b, c]).signedArea()
        #expect(approx(pieces.reduce(0) { $0 + $1.path.signedArea() }, union, 1e-9))
        #expect(pieces.contains { $0.operands == [0, 1, 2] })
        #expect(pieces.contains { $0.operands == [0] })
        #expect(pieces.allSatisfy { !$0.operands.isEmpty && $0.path.signedArea() > 0 })
        // Ordered by covering set size.
        let sizes = pieces.map { $0.operands.count }
        #expect(sizes == sizes.sorted())
        // A region split in two by an operand gives two pieces with the same operands.
        let split = Boolean.divide([a, rectPath(4, -1, 2, 12)])
        #expect(split.filter { $0.operands == [0] }.count == 2)
        #expect(Boolean.divide([]).isEmpty)
        let piece = DividedPiece(path: a, operands: [0])
        #expect(piece.operands == [0])
    }

    @Test func normalizeRemovesOverlap() {
        let eight = polygonPath(BooleanCorpus.bowtie)
        #expect(approx(eight.signedArea(), 0, 1e-9))  // lobes wind opposite ways
        let clean = Boolean.normalize(eight)
        #expect(clean.contours.count == 2)
        #expect(approx(clean.signedArea(), 50))
        #expect(clean.contours.allSatisfy { $0.signedArea() > 0 })
        // Two overlapping contours in one path, non-zero: one outline; even-odd: a hole.
        let overlapping = FilledPath(contours: [a.contours[0], b.contours[0]])
        #expect(Boolean.normalize(overlapping).contours.count == 1)
        var evenOdd = overlapping
        evenOdd.fillRule = .evenOdd
        #expect(approx(Boolean.normalize(evenOdd).signedArea(), 150))
        // A clockwise square normalizes to a counter-rotating one.
        let backwards = FilledPath(a.contours[0].reversed())
        #expect(approx(Boolean.normalize(backwards).signedArea(), 100))
        // A contour winding twice is still filled once.
        let twice = FilledPath(contours: [a.contours[0], a.contours[0]])
        #expect(approx(Boolean.normalize(twice).signedArea(), 100))
        #expect(approx(eight.contours[0].normalized().reduce(0) { $0 + $1.signedArea() }, 50))
    }

    @Test func largeCoordinatesAndTinyShapes() {
        let far = rectPath(1e6, 1e6, 10, 10)
        let farB = rectPath(1e6 + 5, 1e6 + 5, 10, 10)
        #expect(approx(Boolean.union(far, farB).signedArea(), 175, 1e-4))
        let tiny = rectPath(0, 0, 1e-3, 1e-3)
        #expect(approx(Boolean.union(tiny, rectPath(5e-4, 5e-4, 1e-3, 1e-3)).signedArea(), 1.75e-6, 1e-9))
        let options = Boolean.Options(tolerance: 1e-7, maxSplitsPerSegment: 8)
        #expect(options != Boolean.Options.standard)
        #expect(approx(Boolean.intersection(a, b, options: options).signedArea(), 25))
    }

    /// A contour of one closed cubic (a teardrop) coincides with itself as a loop edge: the
    /// merge must compare directions along the loop, not end vertices.
    @Test func coincidentLoopEdges() {
        let teardrop = Contour(segments: [CubicBezier(Point(0, 0), Point(20, -10), Point(20, 10), Point(0, 0))], closed: true)
        let path = FilledPath(teardrop)
        let area = abs(teardrop.signedArea())
        #expect(approx(Boolean.union(path, path).signedArea(), area, 1e-9))
        #expect(approx(Boolean.intersection(path, path).signedArea(), area, 1e-9))
        #expect(Boolean.subtracting(path, path).isEmpty)
        // Opposite directions cancel under non-zero: the doubled path winds 0 in the middle.
        let cancelled = FilledPath(contours: [teardrop, teardrop.reversed()])
        #expect(Boolean.normalize(cancelled).isEmpty)
        let loopOverlap = teardrop.segments[0].overlap(with: teardrop.segments[0].reversed())
        #expect(loopOverlap != nil && loopOverlap?.isSameDirection == false)
        #expect(teardrop.segments[0].overlap(with: teardrop.segments[0])?.isSameDirection == true)
        // A microscopic loop is merged away without disturbing the rest.
        let speck = Contour(segments: [CubicBezier(Point(5, 5), Point(5 + 1e-5, 5), Point(5, 5 + 1e-5), Point(5, 5))], closed: true)
        #expect(approx(Boolean.union(a, FilledPath(speck)).signedArea(), 100, 1e-9))
    }

    @Test func splitCapIsHonoured() {
        // A comb crossing one long edge many times, with the split cap far below the crossings.
        var teeth: [Point] = [Point(0, -5)]
        for k in 0..<40 {
            teeth.append(Point(Double(k) * 0.25, 5))
            teeth.append(Point(Double(k) * 0.25 + 0.125, -5))
        }
        let comb = polygonPath(teeth)
        let result = Boolean.union(a, comb, options: Boolean.Options(maxSplitsPerSegment: 4))
        #expect(result.signedArea().isFinite)
    }

    @Test func cleanParametersDropsTinyPieces() {
        let line = Line(Point(0, 0), Point(10, 0)).elevated()
        #expect(Arrangement.cleanParameters([0.5, 0.5 + 1e-9, 1e-9, 1 - 1e-9, .nan, 2], on: line, merge: 1e-5, limit: 10) == [0, 0.5, 1])
        #expect(Arrangement.cleanParameters([0.1, 0.2, 0.3], on: line, merge: 1e-5, limit: 2) == [0, 0.1, 0.2, 1])
        // The two parameters of a loop map to one point and both survive.
        let loop = loopCurve
        let (s, t) = loop.selfIntersection()!
        #expect(Arrangement.cleanParameters([s, t], on: loop, merge: 1e-5, limit: 10).count == 4)
    }

    @Test func mergeCollinearAcrossTheSeam() {
        let pieces = [
            Line(Point(5, 0), Point(10, 0)).elevated(), Line(Point(10, 0), Point(10, 10)).elevated(),
            Line(Point(10, 10), Point(0, 10)).elevated(), Line(Point(0, 10), Point(0, 0)).elevated(),
            Line(Point(0, 0), Point(5, 0)).elevated(),
        ]
        #expect(Arrangement.mergeCollinear(pieces, tolerance: 1e-9).count == 4)
        #expect(Arrangement.mergeCollinear([pieces[0]], tolerance: 1e-9).count == 1)
        // Doubling back is not merged.
        let back = [Line(Point(0, 0), Point(5, 0)).elevated(), Line(Point(5, 0), Point(2, 0)).elevated()]
        #expect(Arrangement.mergeCollinear(back, tolerance: 1e-9).count == 2)
        let curved = [sCurve, Line(sCurve.p3, Point(9, 0)).elevated()]
        #expect(Arrangement.mergeCollinear(curved, tolerance: 1e-9).count == 2)
        let degenerate = [Line(Point(0, 0), Point(0, 0)).elevated(), Line(Point(0, 0), Point(1, 0)).elevated()]
        #expect(Arrangement.mergeCollinear(degenerate, tolerance: 1e-9).count == 2)
    }
}

@Suite struct SelfIntersectionTests {
    @Test func cubicLoop() {
        let (s, t) = loopCurve.selfIntersection()!
        #expect(s < t)
        #expect(approx(loopCurve.evaluate(s), loopCurve.evaluate(t), 1e-9))
        #expect(sCurve.selfIntersection() == nil)
        #expect(Line(Point(0, 0), Point(1, 1)).elevated().selfIntersection() == nil)
        // A loop that would close beyond the curve's parameter range does not count.
        #expect(loopCurve.subdivide(from: 0, to: 0.3).selfIntersection() == nil)
        // Degenerate: a curve whose cubic coefficient is vertical (a.dx == 0) takes the y branch.
        let vertical = CubicBezier(Point(0, 0), Point(3, 4), Point(-3, 4), Point(0, 0)).applying(.rotation(radians: .pi / 2))
        if let loop = vertical.selfIntersection() {
            #expect(approx(vertical.evaluate(loop.s), vertical.evaluate(loop.t), 1e-9))
        }
    }

    @Test func contourCrossings() {
        let eight = Contour(polygon: BooleanCorpus.bowtie)
        let hits = eight.selfIntersections()
        #expect(hits.count == 1)
        #expect(approx(hits[0].point, Point(5, 5), 1e-9))
        #expect(!eight.isSimple())
        let square = Contour(polygon: [Point(0, 0), Point(4, 0), Point(4, 4), Point(0, 4)])
        #expect(square.isSimple())
        #expect(circle(radius: 3).isSimple())
        // A segment's own loop.
        let looped = Contour(segments: [loopCurve], closed: false)
        #expect(looped.selfIntersections().contains { $0.segmentIndex == $0.otherSegmentIndex })
        // A doubled-back stretch reports the ends of the shared stretch.
        let doubled = Contour(polygon: [Point(0, 0), Point(10, 0), Point(10, 5), Point(10, 2), Point(3, 2)], closed: false)
        #expect(!doubled.isSimple())
        let spur = Contour(polygon: [Point(0, 0), Point(10, 0), Point(4, 0), Point(4, 5)])
        #expect(spur.selfIntersections().contains { approx($0.point, Point(4, 0), 1e-6) })
        let record = ContourSelfIntersection(segmentIndex: 0, t: 0.1, otherSegmentIndex: 2, u: 0.2, point: .zero)
        #expect(record.otherSegmentIndex == 2)
    }

    @Test func normalizationSplitsSelfIntersectingContours() {
        let eight = Contour(polygon: BooleanCorpus.bowtie)
        let lobes = eight.normalized()
        #expect(lobes.count == 2)
        #expect(lobes.allSatisfy { $0.isSimple() })
        #expect(lobes.allSatisfy { approx($0.signedArea(), 25, 1e-9) })
        let star = (0..<5).map { k -> Point in
            let angle = Double(k * 2) * 2 * .pi / 5
            return Point(10 * cos(angle), 10 * sin(angle))
        }
        let pentagram = Contour(polygon: star)
        let nonZero = pentagram.normalized(rule: .nonZero)
        let evenOdd = pentagram.normalized(rule: .evenOdd)
        #expect(nonZero.count == 1)  // the pentagon outline
        #expect(evenOdd.count == 5)  // five points, hollow middle
        #expect(nonZero.reduce(0) { $0 + $1.signedArea() } > evenOdd.reduce(0) { $0 + $1.signedArea() })
    }
}

@Suite struct OverlapTests {
    @Test func collinearLines() {
        let a = Line(Point(0, 0), Point(10, 0)).elevated()
        let b = Line(Point(5, 0), Point(15, 0)).elevated()
        let o = a.overlap(with: b)!
        #expect(approx(o.t0, 0.5, 1e-6) && approx(o.t1, 1, 1e-6))
        #expect(approx(o.u0, 0, 1e-6) && approx(o.u1, 0.5, 1e-6))
        #expect(o.isSameDirection)
        let reversed = a.overlap(with: b.reversed())!
        #expect(!reversed.isSameDirection)
        // End to end is a shared point, not a shared stretch.
        #expect(a.overlap(with: Line(Point(10, 0), Point(20, 0)).elevated()) == nil)
        // Crossing, parallel and far apart.
        #expect(a.overlap(with: Line(Point(5, -5), Point(5, 5)).elevated()) == nil)
        #expect(a.overlap(with: Line(Point(0, 1), Point(10, 1)).elevated()) == nil)
        #expect(a.overlap(with: Line(Point(50, 50), Point(60, 50)).elevated()) == nil)
    }

    @Test func curveAndItsPiece() {
        let piece = sCurve.subdivide(from: 0.2, to: 0.7)
        let o = sCurve.overlap(with: piece)!
        #expect(approx(o.t0, 0.2, 1e-5) && approx(o.t1, 0.7, 1e-5))
        #expect(sCurve.overlap(with: sCurve)!.t1 > 0.99)
        // Curves that touch at both ends but bulge apart do not overlap.
        let bulge = CubicBezier(sCurve.p0, Point(1, -3), Point(2, 3), sCurve.p3)
        #expect(sCurve.overlap(with: bulge) == nil)
        // A hairpin passing through its start again at t = 0.5 and 1 is no closed loop.
        let hairpin = CubicBezier(Point(0, 0), Point(1, 0), Point(-1, 0), Point(0, 0))
        #expect(hairpin.overlap(with: hairpin) == nil)
        let arrangement = sCurve.arrangementIntersections(with: piece, tolerance: 1e-6)
        #expect(arrangement.overlap != nil)
        #expect(arrangement.crossings.allSatisfy { $0.t < 0.19 || $0.t > 0.71 })
        let shared = sCurve.arrangementIntersections(with: Line(Point(3, 0), Point(3, 5)).elevated(), tolerance: 1e-6, sharedEndpoint: Point(3, 0))
        #expect(shared.crossings.isEmpty)
    }
}

@Suite struct FilledPathTests {
    @Test func basics() {
        let square = rectPath(0, 0, 4, 4)
        #expect(approx(square.signedArea(), 16))
        #expect(approx(square.reversed().signedArea(), -16))
        #expect(approx(circlePath(0, 0, 2).signedArea(), .pi * 4, 0.01))
        #expect(square.bounds == Rect(minX: 0, minY: 0, maxX: 4, maxY: 4))
        #expect(FilledPath.empty.bounds.isNull && FilledPath.empty.isEmpty)
        #expect(!square.isEmpty)
        #expect(square.windingNumber(at: Point(2, 2)) == 1 && square.crossingCount(at: Point(2, 2)) == 1)
        #expect(square.applying(.translation(x: 10, y: 0)).contains(Point(12, 2)))
        let doubled = FilledPath(contours: [square.contours[0], square.contours[0]], fillRule: .evenOdd)
        #expect(!doubled.contains(Point(2, 2)))
        #expect(FillRule.evenOdd.isInside(windingNumber: -3) && !FillRule.evenOdd.isInside(windingNumber: 2))
        // An open contour's area includes its closing chord.
        let open = Contour(polygon: [Point(0, 0), Point(4, 0), Point(4, 4)], closed: false)
        #expect(approx(open.signedArea(), 8))
        // The area of a cubic segment is exact: the κ quarter circle.
        let quarter = Contour(segments: [quarterCircle(radius: 1)], closed: true)
        #expect(approx(quarter.signedArea(), flattenedArea(FilledPath(quarter), samples: 20000), 1e-7))
    }

    @Test func pieces() {
        let two = FilledPath(contours: [
            rectPath(0, 0, 10, 10).contours[0], rectPath(2, 2, 2, 2).contours[0].reversed(),
            rectPath(20, 0, 5, 5).contours[0], rectPath(21, 1, 1, 1).contours[0].reversed(),
            rectPath(3, 3, 0, 5).contours[0],
        ])
        let pieces = two.pieces()
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.contours.count == 2 })
        // A hole inside nested outers goes to the innermost.
        let nested = FilledPath(contours: [
            rectPath(0, 0, 20, 20).contours[0], rectPath(2, 2, 16, 16).contours[0].reversed(),
            rectPath(4, 4, 12, 12).contours[0], rectPath(6, 6, 2, 2).contours[0].reversed(),
        ])
        let nestedPieces = nested.pieces()
        #expect(nestedPieces.count == 2)
        #expect(nestedPieces.contains { $0.contours.count == 2 && approx($0.signedArea(), 144 - 4) })
        // An orphan hole stands on its own.
        let orphan = FilledPath(contours: [rectPath(0, 0, 2, 2).contours[0].reversed()])
        #expect(orphan.pieces().count == 1)
    }
}
