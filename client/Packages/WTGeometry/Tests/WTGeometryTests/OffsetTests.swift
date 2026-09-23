import Foundation
import Testing
@testable import WTGeometry

@Suite struct OffsetCurveTests {
    @Test func straightLineOffsetsExactly() {
        let line = Line(start: Point(0, 0), end: Point(10, 0)).elevated()
        let result = Offset.offset(line, by: 2)
        #expect(result.count == 1)
        #expect(result[0].segments.count == 1)
        let s = result[0].segments[0]
        // The normal of +x is +y (the perpendicular turns positively).
        #expect(approx(s.p0, Point(0, 2)))
        #expect(approx(s.p3, Point(10, 2)))
    }

    @Test func quarterCircleOffsetStaysOnTheConcentricCircle() {
        let arc = quarterCircle(center: .zero, radius: 10)
        for d in [-5.0, 3, 9.5] {
            let tolerance = 1e-4
            let result = Offset.offset(arc, by: d, tolerance: tolerance)
            #expect(result.count == 1)
            // The normal of a positively running arc points at its center.
            for p in boundarySamples(FilledPath(contours: result)) {
                let r = p.distance(to: .zero)
                // The source is a cubic approximation of the circle, off by ≤ 2.8e-4 of r.
                #expect(abs(r - (10 - d)) < tolerance + 3e-3, "d \(d): radius \(r)")
            }
        }
    }

    @Test func zeroDistanceIsTheCurve() {
        let result = Offset.offset(sCurve, by: 0)
        #expect(result.count == 1)
        #expect(approx(result[0].segments.first!.p0, sCurve.p0))
        #expect(approx(result[0].segments.last!.p3, sCurve.p3))
    }

    @Test func degenerateAndNonFiniteCurvesHaveNoOffset() {
        let p = Point(3, 4)
        #expect(Offset.offset(CubicBezier(p, p, p, p), by: 1).isEmpty)
        #expect(Offset.offset(CubicBezier(p, Point(.nan, 0), p, p), by: 1).isEmpty)
        #expect(Offset.offset(sCurve, by: .infinity).isEmpty)
    }

    @Test func cuspSplitsTheOffset() {
        let cusp = CubicBezier(Point(0, 0), Point(10, 10), Point(0, 10), Point(10, 0))
        let result = Offset.offset(cusp, by: 1)
        #expect(result.count == 2)
        // A straight segment that doubles back has two cusps.
        let overshoot = CubicBezier(Point(0, 0), Point(20, 0), Point(-10, 0), Point(10, 0))
        #expect(Offset.offset(overshoot, by: 1).count == 3)
    }

    /// Every point of the offset is within tolerance of |d| from the source, and every exact
    /// offset point is within tolerance of the offset: the approximation neither strays nor
    /// leaves anything out.
    @Test(arguments: [1.0, -2.5, 8, 0.25])
    func randomCurvesOffsetWithinTolerance(_ d: Double) {
        var rng = SeededGenerator(seed: 303 + UInt64(abs(d * 100)))
        let tolerance = 1e-3
        for _ in 0..<40 {
            let curve = rng.cubic(in: -20...20)
            let offsets = Offset.offset(curve, by: d, tolerance: tolerance)
            let source = [Contour(segments: [curve], closed: false)]
            for p in boundarySamples(FilledPath(contours: offsets), perSegment: 8) {
                // Farther than |d| never; nearer only where the offset loops past the center of
                // curvature, which the stroke cleanup removes, so only the upper bound holds.
                #expect(distance(from: p, to: source) <= abs(d) + tolerance + 1e-9)
            }
            for k in 1..<40 {
                let t = Double(k) / 40
                guard curve.speed(t) > 1e-3 * curve.controlPolygonLength else {
                    continue
                }
                let exact = curve.evaluate(t) + curve.normal(t) * d
                #expect(distance(from: exact, to: offsets) <= tolerance + 1e-9, "t \(t)")
            }
        }
    }
}

@Suite struct StrokeOutlineTests {
    static let tolerance = 1e-3

    func stroke(_ contour: Contour, _ style: StrokeStyle) -> FilledPath {
        Offset.strokeOutline(contour, style: style, tolerance: Self.tolerance)
    }

