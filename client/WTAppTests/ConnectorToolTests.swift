import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-036: the Connector tool -- hover and side highlighting, create by drag, end re-attachment
/// and freeing, run handles -- driven with the events the canvas delivers (the UI tests of *Done
/// when*, hosted in the app).
@Suite @MainActor struct ConnectorToolTests {
    static let viewport = Viewport(size: Size(width: 400, height: 300))
    static let a = Rect(x: 10, y: 10, width: 50, height: 50)
    static let b = Rect(x: 200, y: 10, width: 50, height: 50)
    static let c = Rect(x: 100, y: 150, width: 50, height: 50)

    /// The rendered bounds an end sits on: the rectangle grown by half its 1 pt stroke.
    static func attached(_ rect: Rect) -> Rect { rect.expanded(by: 0.5) }

    /// A point just inside `rect` nearest `side`.
    static func near(_ side: ConnectorSide, of rect: Rect) -> Point {
        switch side {
        case .top: Point(x: rect.midX, y: rect.minY + 2)
        case .bottom: Point(x: rect.midX, y: rect.maxY - 2)
        case .left: Point(x: rect.minX + 2, y: rect.midY)
        case .right: Point(x: rect.maxX - 2, y: rect.midY)
        }
    }

    static func close(_ p: Point, _ q: Point, _ tolerance: Double = 0.01) -> Bool { p.distance(to: q) < tolerance }

    /// A bitmap context to draw overlays into.
    static func context() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Connectors")
        let host = RecordingHost(viewport: ConnectorToolTests.viewport)
        let controller: SelectionController
        let tool = ConnectorTool()
        private(set) var rects: [Rect] = []
        private(set) var boxes: [SelectionID] = []

        init() {
            document.pages = [Rect(x: 0, y: 0, width: 400, height: 300)]
            controller = SelectionController(document: document)
            tool.activate(in: ToolContext(document: document, host: host, selection: controller))
        }

        static func make(_ rects: [Rect] = [ConnectorToolTests.a, ConnectorToolTests.b, ConnectorToolTests.c]) async -> Fixture {
            let fixture = Fixture()
            fixture.rects = rects
            fixture.boxes = await fixture.document.addRectangles(rects)
            return fixture
        }

