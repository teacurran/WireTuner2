import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-005 (path display preferences), DRAW-018 (the Variable Stroke Pen), DRAW-020 (tablet
/// input), DRAW-028 (the Knife and Split) and the installer of the path tools.
@Suite(.serialized) @MainActor struct PathEditingToolTests {
    typealias Fixture = DrawingToolTests.Fixture

    static func tablet(_ x: Double, _ y: Double, pressure: Double, _ modifiers: KeyModifiers = []) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: Point(x: x, y: y), viewPoint: Point(x: x, y: y), modifiers: modifiers, pressure: pressure, isTablet: true)
    }

    /// The outline's half-width along a straight stroke on y = 50: its distance from the line at
    /// many points of the outline away from the caps.
    static func halfWidths(_ contour: Contour, from minX: Double, to maxX: Double) -> [Double] {
        contour.segments.flatMap { segment in
            stride(from: 0.0, through: 1.0, by: 0.05).map { segment.evaluate($0) }
        }.filter { $0.x > minX && $0.x < maxX }.map { abs($0.y - 50) }
    }

    // MARK: DRAW-020

    @Test func penPressureDrivesTheWidthAndTheBracketsWaitForTheMouse() {
        var control = StrokeWidthControl(min: 2, max: 12)
        #expect(control.keyWidth == 7)
        #expect(control.width(for: Self.tablet(0, 0, pressure: 1)) == 12 && control.penInContact)
        #expect(control.width(for: Self.tablet(0, 0, pressure: 0)) == 2)
        #expect(control.width(for: Self.tablet(0, 0, pressure: 0.5)) == 7)
        #expect(!control.bracket(wider: true) && control.keyWidth == 7, "ignored while the pen is in contact")
        #expect(control.width(for: TestEvents.point(0, 0)) == 7 && !control.penInContact, "a mouse leaves the key width")
        #expect(control.bracket(wider: true) && control.keyWidth == 8)
        for _ in 0..<20 { control.bracket(wider: false) }
        #expect(control.keyWidth == 2, "clamped to Min")
        var curved = StrokeWidthControl(min: 0, max: 10, curve: 2)
        #expect(abs(curved.width(for: Self.tablet(0, 0, pressure: 0.5)) - 2.5) < 1e-9, "the pressure curve")
        #expect(StrokeWidthControl(min: 9, max: 3, curve: -1).min == 3 && StrokeWidthControl(min: 9, max: 3, curve: -1).curve == 1)
        #expect(StrokeWidthControl(min: 1, max: 5, keyWidth: 40).keyWidth == 5)
        #expect(StrokeWidthControl.bracket("[") == false && StrokeWidthControl.bracket("]") == true && StrokeWidthControl.bracket("a") == nil)
        // The translator keeps the tablet flag and clamps its pressure.
        let event = CanvasEventTranslator.event(appKitPoint: .zero, viewHeight: 10, viewport: Viewport(size: Size(width: 10, height: 10)),
                                                modifierFlags: [], pressure: 0.3, clickCount: 1, timestamp: 0, isTablet: true)
        #expect(event.isTablet && abs(event.pressure - 0.3) < 1e-6 && event.with(modifiers: .shift).isTablet)
    }

    // MARK: DRAW-018

    @Test func aConstantPressureStrokeHasTheMappedWidthAlongItsLength() async throws {
        let settings = VariableStrokeSettings()
        let f = Fixture(VariableStrokePen { settings })
        f.tool.mouseDown(Self.tablet(0, 50, pressure: 0.5))
        for x in stride(from: 5.0, through: 200, by: 5) { f.tool.mouseDragged(Self.tablet(x, 50, pressure: 0.5)) }
        let outline = try #require(f.tool.outline())
        let mapped = settings.min + (settings.max - settings.min) * 0.5
        let widths = Self.halfWidths(outline, from: 10, to: 190).map { $0 * 2 }
        #expect(!widths.isEmpty && widths.allSatisfy { abs($0 - mapped) < 0.1 }, "width \(mapped) within 0.1 pt")
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
        f.tool.mouseUp(Self.tablet(200, 50, pressure: 0.5))
        await f.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        let created = try #require(f.created?.path?.contours.first)
        #expect(created.closed && f.document.undoTitle == "Undo Variable Stroke")
        // A mouse stroke keeps the key width, which the brackets change.
        f.tool.mouseDown(TestEvents.point(0, 150))
        #expect(f.tool.keyDown(TestEvents.key("]", keyCode: 30)) && f.tool.keyDown(TestEvents.key("]", keyCode: 30)))
        #expect(!f.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        for x in stride(from: 5.0, through: 100, by: 5) { f.tool.mouseDragged(TestEvents.point(x, 150)) }
        #expect(f.tool.samples.dropFirst().allSatisfy { $0.width == 9 })
        f.tool.cancel()
        #expect(!f.tool.hasSomethingToCancel && f.tool.command() == nil)
        f.tool.pointerMoved(TestEvents.point(0, 0))
        f.tool.flagsChanged(TestEvents.point(0, 0))
        f.tool.deactivate()
        #expect(f.tool.outline() == nil)
    }

    @Test func widthsInterpolateAlongTheSamplesAndOptionDrawsStraight() async throws {
        let samples = [VariableStrokeOutline.Sample(point: Point(x: 0, y: 0), width: 2), VariableStrokeOutline.Sample(point: Point(x: 10, y: 0), width: 12)]
        #expect(VariableStrokeOutline.width(at: 0.5, samples: samples) == 7)
        #expect(VariableStrokeOutline.width(at: 2, samples: samples) == 12 && VariableStrokeOutline.width(at: 0, samples: []) == 0)
        #expect(VariableStrokeOutline.width(at: 0.3, samples: [samples[0]]) == 2)
        #expect(VariableStrokeOutline.width(at: 0.3, samples: [samples[0], samples[0]]) == 2)
        #expect(VariableStrokeOutline.outline(centerline: [], samples: samples) == nil)
        #expect(VariableStrokeOutline.cap(center: .zero, from: .zero, forward: Vector(dx: 1, dy: 0)).isEmpty)
        let f = Fixture(VariableStrokePen())
        f.tool.mouseDown(TestEvents.point(0, 50))
        f.tool.mouseDragged(TestEvents.point(40, 50))
        f.tool.mouseDragged(TestEvents.point(80, 60, .option))
        f.tool.mouseDragged(TestEvents.point(120, 60, .option))
        f.tool.mouseDragged(TestEvents.point(150, 60))
        #expect(f.tool.outline() != nil)
        #expect(ContourPoints.points(Contour(segments: [], closed: true)).isEmpty && ContourPoints.segments([], closed: false).isEmpty)
    }

    @Test func aSelfCrossingStrokeWithOverlapRemovalIsOneCompositeAndOneUndoGroup() async throws {
        var settings = VariableStrokeSettings()
        settings.removeOverlap = true
        settings.min = 6
        settings.max = 6
        let f = Fixture(VariableStrokePen { [settings] in settings })
        // A loop that crosses itself.
        f.tool.mouseDown(TestEvents.point(0, 100))
        for step in 1...60 {
            let t = Double(step) / 60 * 2 * .pi
            f.tool.mouseDragged(TestEvents.point(100 * t / (2 * .pi) + 40 * sin(t), 100 - 40 * (1 - cos(t))))
        }
        f.tool.mouseUp(TestEvents.point(100, 100))
        await f.tool.cleanup?.value
        await f.document.settle()
        let path = try #require(f.created?.path)
        let filled = FilledPath(contours: path.contours.map { Contour(segments: ContourPoints.segments($0.drawn, closed: true), closed: true) })
        #expect(path.contours.allSatisfy { $0.closed })
        // No interior overlaps: the contours cross neither themselves nor each other.
        let region = Boolean.normalize(filled)
        #expect(abs(abs(region.signedArea()) - abs(filled.signedArea())) < 1.0)
        #expect(f.document.undoTitle == "Undo Variable Stroke")
        _ = await f.document.undo().value
        await f.document.settle()
        #expect(f.document.scene.topLevel.isEmpty, "the stroke and its cleanup undo as one step")
    }

    @Test func overlapCleanupAgainstAConcurrentPointEditLandsOnTheTombstone() async throws {
        let document = DocumentHandle.memory(title: "Cleanup")
        let change = await document.perform(CreatePath(contours: [NewContour(closed: true, points: [
            VectorPoint(anchor: Point(x: 0, y: 0)), VectorPoint(anchor: Point(x: 100, y: 100)), VectorPoint(anchor: Point(x: 100, y: 0)), VectorPoint(anchor: Point(x: 0, y: 100)),
        ])])).value
        let node = try #require(change?.createdObjects.first)
        await document.settle()
        let contour = try #require(document.path(SelectionID(node))?.contours.first)
        // A collaborator moves a point from the state before the cleanup.
        var remote = DocumentCore(state: document.state, replica: 0xFFFF_FFFF)
        let move = try #require(try remote.perform(MovePoints(node: node, contour: contour.id, point: contour.points[1].id, to: Point(x: 110, y: 110)),
                                                   recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        let cleanup = try #require(await VariableStrokePen.removeOverlap(node, document: document, sink: document))
        _ = await cleanup.value
        _ = await document.receive(move).value
        await document.settle()
        let element = try #require(document.state.store.element(node, PathFields.point(contour.id, contour.points[1].id)))
        #expect(element.isDeleted, "the edited point was replaced: edit vs delete, and no crash")
        #expect(document.path(SelectionID(node))?.contours.count ?? 0 >= 2, "the bow tie cleans up into two contours")
        #expect(await VariableStrokePen.removeOverlap(OpID(counter: 99_999, replica: 5), document: document, sink: document) == nil)
    }

    // MARK: DRAW-028

    @Test func cuttingAClosedPathOnceYieldsTwoClosedOrTwoOpenPaths() async throws {
        for close in [true, false] {
            let document = DocumentHandle.memory(title: "Knife")
            let square = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)], closed: true))
            let f = Fixture(KnifeTool { KnifeSettings(straight: true, close: close) }, document: document)
            f.selection.model.set(Selection([square]))
            f.tool.mouseDown(TestEvents.point(50, -20))
            f.tool.mouseDragged(TestEvents.point(50, 60))
            f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
            f.tool.mouseUp(TestEvents.point(50, 120))
            await document.settle()
            let paths = document.scene.topLevel.compactMap { document.object(for: SelectionID($0))?.path }
            #expect(paths.count == 2 && paths.allSatisfy { $0.contours[0].closed == close }, "close \(close)")
            #expect(document.undoTitle == "Undo Knife")
            // The piece holding the original start keeps the node.
            #expect(document.path(square)?.contours[0].drawn.contains { $0.anchor == Point(x: 0, y: 0) } == true)
        }
    }

    @Test func aWideCutRemovesAStripAndAFreehandCutFollowsTheDrag() async throws {
        let document = DocumentHandle.memory(title: "Strip")
        let line = try #require(await document.addPath([Point(x: 0, y: 50), Point(x: 200, y: 50)]))
        let f = Fixture(KnifeTool { KnifeSettings(width: 20) }, document: document)
        f.selection.model.set(Selection([line]))
        f.tool.mouseDown(TestEvents.point(100, 0))
        for y in stride(from: 10.0, through: 100, by: 10) { f.tool.mouseDragged(TestEvents.point(100, y)) }
        f.tool.mouseUp(TestEvents.point(100, 110))
        await document.settle()
        let pieces = document.scene.topLevel.compactMap { document.object(for: SelectionID($0))?.path?.contours[0].drawn.map(\.anchor) }
        #expect(pieces.count == 2)
        let ends = pieces.flatMap { [$0.first!.x, $0.last!.x] }.sorted()
        #expect(abs(ends[1] - 90) < 0.5 && abs(ends[2] - 110) < 0.5, "a 20 pt strip is gone: \(ends)")
        // A cut that misses changes nothing; Option spans and Shift work in free mode.
        f.tool.mouseDown(TestEvents.point(0, 300))
        f.tool.mouseDragged(TestEvents.point(50, 310, .option))
        f.tool.mouseDragged(TestEvents.point(90, 330, [.option, .shift]))
        f.tool.mouseUp(TestEvents.point(100, 300))
        #expect(f.tool.command() == nil && !f.tool.hasSomethingToCancel)
        #expect(!f.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        f.tool.flagsChanged(TestEvents.point(0, 0))
        let tight = Fixture(KnifeTool { KnifeSettings(tightFit: true) }, document: document)
        tight.tool.mouseDown(TestEvents.point(0, 0))
        tight.tool.mouseDragged(TestEvents.point(10, 5))
        tight.tool.mouseDragged(TestEvents.point(20, 0))
        #expect(tight.tool.cutter().count == 3)
        tight.tool.deactivate()
        #expect(KnifeSettings(preferences: TestEnvironment().preferences) == KnifeSettings())
    }

    @Test func splitAtTwoPointsOfAClosedPathKeepsTheStartsNode() async throws {
        let document = DocumentHandle.memory(title: "Split")
        let square = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)], closed: true))
        let contour = try #require(document.path(square)?.contours[0])
        let picked = Set([1, 3].map { PointReference(node: NodeID(square.opID), contour: contour.id, point: contour.drawn[$0].id) })
        let selection = Selection([square]).applying([square], sub: [square: .points(picked)], mode: .replace)
        #expect(PathSplitting.canSplit(selection, document: document))
        let command = try #require(PathSplitting.split(selection, document: document))
        let change = try #require(await document.perform(command).value)
        #expect(change.label == "Split" && change.createdObjects.count == 1)
        let kept = try #require(document.path(square)?.contours[0])
        #expect(!kept.closed && kept.drawn.map(\.anchor) == [Point(x: 0, y: 100), Point(x: 0, y: 0), Point(x: 100, y: 0)])
        #expect(kept.drawn.contains { $0.id == contour.drawn[0].id }, "the start keeps its id in the original node")
        let other = try #require(document.object(for: SelectionID(change.createdObjects[0]))?.path?.contours[0])
        #expect(!other.closed && other.drawn.map(\.anchor) == [Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)])
        // An open path's own ends cannot split.
        let line = try #require(await document.addPath([Point(x: 0, y: 200), Point(x: 50, y: 200)]))
        let ends = try #require(document.path(line)?.contours[0])
        let endSelection = Selection([line]).applying([line], sub: [line: .points([PointReference(node: NodeID(line.opID), contour: ends.id, point: ends.drawn[0].id)])], mode: .replace)
        #expect(!PathSplitting.canSplit(endSelection, document: document) && !PathSplitting.canSplit(Selection([line]), document: document))
    }

    @Test func aCutAgainstConcurrentEditsKeepsRetainedPointsAndTombstonesMovedOnes() async throws {
        let document = DocumentHandle.memory(title: "Merge cut")
        let square = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)], closed: true))
        let contour = try #require(document.path(square)?.contours[0])
        var remote = DocumentCore(state: document.state, replica: 0xFFFF_FFFF)
        let recording = DocumentCore.Recording(limit: 1, now: Date())
        // Point 0 stays in the retained piece; point 2 moves into the new piece.
        let keptEdit = try #require(try remote.perform(MovePoints(node: square.opID, contour: contour.id, point: contour.drawn[0].id, to: Point(x: -5, y: -5)), recording: recording)?.change)
        let movedEdit = try #require(try remote.perform(MovePoints(node: square.opID, contour: contour.id, point: contour.drawn[2].id, to: Point(x: 105, y: 105)), recording: recording)?.change)
        let cut = try #require(PathSplitting.knife(Selection([square]), document: document, cutter: [Point(x: 50, y: -20), Point(x: 50, y: 120)], settings: KnifeSettings()))
        _ = await document.perform(cut).value
        _ = await document.receive(keptEdit).value
        _ = await document.receive(movedEdit).value
        await document.settle()
        let kept = try #require(document.path(square)?.contours[0])
        #expect(kept.drawn.first { $0.id == contour.drawn[0].id }?.anchor == Point(x: -5, y: -5), "the edit of a retained point is kept")
        #expect(document.state.store.element(square.opID, PathFields.point(contour.id, contour.drawn[2].id))?.isDeleted == true, "a moved-away point's edit lands on its tombstone")
    }

    @Test func piecesAtCutsKeepTheShape() {
        let curve = [VectorPoint(anchor: Point(x: 0, y: 0), outHandle: Vector(dx: 30, dy: 40)), VectorPoint(anchor: Point(x: 100, y: 0), inHandle: Vector(dx: -30, dy: 40))]
        let pieces = try! #require(PathCutting.split(curve, closed: false, at: [PathCutting.Location(segment: 0, t: 0.25), PathCutting.Location(segment: 0, t: 0.75)]))
        #expect(pieces.count == 3 && pieces[0].keepsStart && !pieces[1].keepsStart)
        let original = CubicBezier(from: curve[0].anchor, outHandle: curve[0].outHandle, inHandle: curve[1].inHandle, to: curve[1].anchor)
        let middle = ContourPoints.segments(pieces[1].points, closed: false)[0]
        #expect(middle.evaluate(0).distance(to: original.evaluate(0.25)) < 1e-9 && middle.evaluate(1).distance(to: original.evaluate(0.75)) < 1e-9)
        #expect(middle.evaluate(0.5).distance(to: original.evaluate(0.5)) < 1e-6)
        #expect(PathCutting.split(curve, closed: false, at: []) == nil && PathCutting.split([curve[0]], closed: true, at: [.init(segment: 0, t: 0)]) == nil)
        // A closed contour cut once opens there.
        let square = [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10)].map { VectorPoint(anchor: $0) }
        let opened = try! #require(PathCutting.split(square, closed: true, at: [.init(segment: 1, t: 0.5)]))
        #expect(opened.count == 1 && opened[0].keepsStart && opened[0].points.count == 5)
        #expect(PathCutting.distance(.zero, to: []) == .infinity && PathCutting.distance(Point(x: 3, y: 4), to: [.zero]) == 5)
        #expect(PathCutting.distance(Point(x: 5, y: 5), to: [.zero, .zero, Point(x: 10, y: 0)]) == 5)
        #expect(PathCutting.strip([.zero], width: 3).left == [.zero])
        #expect(PathCutting.command(node: OpID(counter: 1, replica: 1), cut: [], label: "x") == nil)
        let removed = PathCutting.command(node: OpID(counter: 1, replica: 1), cut: [(OpID(counter: 2, replica: 1), [PathCutting.Piece(points: square, closed: false, keepsStart: false)])], label: "x")
        #expect(removed?.removed.count == 1 && removed?.pieces.count == 1)
    }

    // MARK: DRAW-005

    @Test func theGlyphPreferencesRepaintAndNewOpenPathsTakeTheFill() async throws {
        let environment = TestEnvironment()
        let controller = DocumentWindowController(document: .memory(title: "Prefs"), environment: environment.document)
        defer { controller.close() }
        controller.canvas.overlay.display()
        #expect(!controller.canvas.overlay.needsDisplay())
        environment.preferences.set(true, for: PreferenceCatalog.General.smallerHandles)
        #expect(controller.canvas.overlay.needsDisplay(), "Smaller handles repaints at once")
        #expect(controller.canvas.glyphStyle().smallerHandles)
        controller.canvas.overlay.display()
        environment.preferences.set(false, for: PreferenceCatalog.General.solidPoints)
        #expect(controller.canvas.overlay.needsDisplay() && !controller.canvas.glyphStyle().solidPoints)
        // A path drawn before enabling Show fill for new open paths keeps false; after, true.
        let document = DocumentHandle.memory(title: "Fill")
        let preferences = environment.preferences
        let host = RecordingHost()
        var context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.drawing = { DrawingSettings(preferences: preferences) }
        let pencil = PencilTool()
        pencil.activate(in: context)
        func stroke(_ y: Double) async -> OpID? {
            pencil.mouseDown(TestEvents.point(0, y))
            for x in stride(from: 10.0, through: 100, by: 10) { pencil.mouseDragged(TestEvents.point(x, y + (x.truncatingRemainder(dividingBy: 20) == 0 ? 5 : 0))) }
            let change = await document.perform(pencil.command()!).value
            pencil.cancel()
            return change?.createdObjects.first
        }
        let before = try #require(await stroke(0))
        preferences.set(true, for: PreferenceCatalog.Object.showFillOpenPaths)
        let after = try #require(await stroke(100))
        #expect(!document.state.props(before).path.fillWhenOpen && document.state.props(after).path.fillWhenOpen)
    }

    // MARK: Installing

    @Test func theToolsAndSplitAreInstalledWithTheirSheets() async throws {
        let environment = TestEnvironment()
        let tools = ToolRegistry()
        tools.registerBuiltIn()
        let commands = CommandRegistry()
        ContextMenuCatalog.register(into: commands)
        PathEditingFeatures.install(tools: tools, commands: commands, store: environment.preferences) { nil }
        for id in [VariableStrokePen.id, KnifeTool.id, FreeformTool.id, MirrorTool.id, Rotation3DTool.id] {
            let descriptor = try #require(tools.descriptor(for: id))
            #expect(!(descriptor.make() is UnimplementedTool), "\(id) is delivered")
            let sheet = try #require(descriptor.options?())
            #expect(sheet.title?.hasSuffix("Options") == true)
        }
        let split = try #require(commands.command(ContextMenuCatalog.ID.split))
        #expect(split.validation() == .disabled(Command.placeholderReason), "no points: the Split it replaced decides")
        if case .perform(let run) = split.action { run() }
        // With no points to split at, the previous Split's action runs.
        let ranPrevious = SelectionModel()
        let previous = Command(id: ContextMenuCatalog.ID.split, title: "Split", validation: { .enabled },
                               action: .perform { ranPrevious.set(Selection([SelectionID(OpID(counter: 1, replica: 1))])) })
        let shared = try #require(PathEditingFeatures.commands(target: { nil }, previous: previous).first)
        #expect(shared.validation() == .enabled)
        if case .perform(let run) = shared.action { run() }
        #expect(ranPrevious.count == 1)
        // With a window's editing: disabled until points are selected, then it splits.
        let document = DocumentHandle.memory(title: "Split command")
        let square = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100), Point(x: 0, y: 100)], closed: true))
        let editing = ObjectEditing(document: document, selection: SelectionController(document: document))
        let command = try #require(PathEditingFeatures.commands { editing }.first)
        #expect(command.validation() == .disabled(PathEditingFeatures.noPoints))
        let contour = try #require(document.path(square)?.contours[0])
        editing.selection.model.set(Selection([square]).applying([square], sub: [square: .points([PointReference(node: NodeID(square.opID), contour: contour.id, point: contour.drawn[2].id)])], mode: .replace))
        #expect(command.validation() == .enabled)
        if case .perform(let run) = command.action { run() }
        await document.settle()
        #expect(document.path(square)?.contours[0].closed == false)
        #expect(VariableStrokeSettings(preferences: environment.preferences) == VariableStrokeSettings())
        #expect(FreeformSettings(preferences: environment.preferences) == FreeformSettings())
    }
}