    @Test func twoPointLineExpandsToARectangle() {
        let line = Contour(polygon: [Point(0, 0), Point(100, 0)], closed: false)
        let outline = stroke(line, StrokeStyle(width: 4))
        #expect(outline.contours.count == 1)
        #expect(outline.contours[0].segments.count == 4)
        #expect(approx(area(outline), 400, 1e-6))
        #expect(outline.bounds == Rect(minX: 0, minY: -2, maxX: 100, maxY: 2))
    }

    @Test(arguments: LineCap.allCases)
    func capsOfAnOpenLine(_ cap: LineCap) {
        let line = Contour(polygon: [Point(0, 0), Point(60, 80)], closed: false)  // length 100
        let outline = stroke(line, StrokeStyle(width: 10, cap: cap))
        let expected: Double
        switch cap {
        case .butt: expected = 1000
        case .square: expected = 1100
        case .round: expected = 1000 + Double.pi * 25
        }
        #expect(relativeError(area(outline), expected) < 1e-5, "\(cap): \(area(outline))")
    }

    @Test func circleExpandsToAnAnnulus() {
        let r = 50.0
        let w = 8.0
        let source = circle(center: Point(10, 20), radius: r)
        for cap in LineCap.allCases {
            for join in LineJoin.allCases {
                let outline = stroke(source, StrokeStyle(width: w, cap: cap, join: join))
                #expect(outline.contours.count == 2)
                // The annulus area within 0.1%; and exactly (to the tolerance) the curve's length
                // times the width, as for any smooth closed curve without tight turns.
                #expect(relativeError(area(outline), 2 * Double.pi * r * w) < 1e-3)
                #expect(relativeError(area(outline), source.length() * w) < 1e-4)
                #expect(outline.contains(Point(10 + r, 20)))
                #expect(!outline.contains(Point(10, 20)))
                #expect(!outline.contains(Point(10 + r + w, 20)))
            }
        }
    }

    @Test(arguments: LineJoin.allCases)
    func squareWithEachJoin(_ join: LineJoin) {
        let side = 100.0
        let w = 10.0
        let h = w / 2
        let outline = stroke(squareContour(0, 0, side), StrokeStyle(width: w, join: join))
        let full = (side + w) * (side + w) - (side - w) * (side - w)
        let expected: Double
        switch join {
        case .miter: expected = full
        case .bevel: expected = full - 4 * h * h / 2
        case .round: expected = full - 4 * h * h + Double.pi * h * h
        }
        #expect(outline.contours.count == 2)
        #expect(relativeError(area(outline), expected) < 1e-5, "\(join): \(area(outline)) vs \(expected)")
        // The same square drawn the other way round paints the same region.
        let reversed = stroke(squareContour(0, 0, side).reversed(), StrokeStyle(width: w, join: join))
        #expect(relativeError(area(reversed), expected) < 1e-5)
    }

    @Test func miterLimitBevelsSharpCorners() {
        // A square corner's miter is √2 widths long.
        let square = squareContour(0, 0, 100)
        let full = 110.0 * 110 - 90 * 90
        let within = stroke(square, StrokeStyle(width: 10, join: .miter, miterLimit: 1.5))
        #expect(relativeError(area(within), full) < 1e-5)
        let beyond = stroke(square, StrokeStyle(width: 10, join: .miter, miterLimit: 1.4))
        #expect(relativeError(area(beyond), full - 50) < 1e-5)
        // Below 1 acts as 1, NaN as the default of 4.
        #expect(relativeError(area(stroke(square, StrokeStyle(width: 10, miterLimit: 0))), full - 50) < 1e-5)
        #expect(relativeError(area(stroke(square, StrokeStyle(width: 10, miterLimit: .nan))), full) < 1e-5)
    }

    @Test func acuteMiterReachesTheTip() {
        // A 60° spike: the miter tip lies 1/sin(30°) = 2 half-widths... beyond the vertex along
        // the bisector, i.e. half-width / sin(half-angle).
        let spike = Contour(polygon: [Point(0, 0), Point(100, 0), Point(50, 86.602_540_378)], closed: true)
        let outline = stroke(spike, StrokeStyle(width: 2, join: .miter, miterLimit: 10))
        #expect(outline.bounds.minY < -0.99 && outline.bounds.minY > -1.01)
        #expect(outline.bounds.minX < -1.7 + 1e-3 && outline.bounds.minX > -1.74)
    }

