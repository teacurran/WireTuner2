import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-036 beyond the tool: Reverse Direction, the Object panel's connector section, the Pointer
/// and the arrow keys leaving connectors alone, the tool's installation, and connectors between
/// two replicas (a remote move reroutes with no op from the observer; both ends re-attached
/// concurrently hold).
@Suite @MainActor struct ConnectorCommandTests {
    typealias Fixture = ConnectorToolTests.Fixture

    static func editing(_ f: Fixture) -> ObjectEditing {
        ObjectEditing(document: f.document, selection: f.controller, pasteboard: ObjectEditingTests.pasteboard())
    }

    // MARK: Reverse Direction

    @Test func reverseDirectionSwapsTheSelectedConnectorsEnds() async throws {
        let f = await Fixture.make()
        let connector = try await f.connector((0, .right), (2, .left))
        _ = await f.document.perform(SetConnectorRunOffsets(connector, offsets: [-10])).value
        await f.document.settle()
        let handles = try #require(ConnectorHandles.make(connector, in: f.document))
        #expect(handles.route.offsetsApplied)
        let before = f.stored(connector)
        let box = EditingBox(nil)
        let command = ConnectorCommands.reverseDirection { box.value }
        #expect(command.id == ContextMenuCatalog.ID.reverseDirection && command.menuPath == MenuPath("Modify", "Alter Path", section: 3))
        #expect(command.validation() == .disabled("No document is open"))
        guard case let .perform(action) = command.action else { Issue.record("an action"); return }
        action()
        box.value = Self.editing(f)
        f.controller.model.set(Selection([f.boxes[0]]))
        #expect(command.validation() == .disabled(ConnectorCommands.noConnector))
        action()
        await f.document.settle()
        #expect(f.stored(connector).start.node == before.start.node, "nothing but connectors reverses")
        f.controller.model.set(Selection([f.boxes[0], SelectionID(connector)]))
        #expect(command.validation().isEnabled)
        #expect(ConnectorCommands.selectedConnectors(box.value!) == [connector])
        action()
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Reverse Direction")
        let after = f.stored(connector)
        #expect(after.start.node == before.end.node && after.start.side == before.end.side && after.end.node == before.start.node)
        #expect(after.offsets == [10], "reversed and negated, the line keeps its shape")
        let reversed = try #require(ConnectorHandles.make(connector, in: f.document))
        #expect(reversed.route.offsetsApplied && reversed.route.points.count == handles.route.points.count)
        for (p, q) in zip(reversed.route.points, handles.route.points.reversed()) {
            #expect(ConnectorToolTests.close(p, q), "the same line drawn the other way")
        }
    }

    @Test func installingDeliversTheToolAndTheCommand() {
        let commands = CommandRegistry()
        let tools = ToolRegistry()
        tools.registerBuiltIn()
        for placeholder in ContextMenuCatalog.placeholders() { commands.registerIfAbsent(placeholder) }
        #expect(!(commands.validate(ContextMenuCatalog.ID.reverseDirection)?.isEnabled ?? true))
        ConnectorCommands.install(commands: commands, tools: tools) { nil }
        #expect(tools.makeTool(ConnectorTool.id) is ConnectorTool)
        #expect(tools.descriptor(for: ConnectorTool.id)?.title == "Connector")
        #expect(commands.validate(ContextMenuCatalog.ID.reverseDirection) == .disabled("No document is open"))
    }

    // MARK: Pointer and arrows

    @Test func thePointerAndTheArrowKeysCannotMoveAConnector() async throws {
        let f = await Fixture.make()
        let connector = try await f.connector((0, .right), (2, .left))
        let pointer = PointerTool()
        let host = RecordingHost(viewport: ConnectorToolTests.viewport)
        pointer.activate(in: ToolContext(document: f.document, host: host, selection: f.controller))
        let changes = f.document.changeCount
        let run = try #require(ConnectorHandles.make(connector, in: f.document)).position(.run(0))
        pointer.mouseDown(TestEvents.point(run.x, run.y))
        #expect(pointer.gesture == .move && f.controller.selection.ids == [SelectionID(connector)])
        pointer.mouseDragged(TestEvents.point(run.x + 30, run.y))
        #expect(pointer.movePreview.isEmpty && pointer.moveCommand(Vector(dx: 30, dy: 0), copy: false) == nil)
        #expect(pointer.moveCommand(Vector(dx: 30, dy: 0), copy: true) == nil, "nor copies it")
        pointer.mouseUp(TestEvents.point(run.x + 30, run.y, .option))
        await f.document.settle()
        #expect(f.document.changeCount == changes)
        #expect(ObjectEditing.moveCommand(Vector(dx: 1, dy: 0), selection: f.controller.selection, document: f.document) == nil)
        // With a box selected too, only the box moves and the connector follows it.
        f.controller.model.set(Selection([f.boxes[0], SelectionID(connector)]))
        let move = try #require(ObjectEditing.moveCommand(Vector(dx: 5, dy: 0), selection: f.controller.selection, document: f.document) as? MoveObjects)
        #expect(move.nodes == [f.boxes[0].opID])
        let pointerMove = try #require(pointer.moveCommand(Vector(dx: 5, dy: 0), copy: false) as? MoveObjects)
        #expect(pointerMove.nodes == [f.boxes[0].opID])
        _ = await f.document.perform(move).value
        await f.document.settle()
        #expect(ConnectorHandles.make(connector, in: f.document)?.position(.end(.start)) == Point(x: 65.5, y: 35))
    }

    // MARK: Object panel

