import WTGeometry
import CoreGraphics
import Foundation
import Testing
@testable import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// FX-018, FX-019, FX-022 (extrusions), FX-025, FX-026, FX-029 (blends), FX-038 (envelopes) and
/// FX-042 (perspective): the derived drawing of the wrapper kinds.
@Suite struct LiveGroupTests {
    typealias C = ReferenceCorpus

    static func square(_ rect: Rect, _ color: Color = C.orange) -> DisplayItem {
        C.path(DisplayPath(rect: rect), [C.fill(color), C.stroke(.black, width: 1)])
    }

    // MARK: Extrusions

    static func solver(_ spec: ExtrudeSpec, rect: Rect = Rect(x: 0, y: 0, width: 40, height: 40)) -> (ExtrudeSolver, [ExtrudeFace]) {
        let solver = ExtrudeSolver(spec: spec, bounds: rect)
        let polygons = ExtrudeSolver.polygons(DisplayPath(rect: rect).contours, steps: spec.effectiveSurfaceSteps)
        return (solver, solver.faces(polygons))
    }

    @Test func zeroLengthGivesTheFrontFaceOnly() {
        let (_, faces) = Self.solver(ExtrudeSpec(length: 0, vanishingPoint: Point(x: 200, y: 0)))
        #expect(faces.count == 1 && faces[0].kind == .front)
        let entries = ExtrudeResolver.entries(ExtrudeSpec(length: 0, vanishingPoint: Point(x: 200, y: 0)), children: [Self.square(Rect(x: 0, y: 0, width: 40, height: 40))])
        #expect(entries.count == 1 && entries[0].origin == 0)
    }

    @Test func aVanishingPointAtInfinityGivesAnOrthographicBox() {
        let rect = Rect(x: 0, y: 0, width: 40, height: 40)
        let (_, faces) = Self.solver(ExtrudeSpec(length: 30, vanishingPoint: Point(x: 1e9, y: 1e9)), rect: rect)
        let front = faces.first { $0.kind == .front }!.polygon
        let rear = faces.first { $0.kind == .rear }!.polygon
        // The rear face is the front face translated: same edge lengths, no perspective scaling.
        for index in front.indices {
            let next = (index + 1) % front.count
            #expect(abs(front[index].distance(to: front[next]) - rear[index].distance(to: rear[next])) < 1e-3)
        }
        let shift = rear[0] - front[0]
        #expect(abs(shift.length - 30) < 1e-3)
        // Non-finite: straight behind, the rear face on the front face.
        let (_, behind) = Self.solver(ExtrudeSpec(length: 30, vanishingPoint: Point(x: .infinity, y: 0)), rect: rect)
        #expect(behind.first { $0.kind == .rear }!.polygon == behind.first { $0.kind == .front }!.polygon)
        #expect(behind.filter { $0.kind == .side && $0.facesViewer }.isEmpty)
    }

    @Test func sidesNeverSelfIntersectForConvexOutlines() {
        for (index, rotation) in [(0.0, 0.0, 0.0), (20, 35, 10), (-40, 10, 80), (60, -30, 0)].enumerated() {
            let spec = ExtrudeSpec(length: 50, vanishingPoint: Point(x: 150 - Double(index) * 90, y: -60), rotationX: rotation.0, rotationY: rotation.1, rotationZ: rotation.2)
            let (_, faces) = Self.solver(spec, rect: Rect(x: 10, y: 20, width: 40, height: 30))
            for face in faces where face.kind == .side {
                let p = face.polygon
                // A quad self-intersects when a pair of opposite edges cross.
                #expect(!Self.properlyCross(p[0], p[1], p[2], p[3]), "rotation \(rotation)")
                #expect(!Self.properlyCross(p[1], p[2], p[3], p[0]), "rotation \(rotation)")
            }
        }
    }

    /// Whether segments ab and cd cross at interior points of both.
    static func properlyCross(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        guard let hit = Line(start: a, end: b).intersection(with: Line(start: c, end: d)) else {
            return false
        }
        let inside = { (value: Double) -> Bool in value > 1e-6 && value < 1 - 1e-6 }
        return inside(hit.t) && inside(hit.u)
    }

    @Test func facesAreCulledAndSortedBackToFront() {
        let (_, faces) = Self.solver(ExtrudeSpec(length: 40, vanishingPoint: Point(x: 200, y: -100)))
        let visible = ExtrudeSolver.visibleSorted(faces)
        #expect(visible.contains { $0.kind == .front })
        #expect(!visible.contains { $0.kind == .rear })
        #expect(zip(visible, visible.dropFirst()).allSatisfy { $0.depth >= $1.depth })
        // Toward the vanishing point up and right: the top and right sides show.
        #expect(visible.filter { $0.kind == .side }.count == 2)
    }