    @Test func closedContourWithGapStrokesItsClosingSegment() {
        let open = Contour(polygon: [Point(0, 0), Point(100, 0), Point(100, 100), Point(0, 100)], closed: false)
        var closed = open
        closed.isClosed = true
        let a = stroke(closed, StrokeStyle(width: 10, join: .miter))
        let b = stroke(squareContour(0, 0, 100), StrokeStyle(width: 10, join: .miter))
        #expect(relativeError(area(a), area(b)) < 1e-9)
        #expect(area(stroke(open, StrokeStyle(width: 10))) < area(a))
    }

    @Test func zeroLengthSegmentsAreSkipped() {
        let p = Point(50, 0)
        let segments = [
            Line(start: Point(0, 0), end: p).elevated(),
            CubicBezier(p, p, p, p),
            Line(start: p, end: Point(50, 50)).elevated(),
            CubicBezier(Point(50, 50), Point(50, 50), Point(50, 50), Point(50, 50)),
        ]
        let contour = Contour(segments: segments, closed: false)
        let clean = Contour(polygon: [Point(0, 0), p, Point(50, 50)], closed: false)
        for join in LineJoin.allCases {
            let style = StrokeStyle(width: 6, cap: .square, join: join)
            #expect(relativeError(area(stroke(contour, style)), area(stroke(clean, style))) < 1e-9)
        }
    }

    @Test func zeroLengthContourPaintsADot() {
        let p = Point(5, 5)
        let dot = Contour(segments: [CubicBezier(p, p, p, p)], closed: false)
        #expect(stroke(dot, StrokeStyle(width: 4, cap: .butt)).isEmpty)
        #expect(relativeError(area(stroke(dot, StrokeStyle(width: 4, cap: .round))), Double.pi * 4) < 1e-4)
        let square = stroke(dot, StrokeStyle(width: 4, cap: .square))
        #expect(relativeError(area(square), 16) < 1e-9)
        #expect(square.bounds == Rect(minX: 3, minY: 3, maxX: 7, maxY: 7))
        var closedDot = dot
        closedDot.isClosed = true
        #expect(stroke(closedDot, StrokeStyle(width: 4, cap: .round)).isEmpty)
    }

    @Test func nothingToStroke() {
        let line = Contour(polygon: [Point(0, 0), Point(10, 0)], closed: false)
        #expect(stroke(line, StrokeStyle(width: 0)).isEmpty)
        #expect(stroke(line, StrokeStyle(width: -3)).isEmpty)
        #expect(stroke(line, StrokeStyle(width: .nan)).isEmpty)
        #expect(stroke(line, StrokeStyle(width: .infinity)).isEmpty)
        #expect(stroke(Contour(segments: [], closed: false), StrokeStyle(width: 2)).isEmpty)
        let bad = Contour(segments: [CubicBezier(Point(0, 0), Point(.nan, 1), Point(2, 2), Point(3, 3))], closed: false)
        #expect(stroke(bad, StrokeStyle(width: 2)).isEmpty)
    }

    @Test func invalidTolerancesFallBackToTheDefault() {
        let line = Contour(polygon: [Point(0, 0), Point(10, 0)], closed: false)
        let style = StrokeStyle(width: 2, cap: .round)
        let reference = Offset.strokeOutline(line, style: style)
        for tolerance in [0, -1, Double.nan, .infinity] {
            #expect(Offset.strokeOutline(line, style: style, tolerance: tolerance) == reference)
        }
        #expect(Offset.offset(sCurve, by: 1, tolerance: .nan) == Offset.offset(sCurve, by: 1))
    }

    @Test func pathAndContourListOverloadsAgree() {
        let a = squareContour(0, 0, 50)
        let b = circle(center: Point(100, 100), radius: 20)
        let style = StrokeStyle(width: 4, join: .round)
        let viaPath = Offset.strokeOutline(FilledPath(contours: [a, b], fillRule: .evenOdd), style: style)
        let viaList = Offset.strokeOutline([a, b], style: style)
        #expect(approx(area(viaPath), area(viaList), 1e-9))
        #expect(approx(area(viaList), area(Offset.strokeOutline(a, style: style)) + area(Offset.strokeOutline(b, style: style)), 1e-6))
    }