    @Test func theObjectPanelShowsTheEndsAndPicksASide() async throws {
        let f = await Fixture.make()
        let connector = try await f.connector((0, .right), (2, .left))
        func model() -> ObjectPanelModel { ObjectPanelModel(document: f.document, selection: f.controller.selection) }
        let section = try #require(model().connector)
        #expect(section.node == connector)
        #expect(section.start.object == "Rectangle" && section.start.side == .right && section.start.node == f.boxes[0].opID)
        #expect(section.end.object == "Rectangle" && section.end.side == .left)
        #expect(ObjectPanelModel(document: f.document, selection: Selection([f.boxes[0]])).connector == nil)
        #expect(ObjectPanelModel(document: f.document, selection: Selection([f.boxes[0], SelectionID(connector)])).connector == nil)
        #expect(ObjectPanelModel(document: f.document, selection: .empty).setConnectorSide(.start, .top) == nil)
        _ = await model().perform(model().setConnectorSide(.start, .top))?.value
        await f.document.settle()
        #expect(f.stored(connector).start.side == .top && ConnectorToolTests.close(f.stored(connector).start.point, Point(x: 35, y: 9.5)))
        #expect(f.document.undoTitle == "Undo Move Connector End")
        _ = await model().perform(model().setConnectorSide(.end, nil))?.value
        await f.document.settle()
        #expect(model().connector?.end.side == nil && f.stored(connector).end.node == f.boxes[2].opID, "Automatic keeps the object")
        // A free end shows "Free" and has no side to pick.
        _ = await f.document.perform(SetConnectorEnd(connector, .end, to: ConnectorEnd(point: Point(x: 330, y: 250)))).value
        await f.document.settle()
        #expect(model().connector?.end == .init(which: .end, node: nil, object: nil, side: nil, point: Point(x: 330, y: 250)))
        #expect(model().setConnectorSide(.end, .top) == nil)
        // The view: both states render, and the pop-up writes through the model.
        let free = try #require(model().connector)
        let view = NSHostingView(rootView: ConnectorSectionView(section: free, model: model()))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
        #expect(ConnectorSectionView.sides.map(\.title) == ["Automatic", "Top", "Bottom", "Left", "Right"])
        #expect(ConnectorSectionView.title(nil) == "Automatic" && ConnectorSectionView.title(.bottom) == "Bottom")
        #expect(ConnectorSectionView.label(.start) == "Start" && ConnectorSectionView.label(.end) == "End")
        let binding = ConnectorSectionView.side(free.start, model())
        #expect(binding.wrappedValue == "Top")
        binding.wrappedValue = "Bottom"
        await f.document.settle()
        #expect(f.stored(connector).start.side == .bottom)
        let active = ActiveSelection(model: f.controller.model, document: f.document)
        let body = NSHostingView(rootView: ObjectPanelBody(selection: active))
        body.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        body.layoutSubtreeIfNeeded()
        #expect(body.fittingSize.width > 0)
    }

    @Test func connectorsAreNamedByTheirKind() async throws {
        let f = await Fixture.make()
        let connector = try await f.connector((0, .right), (1, .left))
        #expect(ObjectNaming.name(of: connector, in: f.document.state) == "Connector")
    }

    // MARK: Two replicas

    /// Sends `change` from `from` to `to`, as the server's log would.
    static func relay(_ change: Wiretuner_Doc_V1_Change?, to document: DocumentHandle) async throws {
        _ = await document.receive(try #require(change)).value
        await document.settle()
    }

    @Test func aRemoteMoveReroutesTheConnectorWithNoOpFromTheObserver() async throws {
        let f = await Fixture.make([])
        let observer = DocumentHandle.memory(title: "Observer")
        try await f.add([ConnectorToolTests.a, ConnectorToolTests.b]) { try await Self.relay($0, to: observer) }
        let create = await f.document.perform(CreateConnector(start: f.end(0, .right), end: f.end(1, .left))).value
        try await Self.relay(create, to: observer)
        let connector = try #require(create?.createdObjects.first)
        let model = try #require(await observer.openedModel())
        var local = 0
        let token = model.observe { event in if event.origin != .remote { local += 1 } }
        defer { model.stopObserving(token) }
        let before = try #require(ConnectorHandles.make(connector, in: observer)).position(.end(.start))
        let move = await f.document.perform(MoveObjects([f.boxes[0].opID], by: Vector(dx: 0, dy: 20))).value
        try await Self.relay(move, to: observer)
        let after = try #require(ConnectorHandles.make(connector, in: observer)).position(.end(.start))
        #expect(ConnectorToolTests.close(after, Point(x: before.x, y: before.y + 20)), "the connector follows the box on the observer's screen")
        #expect(local == 0 && !observer.canUndo, "the observer's outbox stays empty")
    }

    @Test func bothEndsReattachedConcurrentlyHold() async throws {
        let f = await Fixture.make([])
        let other = DocumentHandle.memory(title: "Other")
        try await f.add([ConnectorToolTests.a, ConnectorToolTests.b, ConnectorToolTests.c]) { try await Self.relay($0, to: other) }
        let create = await f.document.perform(CreateConnector(start: f.end(0, .right), end: f.end(1, .left))).value
        try await Self.relay(create, to: other)
        let connector = try #require(create?.createdObjects.first)
        let mine = await f.document.perform(SetConnectorEnd(connector, .start, to: f.end(2, .top))).value
        let theirs = await other.perform(SetConnectorEnd(connector, .end, to: f.end(2, .bottom))).value
        try await Self.relay(theirs, to: f.document)
        try await Self.relay(mine, to: other)
        for document in [f.document, other] {
            let props = Connectors.props(connector, in: document.state)
            #expect(Connectors.storedEnd(props.start).node == f.boxes[2].opID && Connectors.storedEnd(props.start).side == .top)
            #expect(Connectors.storedEnd(props.end).node == f.boxes[2].opID && Connectors.storedEnd(props.end).side == .bottom)
        }
    }
}