        func drag(_ from: Point, _ to: Point) async {
            tool.mouseDown(TestEvents.point(from.x, from.y))
            tool.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2))
            tool.mouseDragged(TestEvents.point(to.x, to.y))
            tool.mouseUp(TestEvents.point(to.x, to.y))
            await document.settle()
        }

        func click(_ at: Point) async {
            tool.mouseDown(TestEvents.point(at.x, at.y))
            tool.mouseUp(TestEvents.point(at.x, at.y))
            await document.settle()
        }

        /// Waits for the selection a creation sets once its change lands.
        func selectedConnector() async -> OpID? {
            for _ in 0..<500 {
                if let id = controller.selection.ids.first, document.object(for: id)?.kind == .connector { return id.opID }
                await Task.yield()
            }
            return nil
        }

        /// The end on `side` of box `box`.
        func end(_ box: Int, _ side: ConnectorSide) -> ConnectorEnd {
            ConnectorEnd(node: boxes[box].node, side: side, point: side.midpoint(of: ConnectorToolTests.attached(rects[box])))
        }

        /// A connector between two box sides, selected.
        func connector(_ start: (Int, ConnectorSide), _ end: (Int, ConnectorSide)) async throws -> OpID {
            let change = try #require(await document.perform(CreateConnector(start: self.end(start.0, start.1), end: self.end(end.0, end.1))).value)
            await document.settle()
            let node = try #require(change.createdObjects.first)
            controller.model.set(Selection([SelectionID(node)]))
            return node
        }

        /// Adds boxes one change each and hands every change to `relay` (another replica's log).
        func add(_ added: [Rect], relay: (Wiretuner_Doc_V1_Change) async throws -> Void) async throws {
            for rect in added {
                let command = CreateShape(
                    .rectangle(CornerRadii()), size: Size(width: rect.width, height: rect.height),
                    transform: .translation(x: rect.minX, y: rect.minY), appearance: TestAppearance.filled
                )
                let change = try #require(await document.perform(command).value)
                rects.append(rect)
                boxes.append(SelectionID(try #require(change.createdObjects.first)))
                try await relay(change)
            }
            await document.settle()
        }

        typealias End = (node: OpID?, side: ConnectorSide?, point: Point)

        func stored(_ connector: OpID) -> (start: End, end: End, offsets: [Double]) {
            let props = Connectors.props(connector, in: document.state)
            return (Connectors.storedEnd(props.start), Connectors.storedEnd(props.end), props.runOffsets)
        }
    }

    // MARK: Creating

    @Test(arguments: ConnectorSide.allCases)
    func aDragBetweenTwoBoxesConnectsTheSidesPressedAndReleasedOn(startSide: ConnectorSide) async throws {
        for endSide in ConnectorSide.allCases {
            let f = await Fixture.make([Self.a, Self.b])
            let changes = f.document.changeCount
            await f.drag(Self.near(startSide, of: Self.a), Self.near(endSide, of: Self.b))
            #expect(f.document.changeCount == changes + 1, "one change per creation")
            #expect(f.document.undoTitle == "Undo Connector")
            let connector = try #require(await f.selectedConnector(), "the new connector is selected")
            let stored = f.stored(connector)
            #expect(stored.start.node == f.boxes[0].opID && stored.start.side == startSide)
            #expect(stored.end.node == f.boxes[1].opID && stored.end.side == endSide)
            #expect(Self.close(stored.start.point, startSide.midpoint(of: Self.attached(Self.a))), "the end's point is where it attaches now")
            #expect(Self.close(stored.end.point, endSide.midpoint(of: Self.attached(Self.b))))
            let handles = try #require(ConnectorHandles.make(connector, in: f.document))
            #expect(Self.close(handles.position(.end(.start)), startSide.midpoint(of: Self.attached(Self.a))))
            #expect(Self.close(handles.position(.end(.end)), endSide.midpoint(of: Self.attached(Self.b))))
        }
    }

    @Test func releasingOverEmptyCanvasEndsAtAFreePoint() async throws {
        let f = await Fixture.make()
        await f.drag(Self.near(.right, of: Self.a), Point(x: 330, y: 250))
        let connector = try #require(await f.selectedConnector())
        let stored = f.stored(connector)
        #expect(stored.start.node == f.boxes[0].opID && stored.start.side == .right)
        #expect(stored.end.node == nil && Self.close(stored.end.point, Point(x: 330, y: 250)))
        f.controller.model.clear()
        await f.drag(Point(x: 330, y: 100), Self.near(.top, of: Self.c))
        let second = try #require(await f.selectedConnector())
        #expect(second != connector)
        #expect(f.stored(second).start.node == nil && Self.close(f.stored(second).start.point, Point(x: 330, y: 100)), "a press on nothing starts free")
        #expect(f.stored(second).end.node == f.boxes[2].opID && f.stored(second).end.side == .top)
    }

    @Test func hoverHighlightsTheAttachableObjectAndItsNearestSide() async throws {
        let f = await Fixture.make()
        #expect(f.tool.cursor == NSCursor.crosshair)
        #expect(f.host.messages.last == ConnectorTool.statusMessage)
        f.tool.pointerMoved(TestEvents.point(35, 12))
        #expect(f.tool.hover?.node == f.boxes[0].opID && f.tool.hover?.side == .top)
        #expect(f.tool.cursor == NSCursor.pointingHand, "the pointer shows the object can be connected")
        let overlays = f.host.overlayRequests, cursors = f.host.cursorChanges
        #expect(cursors == 1)
        f.tool.pointerMoved(TestEvents.point(35, 12))
        #expect(f.host.overlayRequests == overlays, "no change, no redraw")
        f.tool.pointerMoved(TestEvents.point(12, 35))
        #expect(f.tool.hover?.side == .left && f.host.overlayRequests == overlays + 1 && f.host.cursorChanges == cursors)
        f.tool.pointerMoved(TestEvents.point(35, 58.5))
        #expect(f.tool.hover?.side == .bottom)
        f.tool.pointerMoved(TestEvents.point(62, 35))
        #expect(f.tool.hover?.side == .right, "just outside, within the pick distance")
        #expect(f.tool.hover?.edge.0 == Point(x: 60.5, y: 9.5) && f.tool.hover?.edge.1 == Point(x: 60.5, y: 60.5))
        #expect(f.tool.hover?.point == Point(x: 60.5, y: 35))
        f.tool.drawOverlay(in: Self.context(), viewport: Self.viewport)
        f.tool.pointerMoved(TestEvents.point(330, 250))
        #expect(f.tool.hover == nil && f.tool.cursor == NSCursor.crosshair && f.host.cursorChanges == cursors + 1)
        // Over a selected connector's handle the cursor changes too; while pressed, hovering stops.
        let connector = try await f.connector((0, .right), (1, .left))
        let handles = try #require(ConnectorHandles.make(connector, in: f.document))
        let end = handles.position(.end(.end))
        f.tool.pointerMoved(TestEvents.point(end.x + 6, end.y + 20))
        #expect(!f.tool.hoverHandle)
        f.tool.pointerMoved(TestEvents.point(end.x - 4, end.y + 1))
        #expect(f.tool.hoverHandle && f.tool.cursor == NSCursor.pointingHand)
        f.tool.mouseDown(TestEvents.point(end.x - 4, end.y + 1))
        f.tool.pointerMoved(TestEvents.point(330, 250))
        #expect(f.tool.hoverHandle, "pointer tracking waits for the release")
        f.tool.cancel()
    }

    @Test func aConnectorIsNotAttachable() async throws {
        let f = await Fixture.make()
        _ = try await f.connector((0, .bottom), (1, .bottom))
        // The route runs under both boxes: its lowest run is outside every box.
        let route = try #require(ConnectorHandles.make(f.controller.selection.ids[0].opID, in: f.document)?.route)
        let low = route.points.map(\.y).max()!
        #expect(ConnectorTarget.find(at: Point(x: 130, y: low), tolerance: 3, in: f.document) == nil)
        #expect(ConnectorTarget.find(at: Point(x: 35, y: 35), tolerance: 3, in: f.document)?.node == f.boxes[0].opID)
    }

    // MARK: Clicking

    @Test func clicksSelectAndPressesOnAConnectorsLinePickIt() async throws {
        let f = await Fixture.make()
        let connector = try await f.connector((0, .right), (2, .left))
        f.controller.model.clear()
        await f.click(Point(x: 330, y: 250))
        #expect(f.controller.selection.isEmpty)
        await f.click(Point(x: 35, y: 35))
        #expect(f.controller.selection.ids == [f.boxes[0]], "a click on an object selects it")
        await f.click(Point(x: 330, y: 250))
        #expect(f.controller.selection.isEmpty, "a click on nothing deselects")
        let handles = try #require(ConnectorHandles.make(connector, in: f.document))
        #expect(handles.runCount == 1)
        let run = handles.run(0)
        let onLine = Point(x: run.0.x, y: (run.0.y + run.1.y) / 2 + 20)
        let changes = f.document.changeCount
        f.tool.mouseDown(TestEvents.point(onLine.x, onLine.y))
        #expect(f.tool.gesture == .pick)
        #expect(f.controller.selection.ids == [SelectionID(connector)], "a press on its line selects it")
        f.tool.mouseDragged(TestEvents.point(onLine.x + 40, onLine.y))
        #expect(f.tool.preview == nil && f.tool.command(releasedAt: TestEvents.point(onLine.x + 40, onLine.y)) == nil)
        f.tool.mouseUp(TestEvents.point(onLine.x + 40, onLine.y))
        await f.document.settle()
        #expect(f.document.changeCount == changes, "dragging a connector's line does nothing")
        // Inside a box, a press starts a connector even where one leaves that side.
        f.controller.model.clear()
        f.tool.mouseDown(TestEvents.point(58, 35))
        #expect(f.tool.gesture == .create(start: f.end(0, .right)))
        f.tool.cancel()
    }

    @Test func escapeAbandonsTheDrag() async throws {
        let f = await Fixture.make()
        let changes = f.document.changeCount
        #expect(!f.tool.hasSomethingToCancel)
        f.tool.mouseDown(TestEvents.point(58, 35))
        f.tool.mouseDragged(TestEvents.point(202, 35))
        #expect(f.tool.hasSomethingToCancel && f.tool.isDragging)
        #expect(f.tool.hover?.node == f.boxes[1].opID)
        #expect(f.tool.preview?.points.first == Point(x: 60.5, y: 35) && f.tool.preview?.points.last == Point(x: 199.5, y: 35))
        f.tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(f.tool.current?.modifiers == .shift)
        f.tool.drawOverlay(in: Self.context(), viewport: Self.viewport)
        f.tool.cancel()
        f.tool.mouseDragged(TestEvents.point(210, 40))
        f.tool.mouseUp(TestEvents.point(210, 40))
        await f.document.settle()
        #expect(f.document.changeCount == changes, "nothing is written")
        #expect(!f.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        f.tool.flagsChanged(TestEvents.point(0, 0, .option))
        #expect(f.tool.current == nil)
    }

    // MARK: Ends

    @Test func draggingAnEndReattachesItThenFreesIt() async throws {
        let f = await Fixture.make()
        let connector = try await f.connector((0, .right), (1, .left))
        let changes = f.document.changeCount
        let end = Point(x: 199.5, y: 35)
        f.tool.mouseDown(TestEvents.point(end.x, end.y))
        #expect(f.tool.gesture == .moveEnd(connector, .end))
        f.tool.mouseDragged(TestEvents.point(125, 152))
        #expect(f.tool.hover?.node == f.boxes[2].opID && f.tool.hover?.side == .top)
        #expect(Self.close(f.tool.preview!.points.last!, Point(x: 125, y: 149.5)), "the preview follows the new side")
        f.tool.drawOverlay(in: Self.context(), viewport: Self.viewport)
        f.tool.mouseUp(TestEvents.point(125, 152))
        await f.document.settle()
        #expect(f.document.changeCount == changes + 1 && f.document.undoTitle == "Undo Move Connector End")
        var stored = f.stored(connector)
        #expect(stored.end.node == f.boxes[2].opID && stored.end.side == .top && Self.close(stored.end.point, Point(x: 125, y: 149.5)))
        #expect(stored.start.node == f.boxes[0].opID, "the other end is untouched")
        // The start moves to another side of the same box.
        f.tool.mouseDown(TestEvents.point(60.5, 35))
        #expect(f.tool.gesture == .moveEnd(connector, .start))
        f.tool.mouseDragged(TestEvents.point(35, 50))
        #expect(Self.close(f.tool.preview!.points.first!, Point(x: 35, y: 60.5)), "the preview follows the start too")
        f.tool.mouseUp(TestEvents.point(35, 58))
        await f.document.settle()
        stored = f.stored(connector)
        #expect(stored.start.node == f.boxes[0].opID && stored.start.side == .bottom)
        // Dropped on empty canvas the end is free there.
        f.tool.mouseDown(TestEvents.point(125, 149.5))
        f.tool.mouseDragged(TestEvents.point(300, 200))
        #expect(f.tool.hover == nil)
        f.tool.mouseUp(TestEvents.point(330, 250))
        await f.document.settle()
        stored = f.stored(connector)
        #expect(stored.end.node == nil && Self.close(stored.end.point, Point(x: 330, y: 250)))
        #expect(f.document.changeCount == changes + 3)
        // A press on a handle that does not move writes nothing.
        f.tool.mouseDown(TestEvents.point(330, 250))
        f.tool.mouseUp(TestEvents.point(331, 250))
        await f.document.settle()
        #expect(f.document.changeCount == changes + 3)
    }

    // MARK: Runs

    @Test func draggingARunHandleSlidesTheRun() async throws {
        let f = await Fixture.make()
        let connector = try await f.connector((0, .right), (2, .left))
        let before = try #require(ConnectorHandles.make(connector, in: f.document))
        #expect(before.runCount == 1 && before.baseOffsets == [0])
        #expect(before.handles == [.end(.start), .end(.end), .run(0)])
        let handle = before.position(.run(0))
        f.tool.mouseDown(TestEvents.point(handle.x, handle.y))
        guard case .moveRun(_, 0)? = f.tool.gesture else { Issue.record("a run drag"); return }
        f.tool.mouseDragged(TestEvents.point(handle.x + 10, handle.y + 30))
        #expect(f.tool.hover == nil, "a run drag attaches nothing")
        #expect(Self.close(f.tool.preview!.points[1], Point(x: before.route.points[1].x + 10, y: before.route.points[1].y)))
        f.tool.drawOverlay(in: Self.context(), viewport: Self.viewport)
        f.tool.mouseUp(TestEvents.point(handle.x + 10, handle.y + 30))
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Reshape Connector")
        let stored = f.stored(connector)
        #expect(stored.offsets == before.offsets(draggingRun: 0, by: Vector(dx: 10, dy: 30)))
        #expect(abs(abs(stored.offsets[0]) - 10) < 1e-9, "only the sideways part of the drag counts")
        let after = try #require(ConnectorHandles.make(connector, in: f.document))
        #expect(after.route.offsetsApplied && after.baseOffsets == stored.offsets)
        #expect(Self.close(after.position(.run(0)), Point(x: handle.x + 10, y: handle.y)))
        // A second drag starts from the stored offsets.
        f.tool.mouseDown(TestEvents.point(handle.x + 10, handle.y))
        f.tool.mouseUp(TestEvents.point(handle.x + 5, handle.y))
        await f.document.settle()
        #expect(abs(abs(f.stored(connector).offsets[0]) - 5) < 1e-9)
    }

    @Test func handleGeometry() {
        let points = [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 20), Point(x: 30, y: 20)]
        var route = ConnectorRouter.route(ConnectorSpec(id: NodeID(counter: 1, replica: 0), start: ConnectorEnd(point: .zero), end: ConnectorEnd(point: .zero))) { _ in nil }
        route.points = points
        route.runCount = 2
        route.offsetsApplied = true
        let handles = ConnectorHandles(node: .zero, route: route, storedOffsets: [1, 2])
        #expect(handles.baseOffsets == [1, 2])
        #expect(handles.normal(ofRun: 0) == Vector(0, 0), "a run of no length has no normal")
        #expect(handles.normal(ofRun: 1) == Vector(-1, 0), "right of a run going down is -x, y down")
        #expect(handles.offsets(draggingRun: 1, by: Vector(dx: -4, dy: 7)) == [1, 6])
        #expect(handles.position(.run(1)) == Point(x: 10, y: 10))
        #expect(handles.handle(at: Point(x: 11, y: 9), viewport: Self.viewport, radius: 5) == .run(1))
        #expect(handles.handle(at: Point(x: 100, y: 100), viewport: Self.viewport, radius: 5) == nil)
        var empty = route
        empty.points = []
        empty.runCount = 0
        empty.offsetsApplied = false
        let none = ConnectorHandles(node: .zero, route: empty, storedOffsets: [3])
        #expect(none.baseOffsets.isEmpty && none.position(.end(.start)) == .zero && none.position(.end(.end)) == .zero)
    }

    @Test func theToolEmitsExactlyOneCommandOnRelease() async throws {
        let f = await Fixture.make()
        let sink = RecordingSink()
        var context = ToolContext(document: f.document, host: f.host, selection: f.controller)
        context.commandSink = sink
        let tool = ConnectorTool()
        tool.activate(in: context)
        tool.mouseDown(TestEvents.point(58, 35))
        for step in 1...10 {
            tool.mouseDragged(TestEvents.point(58 + Double(step) * 14, 35))
            #expect(sink.commands.isEmpty, "nothing is written while dragging")
        }
        tool.mouseUp(TestEvents.point(202, 35))
        let command = try #require(sink.commands.first as? CreateConnector)
        #expect(sink.commands.count == 1 && command.label == "Connector")
        #expect(command.start == f.end(0, .right) && command.end == f.end(1, .left))
        for _ in 0..<20 { await Task.yield() }
        #expect(f.controller.selection.isEmpty, "nothing was created to select")
    }

    @Test func edgesOfEachSideAndWhatIsNotAConnector() async {
        let rect = Rect(x: 0, y: 0, width: 10, height: 20)
        let edges = ConnectorSide.allCases.map { ConnectorTarget(node: .zero, bounds: rect, side: $0).edge }
        #expect(edges.map(\.0) == [Point(x: 0, y: 0), Point(x: 0, y: 20), Point(x: 0, y: 0), Point(x: 10, y: 0)])
        #expect(edges.map(\.1) == [Point(x: 10, y: 0), Point(x: 10, y: 20), Point(x: 0, y: 20), Point(x: 10, y: 20)])
        #expect(ConnectorTarget.nearestSide(to: Point(x: 5, y: 9), of: Rect(x: 0, y: 0, width: 10, height: 10)) == .bottom)
        let f = await Fixture.make()
        #expect(ConnectorHandles.make(f.boxes[0].opID, in: f.document) == nil, "a box has no connector handles")
    }

    // MARK: Without a canvas

    @Test func anInactiveToolDoesNothing() {
        let tool = ConnectorTool()
        #expect(ConnectorTool.descriptor.make() is ConnectorTool)
        #expect(ConnectorTool.descriptor.helpSlug == "connectors")
        let e = TestEvents.point(10, 10)
        #expect(tool.target(at: e) == nil && tool.handles.isEmpty && tool.handle(at: .zero) == nil)
        #expect(tool.end(at: e) == ConnectorEnd(point: Point(x: 10, y: 10)))
        tool.pointerMoved(e)
        tool.mouseDown(e)
        tool.mouseDragged(e)
        tool.mouseUp(e)
        #expect(tool.gesture == nil && tool.preview == nil && tool.command(releasedAt: e) == nil)
        tool.drawOverlay(in: Self.context(), viewport: Self.viewport)
        tool.deactivate()
        #expect(tool.hover == nil && !tool.hoverHandle)
    }
}