    @Test func cuspStrokesLikeTheSweptDisc() {
        // A straight segment that overshoots both ends: the stroke is the capsule of its extent.
        let overshoot = CubicBezier(Point(0, 0), Point(20, 0), Point(-10, 0), Point(10, 0))
        let xs = (0...10_000).map { overshoot.evaluate(Double($0) / 10_000).x }
        let span = xs.max()! - xs.min()!
        let outline = stroke(Contour(segments: [overshoot], closed: false), StrokeStyle(width: 2, cap: .round))
        #expect(relativeError(area(outline), span * 2 + Double.pi) < 1e-4)
        #expect(outline.contours.count == 1)
    }

    @Test func wideStrokeOnATightCurveHasNoHoles() {
        // Radius of curvature far below the half-width: the inner offset loops.
        let tight = Contour(segments: [CubicBezier(Point(0, 0), Point(10, 0), Point(10, 2), Point(0, 2))], closed: false)
        let outline = stroke(tight, StrokeStyle(width: 20, cap: .round, join: .round))
        #expect(outline.contours.count == 1)
        #expect(outline.contains(Point(5, 1)))
        #expect(outline.contains(Point(-8, 1)))
    }
}

@Suite struct StrokeDistanceTests {
    /// With round caps and joins the stroke is exactly the set of points within half the width
    /// of the path, so every outline point sits at half the width from the source, and a point
    /// clearly nearer is inside and one clearly farther is outside.
    ///
    /// Widths up to the size of the drawing make the curves turn far tighter than the half-width,
    /// where the plain offsets fold over (see `Offset.strokeSide`).
    @Test(arguments: 0..<12)
    func randomPathsMatchTheSweptDisc(_ seed: Int) {
        var rng = SeededGenerator(seed: 9000 + UInt64(seed))
        let tolerance = 1e-3
        for iteration in 0..<5 {
            let closed = iteration % 2 == 1
            var source = randomContour(&rng, segments: 1 + seed % 4, range: 0...100, closed: closed)
            if seed % 5 == 0 {
                source.segments[0].p1 = source.segments[0].p0  // a retracted handle: a stationary end
            }
            let w = rng.double(in: 1...100)
            let h = w / 2
            let outline = Offset.strokeOutline(source, style: StrokeStyle(width: w, cap: .round, join: .round), tolerance: tolerance)
            #expect(!outline.isEmpty)
            var worst = 0.0
            for p in boundarySamples(outline, perSegment: 6) {
                worst = max(worst, abs(distance(from: p, to: [source]) - h))
            }
            #expect(worst <= tolerance + 1e-5, "seed \(seed) iteration \(iteration): off by \(worst)")
            let box = source.bounds.expanded(by: h + 1)
            var misses = 0
            for _ in 0..<150 {
                let p = Point(rng.double(in: box.minX...box.maxX), rng.double(in: box.minY...box.maxY))
                let d = distance(from: p, to: [source])
                if abs(d - h) < 3 * tolerance {
                    continue
                }
                if outline.contains(p) != (d < h) {
                    misses += 1
                }
            }
            #expect(misses == 0, "seed \(seed) iteration \(iteration): \(misses) probes misclassified")
        }
    }
}

@Suite struct DashTests {
    let line = Contour(polygon: [Point(0, 0), Point(100, 0)], closed: false)

    @Test func dashesSplitByArcLength() {
        let dashes = Offset.dash(line, pattern: [10, 10])
        #expect(dashes.count == 5)
        for (k, dash) in dashes.enumerated() {
            #expect(approx(dash.startPoint!, Point(Double(20 * k), 0), 1e-6))
            #expect(approx(dash.endPoint!, Point(Double(20 * k + 10), 0), 1e-6))
        }
        let outline = Offset.strokeOutline(line, style: StrokeStyle(width: 2, dash: [10, 10]))
        #expect(outline.contours.count == 5)
        #expect(approx(area(outline), 100, 1e-6))
    }

    @Test func phaseShiftsThePattern() {
        let dashes = Offset.dash(line, pattern: [10, 10], phase: 5)
        // 0-5, 15-25, ..., 75-85, 95-100.
        #expect(dashes.count == 6)
        #expect(approx(dashes[0].endPoint!, Point(5, 0), 1e-6))
        #expect(approx(dashes[4].endPoint!, Point(85, 0), 1e-6))
        #expect(approx(dashes[5].startPoint!, Point(95, 0), 1e-6))
        // Negative phases wrap.
        let negative = Offset.dash(line, pattern: [10, 10], phase: -15)
        #expect(approx(negative[0].endPoint!, Point(5, 0), 1e-6))
        // A non-finite phase is no phase.
        #expect(Offset.dash(line, pattern: [10, 10], phase: .nan) == Offset.dash(line, pattern: [10, 10]))
        // A phase landing in a gap starts with the gap.
        let inGap = Offset.dash(line, pattern: [10, 10], phase: 12)
        #expect(approx(inGap[0].startPoint!, Point(8, 0), 1e-6))
    }

