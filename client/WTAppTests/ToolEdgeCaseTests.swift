import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The content changes a document delivered.
@MainActor
final class ChangeLog {
    var changes: [ContentChange] = []
}

/// The edges of the OBJ and DRAW tools and panel sections: stray events, degenerate drags, the
/// window's wiring.
@Suite @MainActor struct ToolEdgeCaseTests {
    @Test func transformToolsIgnoreStrayEventsAndDegenerateDrags() async throws {
        let document = DocumentHandle.memory(title: "Edges")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        let group = await document.perform(GroupObjects([rect.opID])).value!.createdObjects[0]
        await document.settle()
        let selection = SelectionController(document: document)
        let host = RecordingHost()
        let sink = RecordingSink()
        let tool = TransformTool(.scale)
        var context = ToolContext(document: document, host: host, selection: selection)
        context.commandSink = sink
        tool.activate(in: context)
        tool.mouseDragged(TestEvents.point(5, 5))
        tool.flagsChanged(TestEvents.point(0, 0, .shift))
        tool.mouseUp(TestEvents.point(5, 5))
        #expect(tool.preview.isEmpty && sink.commands.isEmpty)
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: host.viewport)
        selection.model.set(Selection([SelectionID(group)]))
        // A reference straight above the centre: no horizontal factor; a near-zero drag clamps.
        tool.mouseDown(TestEvents.point(0, 0))
        tool.mouseDragged(TestEvents.point(0, 10))
        tool.mouseDragged(TestEvents.point(5, 0.00001))
        let matrix = try #require(tool.matrix)
        #expect(matrix.a == 1 && matrix.d == TransformTool.minimumScale)
        #expect(tool.preview.count == 1, "a group previews by its box")
        tool.mouseDragged(TestEvents.point(5, -0.00001))
        #expect(tool.matrix?.d == -TransformTool.minimumScale)
        tool.cancel()
        let skew = TransformTool(.skew)
        skew.activate(in: context)
        skew.mouseDown(TestEvents.point(0, 0))
        skew.mouseDragged(TestEvents.point(10, 0))
        skew.mouseDragged(TestEvents.point(12, 3, .shift))
        #expect(skew.matrix?.c == 0 && skew.matrix?.b == 0.3)
        let reflect = TransformTool(.reflect)
        reflect.activate(in: context)
        reflect.mouseDown(TestEvents.point(0, 0))
        reflect.mouseDragged(TestEvents.point(10, 0))
        reflect.mouseDragged(TestEvents.point(10, 1, .shift))
        #expect(reflect.matrix.map { nearlyEqual($0, WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)) } == true)
        let move = TransformTool(.move)
        move.activate(in: context)
        move.mouseDown(TestEvents.point(0, 0))
        move.mouseDragged(TestEvents.point(10, 0))
        move.mouseDragged(TestEvents.point(15, 5))
        #expect(move.matrix == .translation(x: 5, y: 5))
        // A deleted object drops out of the preview.
        _ = await document.perform(DeleteNodes([group])).value
        #expect(move.preview.isEmpty)
    }

    @Test func descriptorsAndContextFreeTools() async throws {
        #expect(PointerTool.subselectDescriptor.make().toolID == PointerTool.subselectID)
        #expect(LassoTool.descriptor.make() is LassoTool)
        #expect(PencilTool.descriptor.make().cursor == NSCursor.crosshair)
        let pointer = PointerTool()
        #expect(pointer.moveCommand(Vector(dx: 1, dy: 0), copy: false) == nil)
        pointer.mouseDown(TestEvents.point(0, 0))
        pointer.mouseDragged(TestEvents.point(20, 0))
        #expect(pointer.movePreview.isEmpty && pointer.moveDelta == nil)
        pointer.mouseUp(TestEvents.point(20, 0))
        let pencil = PencilTool()
        #expect(pencil.continuation(at: .zero) == nil && pencil.command() == nil)
        pencil.mouseDown(TestEvents.point(0, 0))
        pencil.mouseDragged(TestEvents.point(5, 5))
        pencil.drawOverlay(in: DrawingToolTests.bitmap(), viewport: Viewport(size: Size(width: 10, height: 10)))
        pencil.mouseUp(TestEvents.point(5, 5))
        // Points of two paths move together as "Move Points".
        let document = DocumentHandle.memory(title: "Points")
        let one = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 10, y: 0)]))
        let two = try #require(await document.addPath([Point(x: 0, y: 20), Point(x: 10, y: 20)]))
        func first(_ id: SelectionID) -> PointReference {
            let contour = document.path(id)!.contours[0]
            return PointReference(node: id.node, contour: contour.id, point: contour.points[0].id)
        }
        var selection = Selection([one, two])
        selection.setSubSelection(.points([first(one)]), for: one)
        selection.setSubSelection(.points([first(two), PointReference(node: two.node, contour: .zero, point: OpID(counter: 999, replica: 1))]), for: two)
        #expect(ObjectEditing.moveCommand(Vector(dx: 1, dy: 1), selection: selection, document: document)?.label == "Move Points")
        // A Pen click on a curved segment of a selected path splits it at the nearest point.
        let curve = await document.perform(CreatePath(contours: [NewContour(points: [
            VectorPoint(anchor: Point(x: 0, y: 100), outHandle: Vector(dx: 0, dy: -40), kind: .curve),
            VectorPoint(anchor: Point(x: 100, y: 100), inHandle: Vector(dx: 0, dy: -40), kind: .curve),
        ])])).value!.createdObjects[0]
        await document.settle()
        let controller = SelectionController(document: document)
        controller.model.set(Selection([SelectionID(curve)]))
        let pen = PenTool()
        let host = RecordingHost()
        var context = ToolContext(document: document, host: host, selection: controller)
        context.drawing = { DrawingSettings() }
        pen.activate(in: context)
        let apex = try #require(document.path(SelectionID(curve))?.contours[0].segments[0].cubic.evaluate(0.5))
        pen.mouseDown(TestEvents.point(apex.x, apex.y))
        pen.mouseUp(TestEvents.point(apex.x, apex.y))
        await pen.settle()
        await document.settle()
        #expect(document.path(SelectionID(curve))?.pointCount == 3)
    }

    @Test func dragDrawingToolsWithoutAContext() {
        let spiral = SpiralTool()
        #expect(spiral.ends == nil && spiral.path == nil && spiral.settings == DrawingSettings())
        spiral.mouseDown(TestEvents.point(3, 4))
        #expect(spiral.anchor == Point(x: 3, y: 4), "no snapping without a context")
        let arc = ArcTool()
        #expect(arc.path == nil)
        arc.mouseDown(TestEvents.point(0, 0))
        arc.mouseDragged(TestEvents.point(-10, -4, .shift))
        #expect(arc.path?.contours[0].points[1].anchor == Point(x: -10, y: -10))
        #expect(DragDrawingTool().command() == nil && DragDrawingTool().preview == nil && DragDrawingTool.id == "polygon")
    }

    @Test func sizeAndRadiusEditsAtTheirEdges() async throws {
        let document = DocumentHandle.memory(title: "Edges")
        let vertical = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 0, y: 40)]))
        let model = ObjectPanelModel(document: document, selection: Selection([vertical]))
        _ = await model.perform(model.setSize(width: 10, height: 80, proportional: false))?.value
        #expect(abs(ObjectPanelModel(document: document, selection: Selection([vertical])).common!.height! - 80) < 1e-9)
        let lone = try #require(await document.addPath([Point(x: 5, y: 5)]))
        let degenerate = ObjectPanelModel(document: document, selection: Selection([lone]))
        #expect(degenerate.common == nil || degenerate.setPosition(x: 3) == nil)
        #expect(degenerate.setSize(width: 3, proportional: false) == nil)
        var ids: [SelectionID] = []
        for radius in [1.0, 2.0] {
            let change = await document.perform(CreateShape(.rectangle(.uniform(radius)), size: Size(width: 20, height: 20))).value
            ids.append(SelectionID(change!.createdObjects[0]))
        }
        await document.settle()
        let mixed = ObjectPanelModel(document: document, selection: Selection(ids))
        _ = await mixed.perform(mixed.setUniform(true))?.value
        #expect(document.state.props(ids[1].opID).rect.corners.topLeft == 0, "Uniform over mixed radii starts from 0")
        let star = await document.perform(CreatePolygon(PolygonShape(sides: 5, radius: 10), center: .zero)).value!.createdObjects[0]
        let star2 = await document.perform(CreatePolygon(PolygonShape(sides: 5, radius: 10), center: .zero)).value!.createdObjects[0]
        await document.settle()
        let polygons = ObjectPanelModel(document: document, selection: Selection([SelectionID(star), SelectionID(star2)]))
        #expect(polygons.setPolygon(.init(sides: 6), label: "Change sides")?.label == "Change sides of 2 objects")
        for props in [Wiretuner_Doc_V1_NodeProps.with { $0.ellipse.common.name = "e" }, .with { $0.polygon.common.name = "e" },
                      .with { $0.group.common.name = "e" }, .with { $0.path.common.name = "e" }, .with { $0.rect.common.name = "e" }] {
            #expect(PanelProps.common(props).name == "e")
        }
    }

    @Test func aReloadRebuildsTheSceneAndDropsWhatNoLongerResolves() async throws {
        let document = DocumentHandle.memory(title: "Reload")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        let selection = SelectionController(document: document)
        selection.model.set(Selection([rect]))
        let log = ChangeLog()
        document.observe { log.changes.append($0) }
        let backend = try #require(document.model?.backend as? MemoryBackend)
        var replacement = DocumentCore(state: EngineState(), replica: 0x5A)
        let fresh = try #require(try replacement.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5)),
                                                         recording: DocumentCore.Recording(limit: 10, now: Date()))?.change?.createdObjects.first)
        await backend.replace(with: replacement)
        await document.reload().value
        #expect(document.object(for: rect) == nil && document.object(for: SelectionID(fresh)) != nil)
        #expect(selection.selection.isEmpty, "the selected object no longer resolves")
        let last = try #require(log.changes.last)
        #expect(last.summary.isStructural && last.summary.touchedNodes.contains(NodeID(fresh)))
    }

    @Test func theWindowWiresTheObjectCommands() async throws {
        let environment = TestEnvironment()
        let document = DocumentHandle.memory(title: "Wiring")
        let controller = DocumentWindowController(document: document, environment: environment.document)
        #expect(controller.objectEditing.rememberLayerInfo() == false)
        #expect(controller.selection.lassoContactSensitive() == false)
        #expect(controller.objectEditing.visibleCenter() != nil)
        // Clear on selected segments deletes one per contour.
        let path = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 20, y: 0), Point(x: 30, y: 0)]))
        let contour = document.path(path)!.contours[0]
        let segments = Set(contour.segments.prefix(2).map { SegmentReference(node: path.node, contour: contour.id, from: $0.from.id) })
        controller.selection.model.set(Selection([path]).applying([path], sub: [path: .segments(segments)], mode: .add))
        #expect(controller.deletionCommand()?.label == "Delete Segment")
        #expect(controller.validate(selector: #selector(DocumentWindowController.cut(_:))))
        #expect(controller.validate(selector: #selector(DocumentWindowController.copy(_:))))
        controller.copy(nil)
        #expect(controller.validate(selector: #selector(DocumentWindowController.paste(_:))))
        controller.paste(nil)
        await document.settle()
        controller.selection.model.set(Selection([path]))
        controller.cut(nil)
        await document.settle()
        #expect(document.undoTitle == "Undo Cut")
        controller.close()
    }
}
