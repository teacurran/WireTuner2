import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The edges of this batch's panels and sections: mixed values as the views show them, the
/// rendered bodies, the Text tool's selection, and the guards of the models.
@Suite(.serialized) @MainActor struct EditingEdgeTests {
    static func model(_ document: DocumentHandle, _ nodes: [OpID], session: TextEditingSession? = nil) -> ObjectPanelModel {
        ObjectPanelModel(document: document, selection: Selection(nodes.map { SelectionID($0) }), textSession: session)
    }

    // MARK: Text sections

    @Test func textSectionsRenderMixedValues() async throws {
        let document = DocumentHandle.memory(title: "Mixed")
        let a = try #require(await document.addText("Across", frame: .area(Rect(x: 0, y: 0, width: 100, height: 40))))
        let b = try #require(await document.addText("Down", frame: .area(Rect(x: 0, y: 100, width: 100, height: 40))))
        _ = await Self.model(document, [b]).perform(Self.model(document, [b]).setDirection(.vertical))?.value
        let blocks = try #require(Self.model(document, [a, b]).textBlock)
        #expect(blocks.direction == nil && TextBlockSectionView.direction(blocks, Self.model(document, [a, b])).wrappedValue == TextBlockSectionView.mixed)
        PanelRendering.host(TextBlockSectionView(section: blocks, model: Self.model(document, [a, b])))
        PanelRendering.host(TextBlockSectionView(section: try #require(Self.model(document, [b]).textBlock), model: Self.model(document, [b])))
        // Two texts on paths with different settings.
        let (first, _) = try await TextBlockSectionTests.attached(document)
        let (second, _) = try await TextBlockSectionTests.attached(document)
        _ = await document.perform(SetTextOnPath(node: second, values: .with { $0.orientation = .vertical; $0.top = .ascent; $0.bottom = .none }, fields: [2, 4, 5], label: "x")).value
        let paths = try #require(Self.model(document, [first, second]).textOnPath)
        #expect(paths.orientation == nil && paths.top == nil && paths.bottom == nil)
        PanelRendering.host(TextOnPathSectionView(section: paths, model: Self.model(document, [first, second])))
        PanelRendering.host(ObjectPanelBody(selection: ActiveSelection(model: SelectionModel(Selection([SelectionID(first)])), document: document)))
    }

    @Test func textOnAPathOfSeveralSegments() async throws {
        let document = DocumentHandle.memory(title: "Segments")
        let text = try #require(await document.addText("Along", at: Point(x: 0, y: 0)))
        let path = try #require(await document.addPath([Point(x: 0, y: 100), Point(x: 100, y: 100), Point(x: 100, y: 200)]))
        _ = await document.perform(AttachTextToPath(text: text, path: path.opID)).value
        let item = try #require(TextOnPath(text, in: document.state))
        #expect(abs(item.length - 200) < 1e-6)
        let corner = item.point(atLength: 150)
        #expect(abs(item.arcLength(nearest: corner) - 150) < 1e-6, "on the second segment")
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.selection.model.set(Selection([SelectionID(text)]))
        TextPathHandle().draw(in: DrawingToolTests.bitmap(), viewport: context.viewport, context: context)
    }

    @Test func theEffectPopUpFollowsTheTextToolsSelection() async throws {
        let document = DocumentHandle.memory(title: "Session")
        let text = try #require(await document.addText("Some words"))
        _ = await document.perform(ApplyMark(node: text, from: .start, to: .end, value: .with { $0.effect = TextEffectKind.zoom.defaultEffect })).value
        let session = TextEditingSession(document: document, sink: document, target: .node(text))
        session.select(anchor: 0, focus: 4)
        let model = Self.model(document, [text], session: session)
        #expect(model.textEffect?.kind == .zoom)
        _ = await model.setTextEffect(.shadow)?.value
        await document.settle()
        let runs = document.state.textNode(text)?.runs.map { TextEffectKind(TextEffectKind.effect(of: $0.values)) }
        #expect(runs == [.shadow, .zoom], "only the Text tool's selection")
        // An empty block reads as no effect.
        let empty = try #require(await document.perform(CreateTextBlock(.point(Point(x: 300, y: 300)))).value?.createdObjects.first)
        await document.settle()
        #expect(Self.model(document, [empty]).characterRuns == [[]])
    }

    // MARK: Find & Replace

    @Test func theFindReplacePanelRendersAndItsButtonsRun() async throws {
        let (document, _, courier, _) = try await TypeFindReplaceTests.fixture()
        _ = await document.perform(CreateTextBlock(.point(Point(x: 400, y: 400)))).value
        await document.settle()
        let selection = ActiveSelection(model: SelectionModel(Selection([SelectionID(courier)])), document: document)
        let state = FindReplaceState()
        #expect(FindReplaceState.Tab.replace.title == "Find & Replace")
        state.from = FontCriteria(family: "Courier")
        state.to = FontReplacement(family: "Menlo")
        let body = FindReplacePanelBody(selection: selection, state: state)
        PanelRendering.host(body)
        body.change()
        await document.settle()
        #expect(state.result == "2 blocks changed")
        FindReplacePanelBody.tab(state).wrappedValue = .select
        #expect(FindReplacePanelBody.tab(state).wrappedValue == .select)
        state.scope = .selection
        state.adjustSelection = true
        PanelRendering.host(body)
        state.from = FontCriteria(family: "Menlo")
        body.find()
        #expect(selection.model?.ids.isEmpty == true, "found in the selection and removed from it")
        state.attribute = .textEffect
        PanelRendering.host(body)
        var size: Double? = 12
        let field = FindReplacePanelBody.size(Binding(get: { size }, set: { size = $0 }))
        field.wrappedValue = "0"
        field.wrappedValue = "-4"
        #expect(size == 12, "sizes must be positive")
        // Nothing to replace in an empty block; page scope without a page reads everything.
        #expect(TypeAttributeSearch(document: document, selection: .empty).replaceFont(FontCriteria(), with: FontReplacement(size: 30), in: .document)?.blocks == 3)
    }

    // MARK: Align

    @Test func alignTitlesSingleBoxesAndPoints() async throws {
        for option in AlignOption.allCases {
            #expect(!option.title(horizontal: true).isEmpty && !option.title(horizontal: false).isEmpty)
        }
        #expect(AlignOption.minEdge.title(horizontal: false) == "Align top" && AlignOption.maxEdge.title(horizontal: true) == "Align right")
        #expect(AlignOption.distributeMin.title(horizontal: true) == "Distribute left edges" && AlignOption.distributeMax.title(horizontal: false) == "Distribute bottoms")
        let page = Rect(x: 0, y: 0, width: 100, height: 100)
        let one = [AlignLayout.Item(box: Rect(x: 10, y: 10, width: 20, height: 20))]
        for option in [AlignOption.distributeMin, .distributeCenter, .distributeMax, .distributeGaps] {
            let offsets = AlignLayout.offsets(one, settings: AlignSettings(horizontal: option, toPage: true), page: page)
            #expect(offsets.count == 1, "\(option)")
        }
        // Two points moving: "Align 2 points".
        let document = DocumentHandle.memory(title: "Points")
        let node = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 10, y: 20), Point(x: 30, y: 5)]))
        let contour = try #require(document.path(node)?.contours[0])
        let references = Set(contour.points.map { PointReference(node: NodeID(node.opID), contour: contour.id, point: $0.id) })
        let selection = Selection([node]).applying([node], sub: [node: .points(references)], mode: .replace)
        let command = try #require(AlignTarget(document: document, selection: selection).command(AlignSettings(vertical: .minEdge)))
        #expect(command.label == "Align 2 points")
        _ = await document.perform(command).value
        #expect(AlignTarget(document: document, selection: selection).command(AlignSettings(vertical: .minEdge)) == nil, "nothing left to move")
        let panel = AlignPanelState()
        panel.settings = AlignSettings(vertical: .maxEdge)
        let active = ActiveSelection(model: SelectionModel(selection), document: document)
        let body = AlignPanelBody(selection: active, state: panel)
        PanelRendering.host(body)
        body.apply()
        await document.settle()
        #expect(document.path(node)?.contours[0].drawn.allSatisfy { $0.anchor.y == 0 } == true)
    }

    // MARK: Names

    @Test func idleEditorEdges() async throws {
        var written: [String] = []
        let editor = IdleTextEditor(value: "a", limit: 20, idle: .seconds(60))
        editor.bind("a")
        #expect(editor.text == "a", "the same value changes nothing")
        editor.edit("ab")
        editor.connect { written.append($0) }
        editor.flush()
        #expect(written == ["ab"], "a burst typed before the writer connected goes to the writer")
        editor.edit("abc")
        editor.bind("remote")
        #expect(editor.text == "abc" && editor.value == "remote")
        editor.cancel()
        #expect(editor.text == "remote")
        let empty = IdleTextEditor(value: nil, limit: 20)
        empty.edit("x")
        empty.bind(nil)
        empty.cancel()
        #expect(empty.text == "")
        PanelRendering.host(IdleTextField(title: "Name", value: nil, limit: 256, identifier: "name") { _ in })
        PanelRendering.host(IdleTextField(title: "Note", value: "note", limit: 8_192, multiline: true, identifier: "note") { _ in })
    }

    // MARK: Transform panel

    @Test func transformPanelEdges() async throws {
        let document = DocumentHandle.memory(title: "Edges")
        let rects = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 90, y: 90, width: 10, height: 10)])
        let selection = ActiveSelection(model: SelectionModel(Selection(rects)), document: document)
        #expect(TransformPanelModel.center(of: rects.map(\.opID), in: document.state) == Point(x: 50, y: 50), "the union's centre")
        let state = TransformPanelState()
        state.model.moveX = 5
        let change = try #require(await TransformPanelBody.apply(state.model, selection: selection)?.value)
        #expect(change.label == "Move 2 objects")
        var value = 1.0
        TransformPanelBody.field("A", Binding(get: { value }, set: { value = $0 }), unit: .points, identifier: "a").commit(3)
        TransformPanelBody.field("B", Binding(get: { value }, set: { value = $0 }), units: Units(), identifier: "b").commit(4)
        #expect(value == 4)
        state.show(.scale)
        state.model.uniform = false
        let body = TransformPanelBody(selection: selection, state: state)
        PanelRendering.host(body)
        state.model.scaleX = 50
        body.applyNow()
        await document.settle()
        #expect(document.undoTitle == "Undo Scale 2 objects")
    }

    // MARK: Path tools

    @Test func pathToolsWithoutAWindowOrAGesture() async throws {
        let stroke = VariableStrokePen()
        stroke.mouseDragged(TestEvents.point(1, 1))
        stroke.mouseUp(TestEvents.point(1, 1))
        stroke.drawOverlay(in: DrawingToolTests.bitmap(), viewport: Viewport(size: Size(width: 10, height: 10)))
        let knife = KnifeTool()
        #expect(knife.settings() == KnifeSettings() && knife.command() == nil && knife.cutter().isEmpty)
        knife.mouseDragged(TestEvents.point(1, 1))
        knife.drawOverlay(in: DrawingToolTests.bitmap(), viewport: Viewport(size: Size(width: 10, height: 10)))
        let freeform = FreeformTool()
        freeform.mouseDown(TestEvents.point(0, 0))
        freeform.mouseUp(TestEvents.point(0, 0))
        #expect(freeform.tolerance() == FreeformSettings().pushPrecision.tolerance())
        freeform.drawOverlay(in: DrawingToolTests.bitmap(), viewport: Viewport(size: Size(width: 10, height: 10)))
        let mirror = MirrorTool()
        #expect(mirror.settings() == MirrorSettings())
        mirror.mouseDragged(TestEvents.point(1, 1))
        mirror.mouseUp(TestEvents.point(1, 1))
        mirror.drawOverlay(in: DrawingToolTests.bitmap(), viewport: Viewport(size: Size(width: 10, height: 10)))
        let rotation = Rotation3DTool()
        #expect(rotation.place(.center) == nil && rotation.rotation == nil)
        rotation.mouseDragged(TestEvents.point(1, 1))
        rotation.mouseUp(TestEvents.point(1, 1))
        rotation.drawOverlay(in: DrawingToolTests.bitmap(), viewport: Viewport(size: Size(width: 10, height: 10)))
        // Unknown preference values read as the defaults.
        let environment = TestEnvironment()
        typealias P = PathToolPreferences
        environment.preferences.set("bogus", for: P.freeformMode)
        environment.preferences.set("bogus", for: P.pullBend)
        environment.preferences.set("bogus", for: P.mirrorAxis)
        environment.preferences.set("bogus", for: P.rotationFrom)
        environment.preferences.set("bogus", for: P.projectFrom)
        #expect(FreeformSettings(preferences: environment.preferences).mode == .pushPull && FreeformSettings(preferences: environment.preferences).bend == .length)
        #expect(MirrorSettings(preferences: environment.preferences).axis == .vertical)
        #expect(Rotation3DSettings(preferences: environment.preferences).rotateFrom == .center && Rotation3DSettings(preferences: environment.preferences).projectFrom == .center)
        // The installed tools read their sheets' preferences.
        for descriptor in PathEditingFeatures.descriptors(store: environment.preferences) {
            switch descriptor.make() {
            case let tool as VariableStrokePen: _ = tool.settings()
            case let tool as KnifeTool: _ = tool.settings()
            case let tool as FreeformTool: _ = tool.settings()
            case let tool as MirrorTool: _ = tool.settings()
            case let tool as Rotation3DTool: _ = tool.settings()
            default: Issue.record("an unexpected tool")
            }
        }
    }

    @Test func restoringDuplicatePoints() {
        let square = [Point(x: 0, y: 0), Point(x: 10, y: 0)].enumerated().map { index, point in
            VectorPoint(id: OpID(counter: UInt64(index + 1), replica: 3), anchor: point)
        }
        let duplicates = PathSplitting.restored([square[0]], from: [square[0], square[0]])
        #expect(duplicates == [square[0]])
    }

    @Test func knifeAndSplitOverSeveralPaths() async throws {
        let document = DocumentHandle.memory(title: "Several")
        let a = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 50), Point(x: 0, y: 50)], closed: true))
        let b = try #require(await document.addPath([Point(x: 0, y: 100), Point(x: 100, y: 100), Point(x: 100, y: 150), Point(x: 0, y: 150)], closed: true))
        let knife = try #require(PathSplitting.knife(Selection([a, b]), document: document, cutter: [Point(x: 50, y: -10), Point(x: 50, y: 200)], settings: KnifeSettings()))
        #expect(knife.label == "Knife" && knife is CompositeCommand)
        let pointsA = try #require(document.path(a)?.contours[0])
        let pointsB = try #require(document.path(b)?.contours[0])
        let selection = Selection([a, b]).applying([a, b], sub: [
            a: .points([PointReference(node: NodeID(a.opID), contour: pointsA.id, point: pointsA.drawn[1].id)]),
            b: .points([PointReference(node: NodeID(b.opID), contour: pointsB.id, point: pointsB.drawn[2].id)]),
        ], mode: .replace)
        let split = try #require(PathSplitting.split(selection, document: document))
        #expect(split.label == "Split" && split is CompositeCommand)
        // A straight knife constrained with Shift.
        let f = DrawingToolTests.Fixture(KnifeTool { KnifeSettings(straight: true) }, document: document)
        f.tool.mouseDown(TestEvents.point(0, 0))
        f.tool.mouseDragged(TestEvents.point(30, 2, .shift))
        #expect(f.tool.cutter() == [.zero, Point(x: 30, y: 0)])
    }

    @Test func freeformEdges() async throws {
        let document = DocumentHandle.memory(title: "Freeform edges")
        let a = try await FreeformToolTests.line(document)
        let b = try #require(await document.addPath([Point(x: 0, y: 300), Point(x: 300, y: 300)]))
        var settings = FreeformSettings()
        settings.bend = .points
        let f = DrawingToolTests.Fixture(FreeformTool { [settings] in settings }, document: document)
        f.selection.model.set(Selection([a, b]))
        // Option swaps Between points back to By length; the grab picks the nearer of two paths.
        f.tool.mouseDown(TestEvents.point(10, 100, .option))
        #expect(f.tool.gesture == .pull(bend: .length) && f.tool.grab?.contour == 0)
        // Pulling the start: the end point moves with the stretch.
        f.tool.mouseDragged(TestEvents.point(10, 80))
        f.tool.mouseUp(TestEvents.point(10, 80))
        await document.settle()
        #expect(document.path(a)?.contours[0].drawn.first?.anchor.y ?? 100 < 100)
        // A push across both paths writes both in one change.
        f.tool.mouseDown(TestEvents.point(150, 200))
        f.tool.mouseDragged(TestEvents.point(150, 290))
        f.tool.mouseDragged(TestEvents.point(150, 50))
        f.tool.mouseUp(TestEvents.point(150, 50))
        await document.settle()
        #expect(document.undoTitle == "Undo Freeform")
        // Between points on the last segment, grabbed at its very end.
        let line = try #require(document.path(b)?.contours[0].drawn)
        let contour = FreeformContour(node: b.opID, contour: .zero, closed: false, points: line)
        #expect(FreeformTool.bendSegment(contour, grab: contour.samples.count - 1, by: Vector(dx: 0, dy: 5)) != nil)
        let closed = FreeformContour(node: .zero, contour: .zero, closed: true, points: [VectorPoint(anchor: .zero), VectorPoint(anchor: Point(x: 10, y: 0)), VectorPoint(anchor: Point(x: 5, y: 8))])
        #expect(closed.preview.count == closed.samples.count + 1)
        f.tool.pointerMoved(TestEvents.point(3, 3))
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
    }

    @Test func remainingToolEdges() async throws {
        #expect(Rotation3DSettings.place("nowhere") == .center && FreeformSettings.mode("x") == .pushPull && FreeformSettings.bend("x") == .length)
        #expect(MirrorSettings.axis("diagonal") == .vertical)
        let document = DocumentHandle.memory(title: "Remaining")
        let line = try await FreeformToolTests.line(document)
        let host = RecordingHost()
        var context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.drawing = { DrawingSettings(constrainAngle: 0) }
        context.selection.model.set(Selection([line]))
        // 3D Rotation: the cursor, a modifier change before any drag, the centre of gravity of a path.
        let rotation = Rotation3DTool { Rotation3DSettings(expert: true) }
        rotation.activate(in: context)
        #expect(rotation.cursor == .crosshair)
        rotation.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(rotation.place(.gravity) == Point(x: 150, y: 100))
        rotation.mouseDown(TestEvents.point(150, 100))
        rotation.mouseDragged(TestEvents.point(170, 110))
        rotation.flagsChanged(TestEvents.point(170, 110, .shift))
        rotation.drawOverlay(in: DrawingToolTests.bitmap(), viewport: context.viewport)
        rotation.cancel()
        // Freeform: Option at the press turns By length into Between points; a click writes nothing;
        // pulling the end moves the end point.
        let freeform = FreeformTool()
        freeform.activate(in: context)
        freeform.mouseDown(TestEvents.point(150, 100, .option))
        #expect(freeform.gesture == .pull(bend: .points))
        freeform.cancel()
        freeform.mouseDown(TestEvents.point(150, 100))
        #expect(freeform.command() == nil, "nothing moved")
        freeform.mouseUp(TestEvents.point(150, 100))
        freeform.mouseDown(TestEvents.point(299, 100))
        freeform.mouseUp(TestEvents.point(299, 80))
        await document.settle()
        #expect(document.path(line)?.contours[0].drawn.last?.anchor.y ?? 100 < 100, "the end point followed")
        // Between points on a zero-length segment bends at its middle.
        let repeated = FreeformContour(node: .zero, contour: .zero, closed: false, points: [VectorPoint(anchor: .zero), VectorPoint(anchor: .zero), VectorPoint(anchor: Point(x: 10, y: 0))])
        #expect(FreeformTool.bendSegment(repeated, grab: 1, by: Vector(dx: 0, dy: 3)) != nil)
        // The Variable Stroke Pen with Shift and a dotted trail.
        var dotted = VariableStrokeSettings()
        dotted.dotted = true
        let pen = VariableStrokePen { [dotted] in dotted }
        pen.activate(in: context)
        pen.mouseDown(TestEvents.point(0, 0))
        pen.mouseDragged(TestEvents.point(20, 5, [.option, .shift]))
        pen.mouseDragged(TestEvents.point(40, 5))
        pen.drawOverlay(in: DrawingToolTests.bitmap(), viewport: context.viewport)
        pen.cancel()
    }

    @Test func mirrorAndRotationEdges() async throws {
        let document = DocumentHandle.memory(title: "Edges")
        let text = try #require(await document.addText("No bounds", at: Point(x: 10, y: 10)))
        let closedPath = try #require(await document.addPath([Point(x: 100, y: 0), Point(x: 80, y: 20), Point(x: 100, y: 40)], closed: true))
        let far = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 20, y: 20)]))
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        // Nothing selected.
        let mirror = MirrorTool { MirrorSettings(axis: .multiple, axes: 2, rotate: true) }
        mirror.activate(in: context)
        mirror.mouseDown(TestEvents.point(0, 0))
        #expect(mirror.command() == nil)
        // Rotated multiple copies; a text (no bounds) in the overlay.
        context.selection.model.set(Selection([SelectionID(text), far]))
        mirror.drawOverlay(in: DrawingToolTests.bitmap(), viewport: context.viewport)
        mirror.mouseUp(TestEvents.point(0, 0))
        await document.settle()
        #expect(document.undoTitle == "Undo Mirror")
        // Close paths finds nothing to join (a closed path; an open one far from the axis): copies instead.
        context.selection.model.set(Selection([closedPath, far]))
        let closer = MirrorTool { MirrorSettings(axis: .horizontal, closePaths: true) }
        closer.activate(in: context)
        closer.mouseDown(TestEvents.point(500, 500))
        let fallback = try #require(closer.command())
        #expect(fallback.label == "Mirror")
        // 3D Rotation: no drag distance writes nothing; the overlay with a text and the expert eye.
        let rotation = Rotation3DTool { Rotation3DSettings(expert: true, projectFrom: .origin) }
        rotation.activate(in: context)
        #expect(rotation.place(.center) != nil)
        context.selection.model.set(.empty)
        #expect(rotation.place(.center) == nil)
        context.selection.model.set(Selection([SelectionID(text), far]))
        rotation.mouseDown(TestEvents.point(5, 5))
        #expect(rotation.command() == nil)
        rotation.mouseDragged(TestEvents.point(40, 5))
        rotation.drawOverlay(in: DrawingToolTests.bitmap(), viewport: context.viewport)
        rotation.mouseUp(TestEvents.point(5, 5))
    }
}