    @Test func oddPatternsRepeatAndSolidPatternsAreSolid() {
        // [10, 5, 5] reads as [10, 5, 5, 10, 5, 5]: on 0-10, 15-20, 30-35, 40-50...
        let odd = Offset.dash(line, pattern: [10, 5, 5])
        #expect(approx(odd[1].startPoint!, Point(15, 0), 1e-6))
        #expect(approx(odd[1].endPoint!, Point(20, 0), 1e-6))
        #expect(approx(odd[2].startPoint!, Point(30, 0), 1e-6))
        #expect(approx(odd[2].endPoint!, Point(35, 0), 1e-6))
        for solid in [[], [0, 0], [-1, 4], [Double.nan, 2]] as [[Double]] {
            #expect(Offset.dash(line, pattern: solid) == [line])
        }
        #expect(StrokeStyle(width: 1, dash: [3]).normalizedDash == [3, 3])
    }

    @Test func dashesFollowCurvesAndCorners() {
        let square = squareContour(0, 0, 100)
        let dashes = Offset.dash(square, pattern: [30, 20])
        #expect(dashes.count == 8)
        var total = 0.0
        for dash in dashes {
            total += dash.length()
        }
        #expect(approx(total, 240, 1e-6))
        // A dash spanning a corner gets the join.
        let outline = Offset.strokeOutline(square, style: StrokeStyle(width: 2, join: .miter, dash: [30, 20], dashPhase: 15))
        #expect(outline.contains(Point(100.9, -0.9)))
        let circleDashes = Offset.dash(circle(center: .zero, radius: 10), pattern: [1, 1])
        #expect(circleDashes.count == Int((2 * Double.pi * 10 / 2).rounded(.up)))
    }

    @Test func zeroLengthDashesAreDots() {
        let dashes = Offset.dash(line, pattern: [0, 10])
        #expect(dashes.count == 10)
        #expect(dashes.allSatisfy { $0.segments.count == 1 && $0.segments[0].isDegenerate })
        let round = Offset.strokeOutline(line, style: StrokeStyle(width: 2, cap: .round, dash: [0, 10]))
        #expect(round.contours.count == 10)
        #expect(relativeError(area(round), 10 * Double.pi) < 1e-3)
        // Square dots turn with the path.
        let diagonal = Contour(polygon: [Point(0, 0), Point(30, 30)], closed: false)
        let squares = Offset.strokeOutline(diagonal, style: StrokeStyle(width: 2, cap: .square, dash: [0, 20]))
        #expect(relativeError(area(squares), 3 * 4) < 1e-9)
        #expect(squares.bounds.minX < -1.4)
        #expect(Offset.strokeOutline(line, style: StrokeStyle(width: 2, cap: .butt, dash: [0, 10])).isEmpty)
    }

    @Test func degenerateContoursHaveNoDashes() {
        let p = Point(1, 1)
        #expect(Offset.dash(Contour(segments: [CubicBezier(p, p, p, p)], closed: false), pattern: [1, 1]).isEmpty)
        #expect(Offset.dash(Contour(segments: [], closed: false), pattern: [1, 1]).isEmpty)
        let bad = Contour(segments: [CubicBezier(p, Point(.infinity, 0), p, Point(2, 2))], closed: false)
        #expect(Offset.dash(bad, pattern: [1, 1]).isEmpty)
    }

    @Test func dashCountIsCapped() {
        let long = Contour(polygon: [Point(0, 0), Point(1e6, 0)], closed: false)
        #expect(Offset.dash(long, pattern: [1, 1]).count == Offset.maxDashes)
    }
}

@Suite struct InsetTests {
    let square = FilledPath(squareContour(0, 0, 100))

    @Test func insetShrinksASquare() {
        let inset = Offset.inset(square, by: 10)
        #expect(relativeError(area(inset), 6400) < 1e-6)
        #expect(approx(inset.bounds.minX, 10, 1e-6) && approx(inset.bounds.maxX, 90, 1e-6))
        #expect(Offset.inset(square, by: 0) == Boolean.normalize(square))
    }

