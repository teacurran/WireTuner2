import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-030 (Add Points, Fractalize, the Distort submenu, kbd:[Cmd]-click), FX-032 (Roughen, Fisheye
/// Lens and Bend) and the FX-035/036 keylines and trackball.
@Suite(.serialized) @MainActor struct DistortToolTests {
    static let square = [Point(x: 100, y: 100), Point(x: 200, y: 100), Point(x: 200, y: 200), Point(x: 100, y: 200)]

    static func contour(_ points: [Point], closed: Bool = true) -> DistortContour {
        DistortContour(points: points.map { VectorPoint(anchor: $0) }, closed: closed)
    }

    /// A circle of radius 50 about (150, 150) as four curve points.
    static var circle: [VectorPoint] {
        let k = 50 * 0.5523
        return [
            VectorPoint(anchor: Point(x: 200, y: 150), inHandle: Vector(dx: 0, dy: -k), outHandle: Vector(dx: 0, dy: k), kind: .curve),
            VectorPoint(anchor: Point(x: 150, y: 200), inHandle: Vector(dx: k, dy: 0), outHandle: Vector(dx: -k, dy: 0), kind: .curve),
            VectorPoint(anchor: Point(x: 100, y: 150), inHandle: Vector(dx: 0, dy: k), outHandle: Vector(dx: 0, dy: -k), kind: .curve),
            VectorPoint(anchor: Point(x: 150, y: 100), inHandle: Vector(dx: -k, dy: 0), outHandle: Vector(dx: k, dy: 0), kind: .curve),
        ]
    }

    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Distort")
        let host = RecordingHost()
        let context: ToolContext
        var node: SelectionID?

        init() {
            context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        }

        func select(_ ids: [SelectionID]) {
            context.selection.model.set(Selection(ids))
        }

        func addCircle() async -> SelectionID {
            let node = await document.perform(CreatePath(contours: [NewContour(closed: true, points: DistortToolTests.circle)], appearance: TestAppearance.filled))
                .value!.createdObjects.first!
            await document.settle()
            return SelectionID(node)
        }

        func drag(_ tool: any Tool, _ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) async {
            tool.mouseDown(TestEvents.point(from.x, from.y, modifiers))
            tool.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: context.viewport)
            tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
            await document.settle()
        }
    }

    /// The RGBA bytes of `document` drawn at 1:1 over 300 × 300 points.
    static func pixels(_ document: DocumentHandle) -> [UInt8] {
        let image = CoreGraphicsRenderer().renderBitmap(document.displayList, viewport: Viewport(size: Size(width: 300, height: 300)))!
        var bytes = [UInt8](repeating: 0, count: 300 * 300 * 4)
        let context = CGContext(data: &bytes, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 300, height: 300))
        return bytes
    }

    // MARK: Kernels

    @Test func fractalizeTurnsASquareIntoSixteenSegmentsSpikedOutward() {
        let square = Self.contour(Self.square)
        let result = DistortKernels.fractalize(square)
        #expect(result.segments.count == 16 && result.closed)
        // The first side's spike points up, away from the square, by the equilateral height.
        let spike = result.points[2].anchor
        #expect(abs(spike.x - 150) < 1e-6 && abs(spike.y - (100 - 100.0 / 3 * 3.0.squareRoot() / 2)) < 1e-6)
        // A counter-clockwise square spikes outward too: its first side is the bottom one.
        let reversed = DistortKernels.fractalize(Self.contour(Self.square.reversed()))
        #expect(reversed.points[2].anchor.y > 200, "the bottom side's spike points down")
        // An open path: three segments per… four per segment, the ends kept.
        let open = DistortKernels.fractalize(Self.contour([Point(x: 0, y: 0), Point(x: 90, y: 0)], closed: false))
        #expect(open.segments.count == 4 && open.points.first?.anchor == Point(x: 0, y: 0) && open.points.last?.anchor == Point(x: 90, y: 0))
        #expect(DistortKernels.fractalize(Self.contour([Point(x: 1, y: 1)], closed: false)).points.count == 1, "nothing to spike")
        // Curves keep their shape outside the middle thirds.
        let curved = DistortKernels.fractalize(DistortContour(points: Self.circle, closed: true))
        #expect(curved.points.count == 16 && curved.points[0].outHandle.length > 0 && curved.points[0].inHandle.length > 0)
        #expect(Self.contour(Self.square).signedArea > 0 && Self.contour([Point(x: 0, y: 0)]).signedArea == 0)
    }

    @Test func roughenAddsPointsPerInchAndMovesThemWithinTheDrag() {
        var random = SeededGenerator(seed: 7)
        let square = Self.contour(Self.square)
        let rough = DistortKernels.roughen(square, amount: 10, smooth: false, distance: 50, using: &random)
        // 100 pt sides at 7.2 pt spacing: 14 points each.
        #expect(rough.points.count == 56 && rough.points.allSatisfy { $0.kind == .corner && $0.inHandle == .zero })
        #expect(rough.points[0].id == square.points[0].id)
        let reach = rough.points.enumerated().map { index, point in index % 14 == 0 ? point.anchor.distance(to: Self.square[index / 14]) : 0 }
        #expect(reach.allSatisfy { $0 <= 5 + 1e-9 } && reach.contains { $0 > 0 }, "moved at most distance × 0.1")
        let smooth = DistortKernels.roughen(square, amount: 10, smooth: true, distance: 50, using: &random)
        #expect(smooth.points.allSatisfy { $0.kind == .curve && $0.outHandle.length > 0 })
        // No amount: only the existing points move; an open path keeps its end.
        let none = DistortKernels.roughen(Self.contour(Self.square, closed: false), amount: 0, smooth: true, distance: 10, using: &random)
        #expect(none.points.count == 4 && none.points.first?.kind == .corner && none.points.last?.outHandle == .zero)
        #expect(DistortKernels.roughen(Self.contour([], closed: false), amount: 5, smooth: false, distance: 5, using: &random).points.isEmpty)
        #expect(DistortKernels.normal(CubicBezier(Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 0, y: 0)), at: 0) == Vector(dx: 0, dy: 0))
        #expect(DistortKernels.smoothed([VectorPoint(anchor: .zero)], closed: false).count == 1)
        let flat = DistortKernels.smoothed([Point(x: 0, y: 0), Point(x: 0, y: 0), Point(x: 0, y: 0)].map { VectorPoint(anchor: $0) }, closed: true)
        #expect(flat.allSatisfy { $0.outHandle == .zero }, "coincident points take no handles")
        var zero = SeededGenerator(seed: 0)
        #expect(zero.next() != 0)
    }

    @Test func theLensBulgesConvexAndSinksConcave() {
        #expect(DistortKernels.lens(0.25, perspective: 100) > 0.25 && DistortKernels.lens(0.25, perspective: -100) < 0.25)
        #expect(DistortKernels.lens(0.25, perspective: 0) == 0.25 && DistortKernels.lens(1, perspective: 50) == 1 && DistortKernels.lens(0, perspective: 50) == 0)
        let center = Point(x: 0, y: 0)
        #expect(DistortKernels.fisheye(Point(x: 20, y: 0), center: center, radius: 10, perspective: 50) == Point(x: 20, y: 0), "outside the lens")
        #expect(DistortKernels.fisheye(center, center: center, radius: 10, perspective: 50) == center)
        let bulged = DistortKernels.fisheye(Point(x: 2, y: 0), center: center, radius: 10, perspective: 50)
        #expect(bulged.x > 2 && bulged.y == 0)
        let lensed = DistortKernels.fisheye(DistortContour(points: Self.circle, closed: true), center: Point(x: 150, y: 150), radius: 80, perspective: -50)
        #expect(lensed.points[0].anchor.x < 200 && lensed.points[0].outHandle.length > 0)
        let corners = DistortKernels.fisheye(Self.contour(Self.square), center: Point(x: 150, y: 150), radius: 200, perspective: 50)
        #expect(corners.points.allSatisfy { $0.inHandle == .zero }, "retracted handles stay retracted")
    }

    @Test func bendSpikesOnAnUpDragAndBloatsOnADownDrag() {
        #expect(DistortKernels.bendSize(dragDistance: -30, up: true, amount: 10) == -30)
        #expect(DistortKernels.bendSize(dragDistance: 30, up: false, amount: 5) == 15)
        #expect(DistortKernels.bendSize(dragDistance: 30, up: false, amount: 40) == 30, "amount clamps to 10")
        let circle = DistortContour(points: Self.circle, closed: true)
        let center = Point(x: 150, y: 150)
        let farthest = DistortKernels.farthest([circle], from: center)
        #expect(farthest > 50)
        let spiked = DistortKernels.bend(circle, center: center, size: -20, farthest: farthest)
        let bloated = DistortKernels.bend(circle, center: center, size: 20, farthest: farthest)
        // Anchors (near the farthest) move little; handle ends move more -- the sides cave in or bulge.
        #expect(spiked.points[0].outHandle.length < circle.points[0].outHandle.length || spiked.points[0].anchor.x != 200)
        #expect(bloated.points[0].anchor.x != spiked.points[0].anchor.x)
        #expect(spiked.points.allSatisfy { abs($0.inHandle.normalized.cross($0.outHandle.normalized)) < 1e-9 }, "smooth points stay smooth")
        #expect(DistortKernels.bend(circle, center: center, size: 0, farthest: farthest) == circle)
        let corner = DistortKernels.bend(Self.contour(Self.square), center: center, size: 10, farthest: 100)
        #expect(corner.points[0].anchor != Self.square[0])
        #expect(DistortKernels.bend(Self.contour([center]), center: center, size: 10, farthest: 1).points[0].anchor == center)
    }

    // MARK: Tools

    @Test func roughenFisheyeAndBendEachWriteOneChange() async throws {
        let f = Fixture()
        let path = try #require(await f.document.addPath(Self.square, closed: true))
        f.select([path])
        let roughen = RoughenTool { RoughenSettings(amount: 5, smooth: false) }
        #expect(RoughenSettings() == RoughenSettings(amount: 20, smooth: false))
        roughen.activate(in: f.context)
        #expect(roughen.command() == nil && roughen.kernel() == nil && !roughen.hasSomethingToCancel)
        await f.drag(roughen, Point(x: 100, y: 100), Point(x: 160, y: 100))
        #expect(f.document.undoTitle == "Undo Roughen")
        #expect((f.document.path(path)?.contours[0].points.count ?? 0) > 4)
        let lens = FisheyeLensTool { 80 }
        lens.activate(in: f.context)
        await f.drag(lens, Point(x: 100, y: 150), Point(x: 200, y: 150))
        #expect(f.document.undoTitle == "Undo Fisheye lens")
        // Option: the lens is drawn from its centre.
        lens.mouseDown(TestEvents.point(150, 150))
        lens.mouseDragged(TestEvents.point(170, 150, [.option]))
        #expect(lens.lens?.center == Point(x: 150, y: 150) && lens.lens?.radius == 20)
        lens.flagsChanged(TestEvents.point(0, 0))
        #expect(lens.lens?.center == Point(x: 160, y: 150) && lens.lens?.radius == 10, "without Option: the circle across the drag")
        lens.cancel()
        let bend = BendTool { 10 }
        bend.activate(in: f.context)
        bend.mouseDown(TestEvents.point(150, 150))
        #expect(bend.size == 0 && bend.kernel() == nil)
        bend.mouseDragged(TestEvents.point(150, 120))
        #expect(bend.size == -30, "up: a spike")
        bend.mouseUp(TestEvents.point(150, 120))
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Bend" && !bend.keyDown(TestEvents.escape))
        // Nothing selected: the press does nothing.
        f.select([])
        bend.mouseDown(TestEvents.point(0, 0))
        #expect(!bend.hasSomethingToCancel && bend.dragDistance == 0)
        bend.mouseDragged(TestEvents.point(5, 5))
        bend.flagsChanged(TestEvents.point(5, 5))
        bend.mouseUp(TestEvents.point(5, 5))
        bend.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        bend.deactivate()
        roughen.deactivate()
        lens.deactivate()
        #expect(bend.cursor == NSCursor.crosshair && f.host.messages.contains(bend.statusMessage))
    }

    @Test func theBendToolDrawsWhatTheBendEffectOfTheSameSizeDraws() async throws {
        let effect = Fixture(), tool = Fixture()
        let bent = await effect.addCircle()
        let list = AttributesListModel(document: effect.document, selection: Selection([bent]))
        _ = await list.perform(list.addEffect(.bend, above: nil))?.value
        let row = try #require(EffectReading.entries(bent.opID, in: effect.document.state).last?.row)
        _ = await effect.document.perform(EditEffect([(bent.opID, row)], label: "Bend", fields: [EffectField.bend(1)]) { $0.bend.size = -20 }).value
        await effect.document.settle()
        let shaped = await tool.addCircle()
        tool.select([shaped])
        let bend = BendTool { 10 }
        bend.activate(in: tool.context)
        await tool.drag(bend, Point(x: 150, y: 150), Point(x: 150, y: 130))
        let a = Self.pixels(effect.document), b = Self.pixels(tool.document)
        let differing = stride(from: 3, to: a.count, by: 4).filter { abs(Int(a[$0]) - Int(b[$0])) > 64 }.count
        #expect(differing < 60, "\(differing) pixels differ")
        #expect(a.contains { $0 != 0 })
    }

    @Test func fractalizeAndAddPointsRunFromTheExtensionsMenu() async throws {
        let f = Fixture()
        let path = try #require(await f.document.addPath(Self.square, closed: true))
        let editing = ObjectEditing(document: f.document, selection: f.context.selection)
        let registry = ExtensionRegistry()
        let tools = ToolRegistry()
        tools.registerBuiltIn()
        var presented: [ToolID] = []
        var manager: ToolManager?
        DistortFeatures.install(tools: tools, extensions: registry, store: TestEnvironment().preferences, target: { editing }, tools: { manager },
                                present: { presented.append($0.id) })
        #expect(registry.validation(ofExtension: "fractalize").reason == DistortFeatures.noPath)
        f.select([path])
        #expect(registry.validation(ofExtension: "fractalize").isEnabled && registry.validation(ofExtension: "addPoints").isEnabled)
        #expect(registry.perform("fractalize"))
        await f.document.settle()
        #expect(f.document.path(path)?.contours[0].points.count == 16 && f.document.undoTitle == "Undo Fractalize")
        #expect(registry.perform("addPoints"))
        await f.document.settle()
        #expect(f.document.path(path)?.contours[0].points.count == 32)
        // Cmd-click replays the previous settings (none captured: the defaults) without a sheet.
        #expect(registry.performWithPreviousSettings("fractalize") && registry.repeatState?.extensionID == "fractalize")
        #expect(!registry.performWithPreviousSettings("emboss"), "a stub does not run")
        #expect(DistortFeatures.fractalize(ObjectEditing(document: f.document, selection: SelectionController(document: f.document))) == nil)
        // The Distort submenu's tools choose the tool and open its options.
        #expect(!registry.validation(ofExtension: "bend").isEnabled)
        manager = ToolManager(registry: tools, context: f.context)
        #expect(registry.perform("bend") && manager?.activeToolID == BendTool.id && presented == [BendTool.id])
        #expect(tools.descriptor(for: ShadowTool.id)?.options != nil && tools.makeTool(RoughenTool.id) is RoughenTool)
        for id in [RoughenTool.id, FisheyeLensTool.id, BendTool.id, SmudgeTool.id, ShadowTool.id] {
            #expect(tools.descriptor(for: id)?.options?() != nil)
            _ = tools.makeTool(id)
        }
        #expect(RoughenSettings(preferences: TestEnvironment().preferences) == RoughenSettings())
    }

    @Test func aCommandClickOnAToolbarButtonReplaysTheOperation() {
        var runs: [ExtensionParameters?] = []
        let registry = ExtensionRegistry()
        var descriptor = registry.descriptor(for: "emboss")!
        descriptor.validate = { .enabled }
        descriptor.run = { parameters in
            runs.append(parameters)
            return ["depth": "4"]
        }
        registry.replace(descriptor)
        #expect(registry.perform("emboss") && registry.lastParameters["emboss"] == ["depth": "4"])
        #expect(registry.performWithPreviousSettings("emboss"))
        #expect(runs == [nil, ["depth": "4"]], "the sheet once, then its captured settings")
        #expect(!registry.performWithPreviousSettings("unknown"))
    }

    @Test func quietEdgesOfTheReshapingTools() async throws {
        let f = Fixture()
        let path = try #require(await f.document.addPath(Self.square, closed: true))
        f.select([path])
        let lens = FisheyeLensTool { 50 }
        lens.mouseDown(TestEvents.point(0, 0))
        #expect(lens.lens == nil && lens.kernel() == nil && !lens.hasSomethingToCancel, "no context: no press")
        lens.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        lens.activate(in: f.context)
        lens.mouseDown(TestEvents.point(150, 150))
        #expect(lens.kernel() == nil, "a lens of no radius")
        lens.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        lens.cancel()
        let bend = BendTool { 5 }
        #expect(bend.size == 0)
        // An open, smooth contour bends too; nothing is farthest from an empty list.
        let open = DistortContour(points: Array(Self.circle.prefix(3)), closed: false)
        #expect(DistortKernels.bend(open, center: Point(x: 150, y: 150), size: -10, farthest: 80).points.count == 3)
        #expect(DistortKernels.farthest([], from: .zero) == 0)
        Keylines.add([DistortContour(points: [VectorPoint(anchor: .zero)], closed: false)], to: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        // A path whose transform cannot be inverted is left alone.
        let target = PathSplitting.Target(node: path.opID, transform: .scale(x: 0, y: 0), contours: [])
        #expect((DistortTargetsCommand.command([target], label: "Fractalize", DistortKernels.fractalize) as? CompositeCommand)?.commands.isEmpty == true)
        // Without the catalog's descriptors, there is nothing to deliver.
        #expect(DistortFeatures.extensionDescriptors(existing: ExtensionRegistry(descriptors: []), target: { nil }, tools: { nil }, present: { _ in },
                                                     registry: ToolRegistry()).isEmpty)
        // The delivered tools read their preferences.
        let store = TestEnvironment().preferences
        let tools = ToolRegistry()
        DistortFeatures.install(tools: tools, extensions: ExtensionRegistry(), store: store, target: { nil }, tools: { nil }, present: { _ in })
        #expect((tools.makeTool(RoughenTool.id) as? RoughenTool)?.settings() == RoughenSettings(preferences: store))
        #expect((tools.makeTool(FisheyeLensTool.id) as? FisheyeLensTool)?.perspective() == 50)
        #expect((tools.makeTool(BendTool.id) as? BendTool)?.amount() == 5)
        #expect((tools.makeTool(SmudgeTool.id) as? SmudgeTool)?.settings() == SmudgeSettings(preferences: store))
        #expect((tools.makeTool(ShadowTool.id) as? ShadowTool)?.settings() == ShadowSettings())
    }

    // MARK: Keylines and trackball

    @Test func keylinesFollowOutlinesAndTheTrackballTurnsAlongTheDrag() async throws {
        let f = Fixture()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 20)])[0]
        let path = try #require(await f.document.addPath(Self.square, closed: true))
        _ = await f.document.perform(GroupObjects([path.opID])).value
        await f.document.settle()
        let group = try #require(Objects.parent(of: path.opID, in: f.document.state))
        let outlines = Keylines.contours([rect.opID, group], document: f.document)
        #expect(outlines.count == 2 && outlines[1].points.map(\.anchor) == Self.square)
        #expect(Keylines.contours([OpID(counter: 9, replica: 9)], document: f.document).isEmpty, "an unknown node has no outline")
        // A diagonal drag turns about the perpendicular diagonal.
        let diagonal = Rotation3D(drag: Vector(dx: 30, dy: 30), constrained: false)
        let horizontal = Rotation3D(drag: Vector(dx: 30, dy: 0), constrained: false)
        #expect(nearlyEqualRows(horizontal.matrix, Rotation3D(yaw: 30 * Rotation3D.radiansPerPoint, pitch: 0).matrix))
        #expect(abs(diagonal.matrix[0][1] - diagonal.matrix[1][0]) > 1e-9 || diagonal.matrix[0][2] != 0)
        #expect(Rotation3D(drag: Vector(dx: 0, dy: 0), constrained: true).isIdentity)
        #expect(Rotation3D(axis: (0, 0, 0), angle: 1).isIdentity && !diagonal.isIdentity)
        let snapped = Rotation3D(drag: Vector(dx: 80, dy: 10), constrained: true)
        #expect(nearlyEqualRows(snapped.matrix, Rotation3D(yaw: .pi / 4, pitch: 0).matrix), "the heading and the angle snap to 45°")
        // The tools' overlays draw the outlines.
        f.select([rect, path])
        let mirror = MirrorTool()
        mirror.activate(in: f.context)
        mirror.mouseDown(TestEvents.point(50, 50))
        mirror.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        mirror.cancel()
        let rotation = Rotation3DTool()
        rotation.activate(in: f.context)
        rotation.mouseDown(TestEvents.point(10, 10))
        rotation.mouseDragged(TestEvents.point(40, 30))
        rotation.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.context.viewport)
        rotation.mouseDown(TestEvents.point(10, 10))
        #expect(rotation.command() == nil, "no drag: no rotation")
        rotation.deactivate()
    }

    func nearlyEqualRows(_ a: [[Double]], _ b: [[Double]]) -> Bool {
        zip(a, b).allSatisfy { zip($0, $1).allSatisfy { abs($0 - $1) < 1e-12 } }
    }
}
