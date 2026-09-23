import WTGeometry
import Foundation
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// FX-004, FX-005, FX-046, FX-048: the vector effect kernels' properties.
@Suite struct EffectKernelTests {
    static let square = EffectShape(contours: DisplayPath(rect: Rect(x: 0, y: 0, width: 40, height: 40)).contours)
    static let circle = EffectShape(contours: DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 40, height: 40)).contours)
    static let reference = Rect(x: 0, y: 0, width: 40, height: 40)

    static func points(_ shapes: [EffectShape]) -> [Point] {
        shapes.flatMap { $0.contours.flatMap { $0.segments.flatMap { [$0.p0, $0.p1, $0.p2, $0.p3] } } }
    }

    static func sameGeometry(_ lhs: [EffectShape], _ rhs: [EffectShape], tolerance: Double = 1e-9) -> Bool {
        let a = points(lhs)
        let b = points(rhs)
        return a.count == b.count && zip(a, b).allSatisfy { approx($0, $1, tolerance: tolerance) }
    }

    /// Random convex polygons for property tests (a fixed stream, so failures reproduce).
    static func convexPolygons(count: Int) -> [[Point]] {
        var random = SplitMix64(seed: 99)
        return (0..<count).map { _ in
            let sides = 3 + Int(random.next() % 7)
            let radius = 10 + random.nextUnit() * 60
            var angles = (0..<sides).map { _ in random.nextUnit() * 2 * .pi }.sorted()
            if Set(angles).count < angles.count { angles = (0..<sides).map { Double($0) * 2 * .pi / Double(sides) } }
            return angles.map { Point(x: 100 + radius * cos($0), y: 100 + radius * sin($0)) }
        }
    }

    // MARK: Bend

    @Test func bendWithSizeZeroIsIdentity() {
        #expect(BendKernel.apply(.init(size: 0), to: [Self.square], reference: Self.reference) == [Self.square])
    }

    @Test func bendBloatsSidesAndPinchesThem() {
        let bloated = BendKernel.apply(.init(size: 10), to: [Self.square], reference: Self.reference)[0]
        // The top side's handles move away from the centre (up), its corners stay.
        let top = bloated.contours[0].segments[0]
        #expect(approx(top.p0, Point(x: 0, y: 0)))
        #expect(top.p1.y < 0 && top.p2.y < 0)
        let pinched = BendKernel.apply(.init(size: -10), to: [Self.square], reference: Self.reference)[0]
        #expect(pinched.contours[0].segments[0].p1.y > 0)
        // A centre offset (y up) moves the distortion: the farthest point is the reference.
        let shifted = BendKernel.apply(.init(size: 10, center: Point(x: 100, y: 0)), to: [Self.square], reference: Self.reference)[0]
        #expect(shifted != bloated)
    }

    @Test func bendKeepsSmoothPointsSmooth() {
        let bent = BendKernel.apply(.init(size: 6, center: Point(x: 7, y: 3)), to: [Self.circle], reference: Self.reference)[0]
        let segments = bent.contours[0].segments
        for index in segments.indices {
            let incoming = segments[(index - 1 + segments.count) % segments.count]
            let outgoing = segments[index]
            let a = (incoming.p3 - incoming.p2).normalized
            let b = (outgoing.p1 - outgoing.p0).normalized
            #expect(abs(a.cross(b)) < 1e-9 && a.dot(b) > 0)
        }
    }

    @Test func bendLeavesADegeneratePointAlone() {
        let dot = EffectShape(contours: [Contour(segments: [CubicBezier(p0: Point(x: 20, y: 20), p1: Point(x: 20, y: 20), p2: Point(x: 20, y: 20), p3: Point(x: 20, y: 20))], closed: false)])
        #expect(BendKernel.apply(.init(size: 5), to: [dot], reference: Self.reference) == [dot])
        #expect(BendKernel.apply(.init(size: 5), to: [EffectShape(contours: [Contour(segments: [], closed: true)])], reference: Self.reference).count == 1)
    }

    // MARK: Duet

    @Test func reflectingTwiceIsIdentity() {
        for angle in [0.0, 30, 90, 137] {
            let mirror = DuetKernel.reflection(center: Point(x: 13, y: -7), degrees: angle)
            let twice = mirror.concatenating(mirror)
            for point in [Point(x: 3, y: 4), Point(x: -20, y: 11), Point(x: 100, y: 0)] {
                #expect(approx(twice.apply(point), point, tolerance: 1e-9))
            }
            #expect(mirror.determinant < 0)
        }
    }

    @Test func duetReflectAddsAMirrorWoundTheSameWay() {
        let result = DuetKernel.apply(.init(mode: .reflect, center: Point(x: 30, y: 0), axisAngle: 90), to: [Self.square], reference: Self.reference)
        #expect(result.count == 1)
        #expect(result[0].contours.count == 2)
        let areas = result[0].contours.map { FilledPath(contours: [$0]).signedArea() }
        #expect(areas[0] * areas[1] > 0)
        #expect(approx(result[0].bounds, Rect(x: 0, y: 0, width: 100, height: 40), tolerance: 1e-9))
    }

    @Test func duetRotateMakesTheRosette() {
        let settings = LiveEffect.Duet(mode: .rotate, copies: 6)
        #expect(DuetKernel.placements(settings, reference: Self.reference).count == 6)
        #expect(DuetKernel.apply(settings, to: [Self.square], reference: Self.reference)[0].contours.count == 6)
        // Zero copies reads one: the original alone.
        #expect(DuetKernel.apply(.init(mode: .rotate, copies: 0), to: [Self.square], reference: Self.reference)[0].contours.count == 1)
        // Two copies are a 180° pair.
        let pair = DuetKernel.placements(.init(mode: .rotate, copies: 2), reference: Self.reference)
        #expect(approx(pair[1].apply(Point(x: 40, y: 20)), Point(x: 0, y: 20), tolerance: 1e-9))
    }

    @Test func duetJoinedClosedAndEvenOdd() {
        let line = EffectShape(contours: DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 10, y: 10)], closed: false).contours)
        let joined = DuetKernel.apply(.init(mode: .rotate, center: Point(x: -5, y: 5), copies: 4, joined: true, closed: true, evenOdd: true), to: [line], reference: line.bounds)
        #expect(joined[0].contours.count == 1)
        #expect(joined[0].contours[0].isClosed)
        #expect(joined[0].rule == .evenOdd)
        let open = DuetKernel.apply(.init(mode: .reflect, closed: true), to: [line], reference: line.bounds)
        #expect(open[0].contours.allSatisfy { $0.isClosed })
        #expect(open[0].rule == nil)
        #expect(DuetKernel.join([Contour(segments: [], closed: false)], closed: false).isEmpty)
    }

    // MARK: Transform

    @Test func transformWithDefaultsIsIdentity() {
        #expect(TransformKernel.matrix(.init(), reference: Self.reference).isIdentity)
        #expect(Self.sameGeometry(TransformKernel.apply(.init(), to: [Self.square], reference: Self.reference), [Self.square]))
    }

    @Test func transformCopiesProduceThatManyDrawables() {
        for copies in [1, 3, 12] {
            #expect(TransformKernel.apply(.init(rotate: 30, copies: copies), to: [Self.square], reference: Self.reference).count == copies)
        }
        #expect(TransformKernel.copies(.init(copies: 5000), reference: Self.reference).count == 1000)
    }

    @Test func transformComposesScaleSkewRotateMoveAboutTheCentre() {
        // Scale 200% about the centre, then move 10 right and 5 up (y up).
        let matrix = TransformKernel.matrix(.init(scaleX: 200, scaleY: 200, move: Point(x: 10, y: 5)), reference: Self.reference)
        #expect(approx(matrix.apply(Point(x: 20, y: 20)), Point(x: 30, y: 15)))
        #expect(approx(matrix.apply(Point(x: 40, y: 20)), Point(x: 70, y: 15)))
        // Rotate 90° counterclockwise on screen about the centre: right goes to top.
        let rotate = TransformKernel.matrix(.init(rotate: 90), reference: Self.reference)
        #expect(approx(rotate.apply(Point(x: 40, y: 20)), Point(x: 20, y: 0), tolerance: 1e-9))
        // Positive horizontal skew leans the top to the right; positive vertical raises the right.
        let skewH = TransformKernel.matrix(.init(skewH: 45), reference: Self.reference)
        #expect(approx(skewH.apply(Point(x: 20, y: 0)), Point(x: 40, y: 0), tolerance: 1e-9))
        let skewV = TransformKernel.matrix(.init(skewV: 45), reference: Self.reference)
        #expect(approx(skewV.apply(Point(x: 40, y: 20)), Point(x: 40, y: 0), tolerance: 1e-9))
        // A centre offset moves the pivot (y up).
        let pivot = TransformKernel.matrix(.init(scaleX: 50, scaleY: 50, center: Point(x: 20, y: 20)), reference: Self.reference)
        #expect(approx(pivot.apply(Point(x: 40, y: 0)), Point(x: 40, y: 0)))
    }

    // MARK: Expand Path

    @Test func expandBothOnAnOpenPathIsTheStrokeOutline() {
        let wave = EffectShape(contours: AttributeCorpus.wave(in: Rect(x: 0, y: 0, width: 90, height: 40)).contours)
        let expanded = ExpandKernel.apply(.init(width: 12, cap: .round, join: .round), to: [wave])[0]
        let outline = Offset.strokeOutline(wave.contours, style: WTGeometry.StrokeStyle(width: 12, cap: .round, join: .round))
        #expect(expanded.contours == outline.contours)
        #expect(expanded.rule == .nonZero)
        // Inside and Outside do not apply to open paths.
        #expect(ExpandKernel.apply(.init(direction: .inside, width: 12, cap: .round, join: .round), to: [wave])[0].contours == outline.contours)
    }

    @Test func expandInsideAndOutsideAreBands() {
        let inside = FilledPath(contours: ExpandKernel.apply(.init(direction: .inside, width: 8), to: [Self.square])[0].contours)
        #expect(inside.contains(Point(x: 4, y: 20)))
        #expect(!inside.contains(Point(x: 20, y: 20)))
        #expect(!inside.contains(Point(x: -4, y: 20)))
        let outside = FilledPath(contours: ExpandKernel.apply(.init(direction: .outside, width: 8, join: .round), to: [Self.square])[0].contours)
        #expect(outside.contains(Point(x: -4, y: 20)))
        #expect(!outside.contains(Point(x: 4, y: 20)))
        // An inset that swallows the shape leaves the whole shape as the band.
        let collapsed = FilledPath(contours: ExpandKernel.apply(.init(direction: .inside, width: 30), to: [Self.square])[0].contours)
        #expect(collapsed.contains(Point(x: 20, y: 20)))
        // Width 0 expands to nothing; widths clamp to 50 and the miter limit reads 4.
        #expect(ExpandKernel.apply(.init(width: 0), to: [Self.square])[0].contours.isEmpty)
        #expect(LiveEffect.ExpandPath(width: 80).effectiveWidth == 50)
        #expect(LiveEffect.ExpandPath(miterLimit: 0).effectiveMiterLimit == 4)
        #expect(LiveEffect.ExpandPath(miterLimit: 99).effectiveMiterLimit == 57)
    }

    // MARK: Ragged and Sketch

    @Test func splitMix64MatchesTheReferenceStream() {
        // Published SplitMix64 outputs for seed 0 and seed 1234567.
        var zero = SplitMix64(seed: 0)
        #expect(zero.next() == 0xE220_A839_7B1D_CDAF)
        #expect(zero.next() == 0x6E78_9E6A_A1B9_65F4)
        var other = SplitMix64(seed: 1_234_567)
        #expect(other.next() == 6_457_827_717_110_365_317)
        var unit = SplitMix64(seed: 5)
        for _ in 0..<1000 {
            let signed = unit.nextSigned()
            #expect(signed >= -1 && signed < 1)
        }
    }

    @Test func raggedFrequencyZeroAndSizeZeroAreIdentity() {
        #expect(RaggedKernel.apply(.init(size: 5, frequency: 0), to: [Self.circle]) == [Self.circle])
        #expect(RaggedKernel.apply(.init(size: 0, frequency: 30), to: [Self.circle]) == [Self.circle])
    }

    @Test func raggedIsSeededAndStable() {
        let settings = LiveEffect.Ragged(size: 4, frequency: 30, copies: 2, seed: 42)
        let first = RaggedKernel.apply(settings, to: [Self.circle])
        let second = RaggedKernel.apply(settings, to: [Self.circle])
        #expect(first == second)
        #expect(first.count == 3)
        // Byte-identical: the exact bit patterns of every coordinate.
        let bits = Self.points(first).flatMap { [$0.x.bitPattern, $0.y.bitPattern] }
        #expect(bits == Self.points(second).flatMap { [$0.x.bitPattern, $0.y.bitPattern] })
        var reseeded = settings
        reseeded.seed = 43
        #expect(RaggedKernel.apply(reseeded, to: [Self.circle]) != first)
        // Seed 0 reads as 1.
        var zero = settings
        zero.seed = 0
        var one = settings
        one.seed = 1
        #expect(RaggedKernel.apply(zero, to: [Self.circle]) == RaggedKernel.apply(one, to: [Self.circle]))
    }

    @Test func raggedDisplacementIsBoundedAndUniformAlternates() {
        let size = 3.0
        let rough = RaggedKernel.apply(.init(size: size, frequency: 72, seed: 9), to: [Self.square])[0]
        // Added points lie within `size` of the square's outline.
        for segment in rough.contours[0].segments {
            let p = segment.p3
            let distance = min(abs(p.x), abs(p.x - 40), abs(p.y), abs(p.y - 40))
            #expect(distance <= size + 1e-9)
        }
        // One point per inch along a 40 pt side: none added at 1 per inch, more at 72.
        #expect(rough.contours[0].segments.count > 4)
        let uniform = RaggedKernel.apply(.init(size: size, frequency: 72, uniform: true, seed: 9), to: [Self.square])[0]
        let top = uniform.contours[0].segments.prefix(while: { $0.p3.y < 20 && $0.p3.x < 40 })
        let offsets = top.dropLast().map { $0.p3.y }
        #expect(offsets.allSatisfy { approx(abs($0), size, tolerance: 1e-9) })
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 == -$1 })
    }

    @Test func raggedSmoothMakesCurvePoints() {
        let smooth = RaggedKernel.apply(.init(size: 3, frequency: 72, smooth: true, seed: 2), to: [Self.square])[0]
        let segments = smooth.contours[0].segments
        // Interior added points are smooth: collinear handles.
        let joint = (segments[0].p3 - segments[0].p2).normalized.cross((segments[1].p1 - segments[1].p0).normalized)
        #expect(abs(joint) < 1e-9)
        #expect(!segments[0].isLinear())
        #expect(LiveEffect.Ragged(copies: 40).effectiveCopies == 10)
    }

    @Test func sketchCopiesOneWithAmountZeroIsIdentity() {
        #expect(SketchKernel.apply(.init(amount: 0, copies: 1), to: [Self.square]) == [Self.square])
        #expect(SketchKernel.apply(.init(amount: 0, copies: 0), to: [Self.square]) == [Self.square])
    }

    @Test func sketchDrawsCopiesStablyOpenOrClosed() {
        let settings = LiveEffect.Sketch(amount: 4, copies: 3, seed: 5)
        let sketched = SketchKernel.apply(settings, to: [Self.square])
        #expect(sketched.count == 3)
        #expect(sketched == SketchKernel.apply(settings, to: [Self.square]))
        #expect(sketched.allSatisfy { $0.contours.allSatisfy { !$0.isClosed } })
        let closed = SketchKernel.apply(.init(amount: 4, copies: 2, closed: true, seed: 5), to: [Self.square])
        #expect(closed.allSatisfy { $0.contours.allSatisfy { $0.isClosed } })
        // Amount 0 with several copies: the outline repeated, never trimmed.
        let repeated = SketchKernel.apply(.init(amount: 0, copies: 2, seed: 5), to: [Self.square])
        #expect(repeated.count == 2 && repeated.allSatisfy { $0.contours[0].isClosed })
        // A trim longer than the path leaves nothing; an empty contour is dropped.
        let tiny = EffectShape(contours: DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 0.5, y: 0)], closed: false).contours + [Contour(segments: [], closed: false)])
        let trimmed = SketchKernel.apply(.init(amount: 50, copies: 20, seed: 8), to: [tiny])
        #expect(trimmed.contains { $0.contours.isEmpty })
        #expect(LiveEffect.Sketch(copies: 99).effectiveCopies == 20)
        #expect(LiveEffect.Sketch(seed: 0).effectiveSeed == 1)
    }

    // MARK: Corners

    @Test func cornersRadiusZeroIsIdentity() {
        #expect(CornersKernel.apply(.init(radius: 0), to: [Self.square]) == [Self.square])
        #expect(CornersKernel.apply(.init(radius: 5), to: [Self.circle]) == [Self.circle])
    }

    @Test func roundSquareMatchesARoundedRectangle() {
        let radius = 8.0
        let rounded = CornersKernel.apply(.init(radius: radius, style: .round), to: [Self.square])[0].contours[0]
        // The rounded rectangle: sides inset by r, quarter circles of radius r (kappa arcs).
        let kappa = 0.552_284_749_831
        #expect(rounded.segments.count == 8)
        for segment in rounded.segments where !segment.isLinear() {
            let corners = [Point(x: radius, y: radius), Point(x: 40 - radius, y: radius), Point(x: 40 - radius, y: 40 - radius), Point(x: radius, y: 40 - radius)]
            let center = corners.min { $0.distance(to: segment.evaluate(0.5)) < $1.distance(to: segment.evaluate(0.5)) }!
            for t in stride(from: 0.0, through: 1, by: 0.125) {
                #expect(abs(segment.evaluate(t).distance(to: center) - radius) < 0.01)
            }
            #expect(approx(segment.p1.distance(to: segment.p0), radius * kappa, tolerance: 0.01))
        }
    }

    @Test func chamferTangentPointsLieOnTheOriginalSides() {
        let chamfered = CornersKernel.apply(.init(radius: 6, style: .chamfer), to: [Self.square])[0].contours[0]
        for segment in chamfered.segments {
            for point in [segment.p0, segment.p3] {
                let onSide = abs(point.x) < 1e-9 || abs(point.x - 40) < 1e-9 || abs(point.y) < 1e-9 || abs(point.y - 40) < 1e-9
                #expect(onSide)
            }
        }
        // Chamfer at 90°: the cut is 6 × tan(45°) along each side.
        #expect(chamfered.segments.contains { approx($0.p0, Point(x: 6, y: 0), tolerance: 1e-9) || approx($0.p3, Point(x: 6, y: 0), tolerance: 1e-9) })
    }

    @Test func invertedRoundScoopsTheCorner() {
        let scooped = CornersKernel.apply(.init(radius: 8, style: .invertedRound), to: [Self.square])[0]
        let region = FilledPath(contours: scooped.contours)
        #expect(!region.contains(Point(x: 1, y: 1)))
        #expect(region.contains(Point(x: 9, y: 9)))
        #expect(region.contains(Point(x: 20, y: 1)))
    }

    @Test func oversizedRadiiAreCappedPerCornerAndNeverOverlap() {
        for polygon in Self.convexPolygons(count: 40) {
            let shape = EffectShape(contours: [Contour(polygon: polygon)])
            let rounded = CornersKernel.apply(.init(radius: 1000, style: .chamfer), to: [shape])[0].contours[0]
            // Every cut point stays on its side, between the side's midpoint and its corner: no
            // two corners' cuts cross, so the chamfered contour never folds back.
            let sides = shape.contours[0].explicitSegments
            for segment in rounded.segments {
                let onSomeSide = sides.contains { side in
                    Line(start: side.p0, end: side.p3).distance(to: segment.p0) < 1e-6
                }
                #expect(onSomeSide)
            }
            let original = FilledPath(contours: shape.contours).signedArea()
            let area = FilledPath(contours: [rounded]).signedArea()
            #expect(area * original > 0 && abs(area) <= abs(original) + 1e-6)
        }
    }

    @Test func curvedNeighboursAreCutByArcLength() {
        // A D shape: a straight side and a curved one meeting at two corners.
        var path = DisplayPath()
        path.move(to: Point(x: 0, y: 0))
        path.addCubicCurve(control1: Point(x: 40, y: 0), control2: Point(x: 40, y: 40), to: Point(x: 0, y: 40))
        path.close()
        let shape = EffectShape(contours: path.contours)
        let rounded = CornersKernel.apply(.init(radius: 5, style: .round), to: [shape])[0]
        #expect(rounded.contours[0].segments.count > 2)
        #expect(rounded != shape)
    }

    @Test func selectedPointsLimitTheCorners() {
        let only = CornersKernel.apply(.init(radius: 6, points: [CornerPoint(contour: 0, anchor: 0)]), to: [Self.square])[0].contours[0]
        #expect(only.segments.count == 5)
        // A member naming a point that is not a corner, or another contour, is ignored.
        let foreign = CornersKernel.apply(.init(radius: 6, points: [CornerPoint(contour: 3, anchor: 0)]), to: [Self.square])
        #expect(foreign == [Self.square])
        // Open paths: the end points are not corners.
        let open = EffectShape(contours: DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 20, y: 0), Point(x: 20, y: 20)], closed: false).contours)
        let bent = CornersKernel.apply(.init(radius: 4), to: [open])[0].contours[0]
        #expect(approx(bent.startPoint!, Point(x: 0, y: 0)) && approx(bent.endPoint!, Point(x: 20, y: 20)))
        #expect(bent.segments.count == 3)
    }

    @Test func cornerPiecesHandleDegenerateInput() {
        #expect(CornersKernel.cornerPieces(from: .zero, direction: Vector(1, 0), to: .zero, style: .round).isEmpty)
        // Collinear: a straight piece.
        #expect(CornersKernel.cornerPieces(from: .zero, direction: Vector(1, 0), to: Point(x: 5, y: 0), style: .round).count == 1)
        #expect(CornersKernel.turning(CubicBezier(p0: .zero, p1: .zero, p2: .zero, p3: .zero), Line(start: .zero, end: Point(x: 1, y: 0)).elevated()) == nil)
        // A full reversal is not a corner.
        #expect(CornersKernel.turning(Line(start: .zero, end: Point(x: 1, y: 0)).elevated(), Line(start: Point(x: 1, y: 0), end: .zero).elevated()) == nil)
        #expect(CornersKernel.arc(center: .zero, from: Point(x: 1, y: 0), sweep: .pi).count == 2)
    }

    // MARK: Combine

    static let a = FilledPath(contours: DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 40, height: 40)).contours)
    static let b = FilledPath(contours: DisplayPath(rect: Rect(x: 20, y: 10, width: 40, height: 20)).contours)
    static let c = FilledPath(contours: DisplayPath(rect: Rect(x: 30, y: 0, width: 5, height: 40)).contours)

    @Test func combineOperationsFoldInStackingOrder() {
        let union = CombineKernel.combine([Self.a, Self.b], operation: .union)
        #expect(union.contains(Point(x: 5, y: 20)) && union.contains(Point(x: 55, y: 20)))
        let subtract = CombineKernel.combine([Self.a, Self.b, Self.c], operation: .subtract)
        #expect(subtract.contains(Point(x: 5, y: 20)) && !subtract.contains(Point(x: 25, y: 20)) && !subtract.contains(Point(x: 32, y: 5)))
        let intersect = CombineKernel.combine([Self.a, Self.b], operation: .intersect)
        #expect(intersect.contains(Point(x: 30, y: 20)) && !intersect.contains(Point(x: 5, y: 20)))
        let exclude = CombineKernel.combine([Self.a, Self.b, Self.c], operation: .exclude)
        // Covered once: in; twice: out; three times: in.
        #expect(exclude.contains(Point(x: 5, y: 20)))
        #expect(!exclude.contains(Point(x: 25, y: 20)))
        #expect(exclude.contains(Point(x: 32, y: 20)))
    }

    @Test func combineEdgeCases() {
        #expect(CombineKernel.combine([], operation: .union).isEmpty)
        #expect(CombineKernel.combine([.empty, .empty], operation: .union).isEmpty)
        #expect(!CombineKernel.combine([Self.a], operation: .subtract).isEmpty)
        // An empty member empties an intersection; an empty bottom member empties a subtraction.
        #expect(CombineKernel.combine([Self.a, .empty], operation: .intersect).isEmpty)
        #expect(CombineKernel.combine([Self.a, .empty, Self.b], operation: .intersect).isEmpty)
        #expect(CombineKernel.combine([.empty, Self.a, Self.b], operation: .subtract).isEmpty)
    }
}