    @Test(arguments: LineJoin.allCases)
    func outsetUsesTheJoinOnConvexCorners(_ join: LineJoin) {
        let outset = Offset.inset(square, by: -10, join: join)
        let expected: Double
        switch join {
        case .miter: expected = 120 * 120
        case .bevel: expected = 120 * 120 - 4 * 50
        case .round: expected = 100 * 100 + 4 * 100 * 10 + Double.pi * 100
        }
        #expect(relativeError(area(outset), expected) < 1e-5, "\(join)")
    }

    @Test(arguments: LineJoin.allCases)
    func insetUsesTheJoinOnReflexCorners(_ join: LineJoin) {
        let l = FilledPath(Contour(polygon: [Point(0, 0), Point(100, 0), Point(100, 50), Point(50, 50), Point(50, 100), Point(0, 100)]))
        let inset = Offset.inset(l, by: 10, join: join)
        let expected: Double
        switch join {
        case .miter: expected = 3900
        case .bevel: expected = 3950
        case .round: expected = 3900 + 100 * (1 - Double.pi / 4)
        }
        #expect(relativeError(area(inset), expected) < 1e-5, "\(join): \(area(inset))")
    }

    @Test func insetCircleAndHoles() {
        let ring = FilledPath(contours: [circle(center: .zero, radius: 50), circle(center: .zero, radius: 20).reversed()])
        let inset = Offset.inset(ring, by: 5, join: .round)
        let expected = Double.pi * (45 * 45 - 25 * 25)
        #expect(relativeError(area(inset), expected) < 1e-3)
        #expect(inset.contours.count == 2)
    }

    @Test func collapseYieldsNothing() {
        #expect(Offset.inset(square, by: 50).isEmpty)
        #expect(Offset.inset(square, by: 70).isEmpty)
        let tiny = Offset.inset(square, by: 49)
        #expect(relativeError(area(tiny), 4) < 1e-4)
        // A dumbbell: the bar collapses first, leaving two pieces.
        let dumbbell = Boolean.union([
            FilledPath(squareContour(0, 0, 40)), FilledPath(squareContour(100, 0, 40)),
            rectPath(40, 15, 60, 10),
        ])
        let split = Offset.inset(dumbbell, by: 6)
        #expect(split.pieces().count == 2)
        #expect(relativeError(area(split), 2 * 28 * 28) < 1e-5)
        // A circle only just larger than the inset leaves a sliver that is dropped.
        #expect(Offset.inset(FilledPath(circle(center: .zero, radius: 10)), by: 9.999_999, join: .round).isEmpty)
        #expect(Offset.inset(FilledPath.empty, by: 1).isEmpty)
        #expect(Offset.inset(square, by: .nan).isEmpty)
    }

    @Test func stepsFollowTheSpacingCurves() {
        let uniform = Offset.insetSteps(square, distance: 10, steps: 3)
        #expect(uniform.count == 3)
        for (k, path) in uniform.enumerated() {
            let side = 100 - 2 * 10 * Double(k + 1) / 3
            #expect(relativeError(area(path), side * side) < 1e-6)
        }
        for spacing in InsetSpacing.allCases {
            let paths = Offset.insetSteps(square, distance: 30, steps: 4, spacing: spacing)
            for (k, path) in paths.enumerated() {
                let d = spacing.distance(step: k + 1, of: 4, total: 30)
                #expect(relativeError(area(path), (100 - 2 * d) * (100 - 2 * d)) < 1e-6)
            }
        }
        #expect(approx(InsetSpacing.farther.distance(step: 1, of: 4, total: 16), 8))
        #expect(approx(InsetSpacing.nearer.distance(step: 1, of: 4, total: 16), 1))
        #expect(InsetSpacing.uniform.distance(step: 1, of: 0, total: 16) == 0)
        #expect(Offset.insetSteps(square, distance: 10, steps: 0).isEmpty)
        // Steps past the collapse are empty but keep their place.
        let deep = Offset.insetSteps(square, distance: 80, steps: 2)
        #expect(!deep[0].isEmpty && deep[1].isEmpty)
    }

    @Test func openContoursInsetAsTheirFill() {
        let open = FilledPath(Contour(polygon: [Point(0, 0), Point(100, 0), Point(100, 100), Point(0, 100)], closed: false))
        #expect(relativeError(area(Offset.inset(open, by: 10)), 6400) < 1e-6)
    }
}

