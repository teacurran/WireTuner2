import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Fisheye Lens reshapes the outline wherever it passes through the lens, not only at its
/// points (path-effects.adoc, "Fisheye lens"; FX-032): a live ellipse converts to a path in the same
/// change (D-078), and one undo brings it back.
@Suite(.serialized) @MainActor struct FisheyeLensTests {
    typealias Fixture = DistortToolTests.Fixture

    /// An ellipse 160 × 100 about (150, 150): its four anchors at (70, 150), (150, 100), (230, 150)
    /// and (150, 200).
    static func addEllipse(_ f: Fixture) async throws -> OpID {
        let node = try #require(await f.document.perform(CreateShape(.ellipse, size: Size(width: 160, height: 100), transform: .translation(x: 70, y: 100),
                                                                     appearance: TestAppearance.filled)).value?.createdObjects.first)
        await f.document.settle()
        return node
    }

    /// `node`'s outline in pasteboard space (a shape's derived path, or the path's).
    static func outline(_ f: Fixture, _ node: OpID) -> [DistortContour] {
        Keylines.contours(of: node, document: f.document)
    }

    /// Points along `contours`, `count` per segment, and the end.
    static func samples(_ contours: [DistortContour], per count: Int) -> [[Point]] {
        contours.map { contour in
            contour.segments.flatMap { segment in (0..<count).map { segment.evaluate(Double($0) / Double(count)) } } + (contour.segments.last.map { [$0.p3] } ?? [])
        }
    }

    /// The farthest any of `points` lies from the polyline `line`.
    static func deviation(_ points: [Point], from line: [Point]) -> Double {
        points.map { point in
            zip(line, line.dropFirst()).map { DistortKernels.distance(from: point, toSegment: $0, $1) }.min() ?? .infinity
        }.max() ?? 0
    }

    /// How far `result` strays from `original` seen exactly through the lens, both ways.
    static func error(_ result: [DistortContour], _ original: [DistortContour], center: Point, radius: Double, perspective: Double) -> Double {
        let expected = samples(original, per: 400).map { $0.map { DistortKernels.fisheye($0, center: center, radius: radius, perspective: perspective) } }
        let actual = samples(result, per: 24), dense = samples(result, per: 200)
        return expected.indices.map { index in
            let coarse = expected[index].enumerated().filter { $0.offset % 16 == 0 }.map(\.element)
            return max(deviation(actual[index], from: expected[index]), deviation(coarse, from: dense[index]))
        }.max() ?? .infinity
    }

    /// The farthest a point of `result` lies from `original`'s outline (how much it changed).
    static func change(_ result: [DistortContour], _ original: [DistortContour]) -> Double {
        zip(samples(result, per: 24), samples(original, per: 400)).map { deviation($0, from: $1) }.max() ?? 0
    }

    /// The live paths on the default layer.
    static func paths(_ f: Fixture) -> [OpID] {
        ShapePointEditingTests.paths(f.document.state)
    }

    /// Drags `tool` from `from` to `to`, checking that the preview at the end of the drag is what
    /// the release writes; answers the preview.
    static func lens(_ f: Fixture, _ tool: FisheyeLensTool, _ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) async throws -> [DistortContour] {
        tool.mouseDown(TestEvents.point(from.x, from.y, modifiers))
        tool.mouseDragged(TestEvents.point(to.x, to.y, modifiers))
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        let preview = try #require(tool.targets.flatMap { targets in tool.kernel().map { targets.distorted($0).flatMap { $0 } } })
        tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
        await f.document.settle()
        return preview
    }

    enum Case: String, CaseIterable {
        /// A small lens inside the ellipse's bounds, over its outline between two anchors.
        case inside
        /// The lens across the ellipse's width: its side anchors on the lens edge.
        case edgeToEdge
        /// A lens larger than the ellipse, off its centre.
        case larger
    }

    @Test(arguments: Case.allCases)
    func aLiveEllipseSeenThroughTheLensChangesAlongItsOutline(_ lens: Case) async throws {
        let f = Fixture()
        let ellipse = try await Self.addEllipse(f)
        f.select([SelectionID(ellipse)])
        let original = Self.outline(f, ellipse)
        #expect(original[0].points.count == 4)
        let tool = FisheyeLensTool { 50 }
        tool.activate(in: f.context)
        let from: Point, to: Point, modifiers: KeyModifiers
        switch lens {
        case .inside:
            // Centred just inside the outline near 45°, (206.6, 114.6), radius 18: no anchor and
            // no handle end within it (the nearest handle end is 21.9 pt away).
            (from, to, modifiers) = (Point(x: 203, y: 120), Point(x: 221, y: 120), [.option])
        case .edgeToEdge:
            (from, to, modifiers) = (Point(x: 70, y: 150), Point(x: 230, y: 150), [])
        case .larger:
            (from, to, modifiers) = (Point(x: 160, y: 140), Point(x: 360, y: 140), [.option])
        }
        let changes = f.document.changeCount
        let center = modifiers.contains(.option) ? from : Point.lerp(from, to, 0.5)
        let radius = modifiers.contains(.option) ? from.distance(to: to) : from.distance(to: to) / 2
        let preview = try await Self.lens(f, tool, from, to, modifiers)
        #expect(f.document.changeCount == changes + 1, "one change")
        #expect(f.document.undoTitle == "Undo Fisheye lens")
        #expect(!f.document.state.isLive(ellipse), "the ellipse converted to a path")
        let path = try #require(Self.paths(f).first)
        let result = Self.outline(f, path)
        #expect(result[0].points.count > 4, "points added where the outline crosses the lens")
        #expect(Self.change(result, original) > 2, "the outline moved")
        let error = Self.error(result, original, center: center, radius: radius, perspective: 50)
        #expect(error < 0.15, "\(error) pt from the outline seen through the lens")
        // What lies outside the lens is untouched.
        for point in result[0].points where point.anchor.distance(to: center) > radius + 1e-6 {
            #expect(Self.deviation([point.anchor], from: Self.samples(original, per: 400)[0]) < 0.01)
        }
        // The preview is the change.
        #expect(preview.count == result.count)
        for (shown, written) in zip(preview, result) {
            #expect(shown.points.count == written.points.count)
            #expect(zip(shown.points, written.points).allSatisfy { $0.anchor.distance(to: $1.anchor) < 1e-6 && ($0.outHandle - $1.outHandle).length < 1e-6 })
        }
        // One undo brings the live ellipse back.
        _ = await f.document.undo().value
        await f.document.settle()
        #expect(f.document.state.isLive(ellipse) && Self.paths(f).isEmpty)
        #expect(Self.change(Self.outline(f, ellipse), original) < 0.01)
    }

    @Test func aLensThatMeetsNoOutlineWritesNothingAndTheEllipseStaysLive() async throws {
        let f = Fixture()
        let ellipse = try await Self.addEllipse(f)
        f.select([SelectionID(ellipse)])
        let tool = FisheyeLensTool { 50 }
        tool.activate(in: f.context)
        let changes = f.document.changeCount
        // A lens of radius 20 about the centre: the ellipse's fill is under it, its outline is not.
        _ = try await Self.lens(f, tool, Point(x: 150, y: 150), Point(x: 170, y: 150), [.option])
        #expect(f.document.changeCount == changes && f.document.state.isLive(ellipse))
    }

    @Test func positivePerspectiveBulgesAndNegativePinches() async throws {
        var tops: [Double: Double] = [:]
        for perspective in [50.0, -50.0, 0.0] {
            let f = Fixture()
            let ellipse = try await Self.addEllipse(f)
            f.select([SelectionID(ellipse)])
            let tool = FisheyeLensTool { perspective }
            tool.activate(in: f.context)
            _ = try await Self.lens(f, tool, Point(x: 70, y: 150), Point(x: 230, y: 150))
            let node = Self.paths(f).first ?? ellipse
            tops[perspective] = Self.outline(f, node).flatMap(\.segments).map { $0.bounds.minY }.min()
        }
        // The top of the ellipse is 50 pt from the lens centre (radius 80).
        let bulged = try #require(tops[50]), pinched = try #require(tops[-50]), flat = try #require(tops[0])
        #expect(bulged < 100 - 5, "convex: pushed out, \(bulged)")
        #expect(pinched > 100 + 5, "concave: pulled in, \(pinched)")
        #expect(abs(flat - 100) < 1e-6, "0: unchanged")
        #expect(abs(bulged - (150 - 80 * DistortKernels.lens(50.0 / 80, perspective: 50))) < 0.1)
    }

    @Test func severalObjectsAndAGroupAreReshapedInOneChange() async throws {
        let f = Fixture()
        let ellipse = try await Self.addEllipse(f)
        let rectangle = try #require(await f.document.addRectangles([Rect(x: 40, y: 40, width: 60, height: 60)]).first)
        let polygon = try #require(await f.document.perform(CreatePolygon(PolygonShape(sides: 6, radius: 30), center: Point(x: 220, y: 210))).value?.createdObjects.first)
        let line = try #require(await f.document.addPath([Point(x: 60, y: 250), Point(x: 240, y: 250)]))
        _ = await f.document.perform(GroupObjects([line.opID])).value
        await f.document.settle()
        let group = try #require(Objects.parent(of: line.opID, in: f.document.state))
        f.select([SelectionID(ellipse), rectangle, SelectionID(polygon), SelectionID(group)])
        let before = [ellipse, rectangle.opID, polygon, line.opID].map { Self.outline(f, $0) }
        let tool = FisheyeLensTool { 80 }
        tool.activate(in: f.context)
        let changes = f.document.changeCount
        _ = try await Self.lens(f, tool, Point(x: 150, y: 150), Point(x: 300, y: 150), [.option])
        #expect(f.document.changeCount == changes + 1 && f.document.undoTitle == "Undo Fisheye lens")
        let state = f.document.state
        #expect(!state.isLive(ellipse) && !state.isLive(rectangle.opID) && !state.isLive(polygon), "every shape converted")
        #expect(Self.paths(f).count == 3, "three converted paths beside the group")
        // The straight line in the group now bows through the lens, still as a path in the group.
        let bowed = Self.outline(f, line.opID)
        #expect(bowed[0].points.count > 2 && Self.change(bowed, before[3]) > 3 && Objects.parent(of: line.opID, in: state) == group)
        let error = Self.error(bowed, before[3], center: Point(x: 150, y: 150), radius: 150, perspective: 80)
        #expect(error < 0.15, "\(error)")
        _ = await f.document.undo().value
        await f.document.settle()
        let restored = f.document.state
        #expect(restored.isLive(ellipse) && restored.isLive(rectangle.opID) && restored.isLive(polygon))
        #expect(Self.change(Self.outline(f, line.opID), before[3]) < 0.01)
    }

    // MARK: Kernel

    @Test func theWarpKeepsWhatIsOutsideAndCutsWhatCrossesTheLens() {
        let center = Point(x: 0, y: 0)
        // A straight open line through the lens, from well outside to well outside.
        let line = DistortContour(points: [VectorPoint(anchor: Point(x: -100, y: 5)), VectorPoint(anchor: Point(x: 100, y: 5))], closed: false)
        let bent = DistortKernels.fisheye(line, center: center, radius: 40, perspective: 60)
        #expect(bent.points.first == line.points.first && bent.points.last?.anchor == line.points.last?.anchor)
        #expect(bent.points.count > 8, "cut into pieces through the lens")
        let added = bent.points.dropFirst().dropLast()
        #expect(added.allSatisfy { $0.id == .zero })
        #expect(added.filter { $0.anchor.distance(to: center) < 39 }.allSatisfy { $0.kind == .curve }, "smooth inside the lens")
        #expect(Self.error([bent], [line], center: center, radius: 40, perspective: 60) < 0.15)
        // A contour the lens misses is returned as it is.
        let far = DistortContour(points: DistortToolTests.circle, closed: true)
        #expect(DistortKernels.fisheye(far, center: center, radius: 40, perspective: 60) == far)
        #expect(DistortKernels.fisheye(far, center: center, radius: 0, perspective: 60) == far)
        // One point: mapped, handles with it.
        let single = DistortContour(points: [VectorPoint(anchor: Point(x: 10, y: 0), outHandle: Vector(dx: 5, dy: 0))], closed: false)
        #expect(DistortKernels.fisheye(single, center: center, radius: 40, perspective: 60).points[0].anchor.x > 10)
        // An open path ending inside the lens maps its outer handles with the ends.
        let open = DistortContour(points: [VectorPoint(anchor: Point(x: 5, y: 0), inHandle: Vector(dx: -2, dy: 0)),
                                           VectorPoint(anchor: Point(x: 10, y: 10), outHandle: Vector(dx: 2, dy: 0))], closed: false)
        let lensed = DistortKernels.fisheye(open, center: center, radius: 40, perspective: 60)
        #expect(lensed.points[0].inHandle.length > 0 && lensed.points.last!.outHandle.length > 0)
        // The hull test: a lens inside a big triangle meets it; degenerate hulls are lines.
        let big = [Point(x: -100, y: -100), Point(x: 100, y: -100), Point(x: 0, y: 100)]
        #expect(DistortKernels.hullMeetsDisk(big, center: center, radius: 10))
        #expect(!DistortKernels.hullMeetsDisk([Point(x: 20, y: 20), Point(x: 30, y: 30), Point(x: 40, y: 40)], center: center, radius: 10))
        #expect(!DistortKernels.inside(center, Point(x: 1, y: 1), Point(x: 2, y: 2), Point(x: 3, y: 3)))
        #expect(DistortKernels.distance(from: center, toSegment: Point(x: 3, y: 4), Point(x: 3, y: 4)) == 5)
        // A curve with a retracted handle keeps a zero tangent there.
        let cusp = CubicBezier(Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 0))
        #expect(DistortKernels.mappedTangent(cusp, 0, DistortKernels.Warp(radius: 40, touches: { _ in true }) { $0 }) == Vector(dx: 0, dy: 0))
    }
}