    @Test func aChamferProfileOnASquareYieldsEightSideFacets() {
        let chamfer = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 6, y: -6), Point(x: 30, y: -6)], closed: false)
        let spec = ExtrudeSpec(length: 30, vanishingPoint: Point(x: 200, y: 0), profile: .init(kind: .bevel, path: chamfer, steps: 2))
        #expect(ProfileSweep.rings(spec).count == 3)
        let (_, faces) = Self.solver(spec)
        #expect(faces.filter { $0.kind == .side }.count == 8)
        // Static profiles offset along one direction; an empty profile reads as none.
        let fixed = ExtrudeSpec(length: 30, profile: .init(kind: .staticAngle, path: chamfer, angle: 90, steps: 4))
        #expect(ProfileSweep.directions([.zero, Point(x: 1, y: 0), Point(x: 0, y: 1)], kind: .staticAngle, angle: 90, orientation: 1).allSatisfy { approx($0.dy, -1) })
        #expect(ProfileSweep.rings(fixed).count >= 3)
        #expect(ProfileSweep.rings(ExtrudeSpec(length: 30, profile: .init(kind: .bevel, path: DisplayPath(), steps: 3))).count == 4)
        // A profile with no horizontal extent spreads by arc length.
        let vertical = ExtrudeSpec(length: 30, profile: .init(kind: .bevel, path: DisplayPath(polygon: [.zero, Point(x: 0, y: -5)], closed: false)))
        #expect(ProfileSweep.rings(vertical).last!.depth == 30)
    }

    @Test func twistTurnsTheRingsContinuously() {
        let spec = ExtrudeSpec(length: 60, vanishingPoint: Point(x: 1e7, y: 0), profile: .init(steps: 36, twist: 360))
        let rings = ProfileSweep.rings(spec)
        #expect(rings.count == 37)
        let center = Point(x: 20, y: 20)
        var previous = Point(x: 40, y: 20)
        for ring in rings.dropFirst() {
            let turned = ProfileSweep.twist(Point(x: 40, y: 20), about: center, degrees: 360 * ring.depth / 60)
            #expect(turned.distance(to: previous) < 4)
            previous = turned
        }
        #expect(approx(previous, Point(x: 40, y: 20), tolerance: 1e-9))
        #expect(ProfileSweep.twist(previous, about: center, degrees: .nan) == previous)
    }

    @Test func lightsAndShading() {
        for direction in ExtrudeSpec.LightDirection.allCases where direction != .none {
            let vector = ExtrudeShading.vector(direction)!
            #expect(approx(vector.length, 1))
            #expect(vector.z < 0)
        }
        #expect(ExtrudeShading.vector(.none) == nil)
        #expect(ExtrudeShading.vector(.front) == Point3(x: 0, y: 0, z: -1))
        // Ambient 100 with no lights is Flat: the fill colour itself.
        let flat = ExtrudeSpec(ambient: 100)
        #expect(ExtrudeShading.intensity(normal: Point3(x: 1, y: 0, z: 0), spec: flat) == 1)
        #expect(ExtrudeShading.shaded(C.orange, intensity: 1) == C.orange)
        let lit = ExtrudeSpec(ambient: 0, light1: .init(direction: .left, intensity: 100))
        #expect(ExtrudeShading.intensity(normal: Point3(x: -1, y: 0, z: 0), spec: lit) > ExtrudeShading.intensity(normal: Point3(x: 1, y: 0, z: 0), spec: lit))
        #expect(ExtrudeShading.baseColor(of: .gradient(Gradient(.linear, from: .black, to: .white))) == Color(white: 0.5))
        #expect(ExtrudeShading.baseColor(of: nil) == Color(white: 0.6))
    }

    @Test func extrusionEntriesHitSidesAsTheGroupAndTheFrontAsTheChild() {
        let group = DisplayItem.group(GroupItem(children: [Self.square(Rect(x: 20, y: 60, width: 40, height: 40)), Self.square(Rect(x: 100, y: 100, width: 5, height: 5))], live: .extrude(ExtrudeSpec(length: 60, vanishingPoint: Point(x: 150, y: 0), ambient: 30, light1: .init(direction: .topLeft, intensity: 80)))))
        let list = DisplayList(canvas: "x", items: [group])
        let tester = HitTester(displayList: list, viewport: Viewport(size: Size(width: 200, height: 200)), options: HitOptions(pickPoints: false))
        // A side (above the front face, toward the vanishing point): the extrusion.
        let side = tester.hitTest(viewPoint: Point(x: 50, y: 55))
        #expect(side.first?.itemPath == [0] && side.first?.leafPath == [0])
        // The front face with Subselect: the child.
        let sub = HitTester(displayList: list, viewport: Viewport(size: Size(width: 200, height: 200)), options: HitOptions(subselect: true, pickPoints: false))
        #expect(sub.hitTest(viewPoint: Point(x: 40, y: 80)).first?.leafPath == [0, 0])
        // A second child draws flat above.
        #expect(EffectPipeline.derived(GroupItem(children: [Self.square(Rect(x: 20, y: 60, width: 40, height: 40)), Self.square(Rect(x: 100, y: 100, width: 5, height: 5))], live: .extrude(ExtrudeSpec(length: 60, vanishingPoint: Point(x: 150, y: 0))))).entries.last?.origin == 1)
    }

    @Test func surfaceKindsAndNestedExtrusions() {
        let child = Self.square(Rect(x: 20, y: 20, width: 30, height: 30))
        for surface in ExtrudeSpec.SurfaceKind.allCases {
            let entries = ExtrudeResolver.entries(ExtrudeSpec(length: 30, vanishingPoint: Point(x: 100, y: -50), surface: surface), children: [child])
            #expect(entries.contains { $0.origin == 0 }, "\(surface)")
            #expect(entries.contains { $0.origin == nil }, "\(surface)")
        }
        let inner = DisplayItem.group(GroupItem(children: [child], live: .extrude(ExtrudeSpec(length: 10))))
        #expect(ExtrudeResolver.nestedChild(inner) == child)
        #expect(ExtrudeResolver.entries(ExtrudeSpec(length: 10), children: []).isEmpty)
        #expect(ExtrudeSpec(length: 99_999).effectiveLength == 32_000)
        #expect(ExtrudeSpec(surfaceSteps: 0).effectiveSurfaceSteps == 10)
    }

    @Test func aRemoteEditToTheChildResolvesTheExtrusionOnce() {
        func group(_ width: Double) -> GroupItem {
            GroupItem(children: [Self.square(Rect(x: 20, y: 20, width: width, height: 30))], live: .extrude(ExtrudeSpec(length: 30, vanishingPoint: Point(x: 100, y: -50))))
        }
        let before = group(30)
        _ = EffectPipeline.derived(before)
        let after = group(31)
        #expect(!EffectPipeline.isResolved(after))
        _ = DisplayItem.group(after).bounds
        #expect(EffectPipeline.isResolved(after) && EffectPipeline.isResolved(before))
    }

    @Test func solvingAFiveHundredPointOutlineAtTwentyStepsIsFast() {
        let polygon = (0..<500).map { index -> Point in
            let angle = Double(index) / 500 * 2 * .pi
            return Point(x: 100 + 60 * cos(angle), y: 100 + 60 * sin(angle))
        }
        let spec = ExtrudeSpec(length: 50, vanishingPoint: Point(x: 300, y: -100), rotationX: 10, profile: .init(steps: 20))
        let solver = ExtrudeSolver(spec: spec, bounds: Rect(boundingPoints: polygon))
        let clock = ContinuousClock()
        var faces: [ExtrudeFace] = []
        let elapsed = clock.measure { faces = ExtrudeSolver.visibleSorted(solver.faces([polygon])) }
        #expect(!faces.isEmpty)
        #if DEBUG
        print("500-point outline, 20 steps: \(elapsed) (debug)")
        #else
        print("500-point outline, 20 steps: \(elapsed) (release)")
        #expect(elapsed < .milliseconds(5), "\(elapsed)")
        #endif
    }

    // MARK: Blends

    static let circle = C.path(DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 20, height: 20)), [C.fill(.black)])
    static let box = C.path(DisplayPath(rect: Rect(x: 100, y: -10, width: 40, height: 40)), [C.fill(.white)])

    @Test func stepsSitBetweenTheKeyObjects() {
        let entries = BlendResolver.entries(BlendSpec(steps: 3), children: [Self.circle, Self.box])
        #expect(entries.map(\.origin) == [0, nil, nil, nil, 1])
        #expect(BlendInterpolator.parameters(steps: 3, first: 0, last: 1) == [0.25, 0.5, 0.75])
        #expect(BlendInterpolator.parameters(steps: 0, first: 0, last: 1).isEmpty)
        // Range: first 20%, last 80%, reversed ranges swap.
        let ranged = BlendResolver.entries(BlendSpec(steps: 1, rangeFirst: 80, rangeLast: 20), children: [Self.circle, Self.box])
        guard case .path(let middle) = ranged[1].item else { return }
        #expect(approx(middle.appearance.fills[0].paint.color!.red, 0.5, tolerance: 1e-9))
    }

    @Test func matchedBlendPointsBlendACircleIntoASquareWithoutRotation() {
        // The circle's top anchor (3) against the square's top-left corner (0).
        let spec = BlendSpec(steps: 1, blendPoints: [BlendPoint(child: 0, anchor: 3), BlendPoint(child: 1, anchor: 0)])
        let entries = BlendResolver.entries(spec, children: [Self.circle, Self.box])
        guard case .path(let step) = entries[1].item else {
            Issue.record("expected a step path")
            return
        }
        // The step's start point lies halfway between the two blend points.
        let start = step.path.contours[0].startPoint!
        #expect(approx(start, Point(x: 55, y: -5), tolerance: 1e-9))
    }

    @Test func pathMatchingEqualizesSegmentCounts() {
        let triangle = Contour(polygon: [.zero, Point(x: 10, y: 0), Point(x: 5, y: 8)])
        let hexagon = Contour(polygon: (0..<6).map { Point(x: 5 + 5 * cos(Double($0) * .pi / 3), y: 5 + 5 * sin(Double($0) * .pi / 3)) })
        let (a, b) = PathMatcher.matched(triangle, hexagon)
        #expect(a.segments.count == 6 && b.segments.count == 6)
        let open = Contour(polygon: [.zero, Point(x: 10, y: 0)], closed: false)
        let (c, d) = PathMatcher.matched(open, triangle)
        #expect(!c.isClosed && !d.isClosed && c.segments.count == d.segments.count)
        #expect(PathMatcher.rotated(triangle, toStartAt: 2).startPoint == Point(x: 5, y: 8))
        #expect(PathMatcher.rotated(open, toStartAt: 1) == open)
        #expect(PathMatcher.rotated(triangle, toStartAt: 9).startPoint == .zero)
    }

    @Test func compositesAndGroupsPairSubpaths() {
        let a = BlendShape(subpaths: [0, 1, 2].map { BlendSubpath(contour: Contour(polygon: [Point(x: Double($0) * 10, y: 0), Point(x: Double($0) * 10 + 5, y: 0), Point(x: Double($0) * 10, y: 5)]), appearance: Appearance()) })
        let b = BlendShape(subpaths: [2, 0].map { BlendSubpath(contour: Contour(polygon: [Point(x: Double($0) * 10, y: 50), Point(x: Double($0) * 10 + 5, y: 50), Point(x: Double($0) * 10, y: 55)]), appearance: Appearance()) })
        #expect(PathMatcher.pairs(a, b, type: .normal, order: .stacking).map { [$0.0, $0.1] } == [[0, 0], [1, 1], [2, 1]])
        #expect(PathMatcher.pairs(a, b, type: .normal, order: .positional).map { [$0.0, $0.1] } == [[0, 1], [1, 0], [2, 0]])
        #expect(PathMatcher.pairs(a, b, type: .vertical, order: .positional).map { [$0.0, $0.1] } == [[0, 1], [1, 0], [2, 0]])
        #expect(PathMatcher.pairs(a, b, type: .horizontal, order: .positional).count == 3)
        // A group of paths is a key object; a group with text is not.
        #expect(BlendShape(.group(GroupItem(children: [Self.circle, Self.box])), blendPoint: nil)?.subpaths.count == 2)
        #expect(BlendShape(.group(GroupItem(children: [.text(TextRunItem(text: "t", origin: .zero, bounds: Rect(x: 0, y: 0, width: 5, height: 5)))])), blendPoint: nil) == nil)
        #expect(BlendShape(C.path(DisplayPath(), [C.fill(.black)]), blendPoint: nil) == nil)
    }

    @Test func appearancesInterpolate() {
        let red = Color(red: 1, green: 0, blue: 0)
        let blue = Color(red: 0, green: 0, blue: 1)
        #expect(BlendInterpolator.paint(.solid(red), .solid(blue), t: 0.5) == .solid(Color(red: 0.5, green: 0, blue: 0.5)))
        guard case .gradient(let mixed) = BlendInterpolator.paint(.gradient(Gradient(.linear, from: red, to: blue, axis: .init(start: .zero, end: Point(x: 10, y: 0)))), .solid(.white), t: 0.5) else {
            Issue.record("a solid colour against a gradient blends as a gradient")
            return
        }
        #expect(mixed.stops.count == 2)
        guard case .gradient = BlendInterpolator.paint(.solid(.white), .gradient(Gradient(.linear, from: red, to: blue)), t: 0.2) else { return }
        #expect(BlendInterpolator.paint(.pattern(PatternPaint(bitmap: .checker, color: red)), .solid(blue), t: 0.4) == .pattern(PatternPaint(bitmap: .checker, color: red)))
        let a = Appearance([C.fill(red), C.stroke(.black, width: 2, dash: [2, 2])])
        let b = Appearance([C.fill(blue), C.stroke(.black, width: 6, dash: [4, 4])])
        let half = BlendInterpolator.appearance(a, b, t: 0.5)
        #expect(half.strokes[0].style.width == 4)
        #expect(half.strokes[0].style.dash == [3, 3])
        // Mismatched stacks switch at the midpoint.
        #expect(BlendInterpolator.appearance(a, Appearance([C.fill(blue)]), t: 0.4) == a)
        #expect(BlendInterpolator.appearance(Appearance([C.stroke(.black, width: 1)]), Appearance([C.fill(blue)]), t: 0.6) == Appearance([C.fill(blue)]))
    }

    @Test func defaultStepsComeFromTheColourDifference() {
        let black = BlendShape(Self.circle, blendPoint: nil)!
        let white = BlendShape(Self.box, blendPoint: nil)!
        #expect(BlendInterpolator.defaultSteps([black, white]) == 100)
        #expect(BlendInterpolator.defaultSteps([black, black]) == 25)
        #expect(BlendInterpolator.defaultSteps([black]) == 25)
        let grey = BlendShape(C.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 5, height: 5)), [C.fill(Color(white: 0.02))]), blendPoint: nil)!
        let steps = BlendInterpolator.defaultSteps([black, grey])
        #expect(steps > 1 && steps < 100)
        #expect(approx(BlendInterpolator.deltaE(.white, .black), 100, tolerance: 0.01))
        #expect(BlendResolver.entries(BlendSpec(), children: [Self.circle, Self.box]).count == 102)
    }

    static let spine = C.path(AttributeCorpus.wave(in: Rect(x: 0, y: 100, width: 200, height: 40)), [C.stroke(.black, width: 1)])

    @Test func blendsOnAPathStartAndEndOnItsEndPoints() {
        let spec = BlendSpec(steps: 4, path: 0, showPath: true, rotateOnPath: true)
        let entries = BlendResolver.entries(spec, children: [Self.spine, Self.circle, Self.box])
        #expect(entries[0].origin == 0 && entries[0].visible)
        let first = entries.first { $0.origin == 1 }!.item.geometricBounds!
        let last = entries.first { $0.origin == 2 }!.item.geometricBounds!
        #expect(approx(first.center, Point(x: 0, y: 120), tolerance: 1e-6))
        #expect(approx(last.center, Point(x: 200, y: 120), tolerance: 1e-6))
        // Reversing the path reverses the blend.
        let reversedSpine = C.path(DisplayPath(contours: AttributeCorpus.wave(in: Rect(x: 0, y: 100, width: 200, height: 40)).contours.map { $0.reversed() }), [C.stroke(.black, width: 1)])
        let reversed = BlendResolver.entries(spec, children: [reversedSpine, Self.circle, Self.box])
        #expect(approx(reversed.first { $0.origin == 1 }!.item.geometricBounds!.center, Point(x: 200, y: 120), tolerance: 1e-6))
        // Without rotate on path a square key object keeps its orientation.
        let upright = BlendResolver.entries(BlendSpec(steps: 4, path: 0, rotateOnPath: false), children: [Self.spine, Self.circle, Self.box])
        #expect(approx(upright.first { $0.origin == 2 }!.item.geometricBounds!.width, 40, tolerance: 1e-9))
        #expect(!upright[0].visible)
        // A path index that is not a path, or out of range: straight.
        #expect(BlendResolver.entries(BlendSpec(steps: 1, path: 7), children: [Self.circle, Self.box]).count == 3)
        #expect(OnPathDistributor(Self.circle, rotates: true) != nil)
        #expect(OnPathDistributor(.image(ImageItem(assetID: "i", rect: .zero)), rotates: true) == nil)
    }

    @Test func blendStepsHitAsTheBlendAndKeyObjectsAsThemselves() {
        let group = DisplayItem.group(GroupItem(children: [Self.circle, Self.box, .text(TextRunItem(text: "x", origin: Point(x: 300, y: 10), bounds: Rect(x: 300, y: 0, width: 10, height: 10)))], live: .blend(BlendSpec(steps: 3))))
        let tester = HitTester(displayList: DisplayList(canvas: "b", items: [group]), viewport: Viewport(size: Size(width: 400, height: 100)), options: HitOptions(subselect: true, pickPoints: false))
        #expect(tester.hitTest(viewPoint: Point(x: 10, y: 10)).first?.leafPath == [0, 0])
        #expect(tester.hitTest(viewPoint: Point(x: 60, y: 10)).first?.leafPath == [0])
        #expect(tester.hitTest(viewPoint: Point(x: 305, y: 5)).first?.leafPath == [0, 2])
        // Fewer than two key objects: the children as they are.
        #expect(BlendResolver.entries(BlendSpec(), children: [Self.circle]).map(\.origin) == [0])
    }

    @Test func aThousandStepBlendOfFiftyPointPathsIsFast() {
        let a = C.path(DisplayPath(polygon: (0..<50).map { Point(x: 10 * cos(Double($0) / 50 * 2 * .pi), y: 10 * sin(Double($0) / 50 * 2 * .pi)) }), [C.fill(.black)])
        let b = C.path(DisplayPath(polygon: (0..<50).map { Point(x: 300 + 20 * cos(Double($0) / 50 * 2 * .pi), y: 20 * sin(Double($0) / 50 * 2 * .pi)) }), [C.fill(.white)])
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure { count = BlendResolver.entries(BlendSpec(steps: 1000), children: [a, b]).count }
        #expect(count == 1002)
        #if DEBUG
        print("1,000-step blend of 50-point paths: \(elapsed) (debug)")
        #else
        print("1,000-step blend of 50-point paths: \(elapsed) (release)")
        #expect(elapsed < .milliseconds(10), "\(elapsed)")
        #endif
    }

    // MARK: Envelopes

    static let source = Rect(x: 0, y: 0, width: 100, height: 60)

    @Test func aRectangularEnvelopeEqualToTheSourceIsIdentity() {
        let warp = EnvelopeWarp(EnvelopeSpec(contour: DisplayPath(rect: Self.source), sourceBounds: Self.source, corners: [0, 1, 2, 3]))!
        for point in [Point(x: 0, y: 0), Point(x: 37, y: 11), Point(x: 100, y: 60), Point(x: 80, y: 45)] {
            #expect(approx(warp.map(point), point, tolerance: 1e-9))
        }
    }

    @Test func movingOneCornerLeavesTheOppositeEdgesInPlace() {
        let moved = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 130, y: 90), Point(x: 0, y: 60)])
        let warp = EnvelopeWarp(EnvelopeSpec(contour: moved, sourceBounds: Self.source, corners: [0, 1, 2, 3]))!
        // The top and left edges (not adjacent to the moved bottom-right corner) stay put.
        for t in stride(from: 0.0, through: 1, by: 0.1) {
            #expect(approx(warp.map(Point(x: 100 * t, y: 0)), Point(x: 100 * t, y: 0), tolerance: 1e-9))
            #expect(approx(warp.map(Point(x: 0, y: 60 * t)), Point(x: 0, y: 60 * t), tolerance: 1e-9))
        }
        #expect(approx(warp.map(Point(x: 100, y: 60)), Point(x: 130, y: 90), tolerance: 1e-9))
        // The inverse map places carets.
        let point = Point(x: 63, y: 41)
        #expect(approx(warp.inverse(warp.map(point))!, point, tolerance: 1e-6))
        #expect(warp.mesh(divisions: 4).elements.count == 5 * 2 * 33)
    }

    @Test func warpedCurvesDeviateLessThanATenthOfAPoint() {
        let warp = EnvelopeWarp(EnvelopeSpec(contour: EffectCorpus.arch(Self.source, rise: 25), sourceBounds: Self.source))!
        let corpus = [DisplayPath(ellipseIn: Rect(x: 10, y: 10, width: 80, height: 40)), EffectCorpus.star(Point(x: 50, y: 30), outer: 28, inner: 12), AttributeCorpus.wave(in: Rect(x: 5, y: 5, width: 90, height: 50))]
        for path in corpus {
            for contour in path.contours {
                let warped = CurveWarp.map([contour], map: warp.map)[0]
                // Every warped piece is within tolerance of the exact mapping of its source span.
                var worst = 0.0
                for segment in contour.explicitSegments {
                    for t in stride(from: 0.0, through: 1, by: 0.05) {
                        let exact = warp.map(segment.evaluate(t))
                        let distance = warped.segments.map { $0.nearestPoint(to: exact).distance }.min()!
                        worst = max(worst, distance)
                    }
                }
                #expect(worst < 0.1)
            }
        }
    }

    @Test func envelopeFallbacks() {
        // Corners that name no anchor fall back to the anchors nearest the bounds' corners.
        let fallback = EnvelopeWarp(EnvelopeSpec(contour: DisplayPath(rect: Self.source), sourceBounds: Self.source, corners: [nil, 99, 2, 2]))
        #expect(fallback != nil)
        #expect(EnvelopeWarp.corners([0, 0, 0, 0], anchors: [.zero, Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1)]) == [0, 1, 2, 3])
        // Fewer than four anchors, no closed contour or an empty source: unwarped.
        #expect(EnvelopeWarp(EnvelopeSpec(contour: DisplayPath(polygon: [.zero, Point(x: 10, y: 0), Point(x: 5, y: 5)]), sourceBounds: Self.source)) == nil)
        #expect(EnvelopeWarp(EnvelopeSpec(contour: DisplayPath(polygon: [.zero, Point(x: 10, y: 0)], closed: false), sourceBounds: Self.source)) == nil)
        #expect(EnvelopeWarp(EnvelopeSpec(contour: DisplayPath(rect: Self.source), sourceBounds: .zero)) == nil)
        let child = Self.square(Rect(x: 10, y: 10, width: 20, height: 20))
        #expect(EnvelopeResolver.entries(EnvelopeSpec(contour: DisplayPath(), sourceBounds: Self.source), children: [child]).map(\.item) == [child])
        // Counter-clockwise contours and multi-segment edges.
        let reversed = DisplayPath(polygon: [Point(x: 0, y: 0), Point(x: 0, y: 60), Point(x: 50, y: 70), Point(x: 100, y: 60), Point(x: 100, y: 0)])
        let warp = EnvelopeWarp(EnvelopeSpec(contour: reversed, sourceBounds: Self.source, corners: [0, 4, 3, 1]))!
        #expect(approx(warp.map(Point(x: 0, y: 0)), .zero, tolerance: 1e-9))
        #expect(warp.map(Point(x: 50, y: 60)).y > 60)
        #expect(EnvelopeWarp.follows(0, 1, 2, 3, count: 4) && !EnvelopeWarp.follows(0, 3, 2, 1, count: 4))
        #expect(EnvelopeWarp.fit([CubicBezier(p0: .zero, p1: .zero, p2: .zero, p3: .zero), CubicBezier(p0: .zero, p1: .zero, p2: .zero, p3: .zero)]).p3 == .zero)
        // Show Map adds the mesh; text maps as glyph outlines.
        let text = DisplayItem.text(TextRunItem(text: "t", origin: Point(x: 10, y: 50), bounds: Rect(x: 10, y: 40, width: 20, height: 10)))
        let entries = EnvelopeResolver.entries(EnvelopeSpec(contour: DisplayPath(rect: Self.source), sourceBounds: Self.source, showMap: true), children: [text, .image(ImageItem(assetID: "i", rect: Rect(x: 0, y: 0, width: 5, height: 5)))])
        #expect(entries.count == 3 && entries.last?.origin == nil)
    }

    // MARK: Perspective

    static let grid = PerspectiveGridSpec.defaultGrid(page: Rect(x: 0, y: 0, width: 256, height: 160))

    @Test func aUnitSquareOnTheFloorProjectsToTheReferenceQuadrilateral() {
        let homography = PlaneProjector.homography(Self.grid, plane: .floorRight)
        // N = (128, 120), R = (256, 80), L = (0, 80), cell 36: |R − N| = |L − N| = √(128² + 40²).
        let d = (128.0 * 128 + 40 * 40).squareRoot()
        let k = 36 / d
        func expected(_ u: Double, _ v: Double) -> Point {
            let w = 1 + k * u + k * v
            return Point(x: (128 + 256 * k * u + 0 * k * v) / w, y: (120 + 80 * k * u + 80 * k * v) / w)
        }
        for (u, v) in [(0.0, 0.0), (1, 0), (1, 1), (0, 1)] {
            #expect(approx(homography.apply(Point(x: u, y: v)), expected(u, v), tolerance: 1e-9))
        }
        #expect(approx(homography.apply(.zero), Point(x: 128, y: 120), tolerance: 1e-12))
        // Receding lines run to the vanishing points.
        #expect(homography.apply(Point(x: 1e9, y: 0)).distance(to: Self.grid.rightVP) < 1e-3)
        #expect(homography.apply(Point(x: 0, y: 1e9)).distance(to: Self.grid.leftVP) < 1e-3)
        // Moving a vanishing point re-projects consistently.
        var moved = Self.grid
        moved.rightVP = Point(x: 300, y: 80)
        let other = PlaneProjector.homography(moved, plane: .floorRight)
        #expect(other.apply(Point(x: 1e9, y: 0)).distance(to: moved.rightVP) < 1e-3)
        #expect(approx(other.apply(.zero), Point(x: 128, y: 120), tolerance: 1e-12))
        #expect(homography.inverted!.apply(homography.apply(Point(x: 0.3, y: 0.7))).distance(to: Point(x: 0.3, y: 0.7)) < 1e-9)
        #expect(Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 0]).inverted == nil)
        #expect(Homography.identity.apply(Point(x: 2, y: 3)) == Point(x: 2, y: 3))
    }

    @Test func everyPlaneOnOneTwoAndThreePointGrids() {
        for count in [1, 2, 3] {
            var grid = Self.grid
            grid.vanishingPoints = count
            for plane in PerspectiveSpec.Plane.allCases {
                let spec = PerspectiveSpec(grid: grid, plane: plane, cellPosition: Point(x: -1, y: 0.5))
                let placement = PerspectivePlacement(spec, flat: Rect(x: 0, y: 0, width: 36, height: 36))!
                let corner = placement.map(Point(x: 0, y: 36))
                #expect(corner.isFinite, "\(count) \(plane)")
                #expect(approx(placement.inverse(placement.map(Point(x: 10, y: 20)))!, Point(x: 10, y: 20), tolerance: 1e-6), "\(count) \(plane)")
            }
        }
        // Planes read across grid kinds.
        var one = Self.grid
        one.vanishingPoints = 1
        #expect(PerspectiveSpec(grid: one, plane: .rightWall).effectivePlane == .wall)
        #expect(PerspectiveSpec(grid: one, plane: .floorLeft).effectivePlane == .floor)
        #expect(PerspectiveSpec(grid: Self.grid, plane: .wall).effectivePlane == .leftWall)
        #expect(PerspectiveSpec(grid: Self.grid, plane: .floor).effectivePlane == .floorLeft)
        #expect(PerspectiveGridSpec(vanishingPoints: 0, cellSize: 0).effectiveVanishingPoints == 2)
        #expect(PerspectiveGridSpec(cellSize: -3).effectiveCellSize == 36)
        // The frontal wall of a one-point grid is affine: the object keeps its shape.
        let frontal = PerspectivePlacement(PerspectiveSpec(grid: one, plane: .wall), flat: Rect(x: 0, y: 0, width: 36, height: 36))!
        #expect(approx(frontal.map(Point(x: 36, y: 36)).distance(to: frontal.map(Point(x: 0, y: 36))), 36, tolerance: 1e-9))
        // Three-point walls taper toward the vertical vanishing point, from above or below.
        var three = Self.grid
        three.vanishingPoints = 3
        three.verticalVP = Point(x: 128, y: 500)
        #expect(PerspectivePlacement(PerspectiveSpec(grid: three, plane: .leftWall), flat: Rect(x: 0, y: 0, width: 36, height: 36)) != nil)
    }

    @Test func projectedCurvesDeviateLessThanATenthOfAPoint() {
        let placement = PerspectivePlacement(PerspectiveSpec(grid: Self.grid, plane: .leftWall, cellPosition: Point(x: -2, y: 0.2), cellWidth: 1.5, cellHeight: 1.5), flat: Rect(x: 0, y: 0, width: 60, height: 60))!
        for path in [DisplayPath(ellipseIn: Rect(x: 0, y: 0, width: 60, height: 60)), EffectCorpus.star(Point(x: 30, y: 30), outer: 30, inner: 12)] {
            let warped = CurveWarp.map(path.contours, map: placement.map)[0]
            var worst = 0.0
            for segment in path.contours[0].explicitSegments {
                for t in stride(from: 0.0, through: 1, by: 0.05) {
                    let exact = placement.map(segment.evaluate(t))
                    worst = max(worst, warped.segments.map { $0.nearestPoint(to: exact).distance }.min()!)
                }
            }
            #expect(worst < 0.1)
        }
    }

    @Test func perspectiveEntriesAndFallbacks() {
        let child = Self.square(Rect(x: 0, y: 0, width: 36, height: 36))
        let spec = PerspectiveSpec(grid: Self.grid, plane: .floorRight, cellPosition: Point(x: 0.2, y: 0.2), flipped: true)
        let entries = PerspectiveResolver.entries(spec, children: [child, Self.circle])
        #expect(entries.map(\.origin) == [0, 1])
        #expect(entries[1].item == Self.circle)
        #expect(PerspectiveResolver.entries(spec, children: []).isEmpty)
        #expect(PerspectivePlacement(spec, flat: .null) == nil)
        // A grid change repaints only attached objects: bounds follow the projection.
        var moved = spec
        moved.grid.rightVP = Point(x: 400, y: 80)
        #expect(DisplayItem.group(GroupItem(children: [child], live: .perspective(spec))).bounds != DisplayItem.group(GroupItem(children: [child], live: .perspective(moved))).bounds)
        // Flipped walls mirror horizontally, floors vertically.
        let wall = PerspectivePlacement(PerspectiveSpec(grid: Self.grid, plane: .rightWall, flipped: true), flat: Rect(x: 0, y: 0, width: 36, height: 36))!
        #expect(wall.cell(of: Point(x: 0, y: 36)) == Point(x: 1, y: 0))
        let floor = PerspectivePlacement(spec, flat: Rect(x: 0, y: 0, width: 36, height: 36))!
        #expect(approx(floor.cell(of: Point(x: 0, y: 36)), Point(x: 0.2, y: 1.2), tolerance: 1e-9))
    }

    // MARK: Output

    /// A live wrapper's PDF equals that of the group of plain items it draws (what Release bakes).
    @Test(arguments: ["effectsExtrude", "effectsBlend", "effectsEnvelope", "effectsPerspective"])
    func pdfOfALiveWrapperEqualsItsReleasedGroup(name: String) throws {
        let reference = try #require(EffectCorpus.cases.first { $0.name == name })
        let released = DisplayList(canvas: reference.list.canvas, items: reference.list.items.map { item in
            guard case .group(let group) = item, group.live != nil else { return item }
            return .group(GroupItem(children: EffectPipeline.derived(group).entries.filter(\.visible).map(\.item)))
        })
        let viewport = Viewport(size: reference.viewSize)
        let renderer = CoreGraphicsRenderer(background: .white)
        let livePDF = try #require(renderer.renderPDF(reference.list, viewport: viewport))
        let bakedPDF = try #require(renderer.renderPDF(released, viewport: viewport))
        let live = try #require(PDFRasterizer.rasterize(livePDF, scale: 1))
        let baked = try #require(PDFRasterizer.rasterize(bakedPDF, scale: 1))
        #expect(PixelComparison(reference: live, candidate: baked, edgeTolerance: 0).passes)
    }

    @Test func aRemoteEditToOneKeyObjectReinterpolatesOnce() {
        func blend(_ size: Double) -> GroupItem {
            GroupItem(children: [Self.circle, C.path(DisplayPath(rect: Rect(x: 100, y: -10, width: size, height: 40)), [C.fill(.white)])], live: .blend(BlendSpec(steps: 7)))
        }
        _ = EffectPipeline.derived(blend(40))
        let edited = blend(41)
        #expect(!EffectPipeline.isResolved(edited))
        let bounds = DisplayItem.group(edited).bounds!
        #expect(EffectPipeline.isResolved(edited) && EffectPipeline.isResolved(blend(40)))
        #expect(bounds.maxX == 141)
    }

    // MARK: Keyline and warp sources

    @Test func keylineDrawsDerivedGeometryWithoutAppearanceEffects() {
        let keyline = CoreGraphicsRenderer(background: .white, viewMode: .keyline)
        let blend = DisplayItem.group(GroupItem(children: [Self.circle, Self.box], appearance: Appearance(effects: [EffectElement(.shadow(.init(offset: 5, opacity: 90)))]), live: .blend(BlendSpec(steps: 2))))
        let image = BitmapSurface(drawing: keyline.renderBitmap(DisplayList(canvas: "k", items: [blend]), viewport: Viewport(size: Size(width: 160, height: 60)))!)!
        // A step's hairline between the key objects.
        var dark = 0
        for x in 30..<90 where Int(image.pixel(x: x, y: 5).red) < 128 { dark += 1 }
        #expect(dark > 0)
    }

    @Test func warpSourcesFlattenEveryKind() {
        let items: [DisplayItem] = [
            .fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), paint: .solid(.black))),
            .stroke(StrokeItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), paint: .solid(.black))),
            .text(TextRunItem(text: "t", origin: .zero, bounds: Rect(x: 0, y: 0, width: 4, height: 4))),
            .image(ImageItem(assetID: "i", rect: Rect(x: 0, y: 0, width: 4, height: 4))),
            .group(GroupItem(children: [Self.circle, Self.box])),
            .group(GroupItem(children: [Self.circle, Self.box], live: .blend(BlendSpec(steps: 1)))),
            .path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), appearance: Appearance([C.fill(.black)], effects: [EffectElement(.duet(.init(mode: .rotate, copies: 3)))]))),
            .path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 4, height: 4)), appearance: Appearance([C.stroke(.black, width: 2, dash: [1, 1])]), transform: .scale(2))),
        ]
        let counts = items.map { WarpSource.plainPaths($0).count }
        #expect(counts == [1, 1, 1, 1, 2, 3, 1, 1])
        let baked = WarpSource.plainPaths(items[7])[0]
        #expect(baked.appearance.strokes[0].style.width == 4)
        #expect(baked.transform.isIdentity)
        #expect(WarpSource.mapped([], map: { $0 }) == nil)
    }
}