@Suite struct OffsetFuzzTests {
    @Test func randomStrokesNeverCrash() {
        var rng = SeededGenerator(seed: 77)
        for iteration in 0..<60 {
            var contour = randomContour(&rng, segments: 1 + iteration % 4, range: -50...50, closed: iteration % 3 == 0)
            if iteration % 5 == 0 {
                // Collapse some handles and whole segments.
                let p = contour.segments[0].p0
                contour.segments[0] = CubicBezier(p, p, contour.segments[0].p2, contour.segments[0].p3)
                contour.segments.append(CubicBezier(contour.endPoint!, contour.endPoint!, contour.endPoint!, contour.endPoint!))
            }
            if iteration % 7 == 0 {
                let p = contour.segments[0].p0
                contour.segments[0] = CubicBezier(p, p + Vector(1, 1), p + Vector(-1, 1), p)
            }
            let style = StrokeStyle(
                width: [0.01, 1, 7, 60][iteration % 4],
                cap: LineCap.allCases[iteration % 3],
                join: LineJoin.allCases[(iteration / 3) % 3],
                miterLimit: rng.double(in: 0.5...20),
                dash: iteration % 4 == 1 ? [rng.double(in: 0...10), rng.double(in: 0...10)] : [],
                dashPhase: rng.double(in: -20...20))
            let outline = Offset.strokeOutline(contour, style: style)
            for c in outline.contours {
                #expect(c.segments.allSatisfy { $0.p0.isFinite && $0.p1.isFinite && $0.p2.isFinite && $0.p3.isFinite })
            }
            #expect(outline.signedArea() >= -1e-6)
            let inset = Offset.inset(FilledPath(contour), by: rng.double(in: -10...10), join: style.join, miterLimit: style.miterLimit)
            #expect(inset.signedArea() >= -1e-6)
        }
    }

    @Test func hugeAndTinyCoordinatesStayFinite() {
        for scale in [1e-6, 1e6] {
            let contour = Contour(segments: [sCurve.applying(.scale(scale))], closed: false)
            let style = StrokeStyle(width: scale, cap: .round, join: .round)
            let outline = Offset.strokeOutline(contour, style: style, tolerance: scale * 1e-3)
            #expect(!outline.isEmpty, "scale \(scale)")
            // The same stroke at unit scale, scaled, has the same area.
            let unit = Offset.strokeOutline(Contour(segments: [sCurve], closed: false), style: StrokeStyle(width: 1, cap: .round, join: .round), tolerance: 1e-3)
            #expect(relativeError(area(outline), area(unit) * scale * scale) < 1e-3, "scale \(scale)")
            #expect(outline.bounds.width.isFinite)
        }
    }
}

/// Regressions in the GEO-001/GEO-002 code the stroke cleanup found.
@Suite struct CleanupRegressionTests {
    @Test func longLineFindsEveryCrossingOfAShortCurve() {
        // The line's control hull is its whole bounding box and the curve lies inside it: the
        // flat pieces far from the line used to fill the candidate limit, and the crossing near
        // the curve's end was lost.
        let line = Line(start: Point(91.31297515609941, -5.976571451255605), end: Point(43.75867052477343, 40.17906336997252)).elevated()
        let curve = CubicBezier(
            Point(59.18099201984661, 28.615272237902566), Point(55.8248725045323, 28.68197527347371),
            Point(52.72749313131705, 30.432673768759777), Point(50.93940458315344, 33.27357623803853))
        let hits = line.intersections(with: curve)
        #expect(hits.count == 2)
        #expect(hits.contains { abs($0.u - 0.985) < 0.01 })
    }

    @Test func nearlyCoincidentEdgesKeepTheirContour() {
        // Two edges crossing at a shallow angle, their ends just beyond the merge distance
        // apart: the sliver between them used to misclassify an edge and lose the whole union.
        let a = FilledPath(Contour(polygon: [Point(31, 0), Point(29, 0), Point(29, 5), Point(31, 5)]))
        let b = FilledPath(Contour(polygon: [Point(29, 1.5e-5), Point(31, -1.5e-5), Point(31, -0.2), Point(29, -0.2)]))
        #expect(abs(abs(Boolean.union(a, b).signedArea()) - 10.4) < 1e-4)
    }
}
