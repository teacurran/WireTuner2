import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Connectors, the WTModel half (DRAW-035/037, connectors.adoc): reading `ConnectorProps` into a
/// `ConnectorSpec` with the read normalizations, the commands, the scene's routing against the
/// objects' rendered bounds and the dependency index that reroutes a connector when an object it
/// joins changes.
@Suite struct ConnectorTests {
    /// Two 20 × 20 rectangles with no fill and a 2 pt stroke: `left` at (0, 0), `right` at
    /// (100, 0) (each by its transform).
    struct Boxes {
        var replica = Replica(7)
        let left: OpID
        let right: OpID
        let layer: OpID

        init(_ replica: UInt64 = 7) throws {
            self.replica = Replica(replica)
            left = try Self.box(&self.replica, x: 0, y: 0)
            right = try Self.box(&self.replica, x: 100, y: 0)
            layer = self.replica.state.liveChildren(WellKnown.layers)[0]
        }

        static func box(_ replica: inout Replica, x: Double, y: Double) throws -> OpID {
            var appearance = Wiretuner_Doc_V1_AppearanceProps()
            appearance.strokes = [Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 2)]
            return try replica.perform(CreateShape(.rectangle(.uniform(0)), size: Size(width: 20, height: 20),
                                                   transform: .translation(x: x, y: y), appearance: appearance))!.createdObjects[0]
        }

        /// A connector from `left`'s right side to `right`'s left side.
        mutating func connect(startSide: ConnectorSide? = .right, endSide: ConnectorSide? = .left) throws -> OpID {
            try replica.perform(CreateConnector(start: ConnectorEnd(node: NodeID(left), side: startSide, point: Point(x: 21, y: 10)),
                                                end: ConnectorEnd(node: NodeID(right), side: endSide, point: Point(x: 99, y: 10))))!.createdObjects[0]
        }

        var state: EngineState { replica.state }
    }

    static func points(_ item: DisplayItem?) -> [Point] {
        guard case .path(let path)? = item else { return [] }
        return path.path.elements.compactMap { element in
            switch element {
            case .move(let p), .line(let p): return p
            default: return nil
            }
        }
    }

    // MARK: Reading

    @Test func specReadsTheEndsSidesOffsetsAndStrokesOnly() throws {
        var boxes = try Boxes()
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        let node = try boxes.replica.perform(CreateConnector(start: ConnectorEnd(node: NodeID(boxes.left), side: .bottom, point: Point(x: 10, y: 21)),
                                                             end: ConnectorEnd(node: NodeID(boxes.right), point: Point(x: 99, y: 10)),
                                                             appearance: appearance))!.createdObjects[0]
        try boxes.replica.perform(SetConnectorRunOffsets(node, offsets: [4]))
        let spec = Connectors.spec(node, in: boxes.state, layers: LayerOrder(boxes.state))
        #expect(spec.id == NodeID(node))
        #expect(spec.start == ConnectorEnd(node: NodeID(boxes.left), side: .bottom, point: Point(x: 10, y: 21)))
        #expect(spec.end == ConnectorEnd(node: NodeID(boxes.right), side: nil, point: Point(x: 99, y: 10)))
        #expect(spec.routing == .orthogonal)
        #expect(spec.runOffsets == [4])
        // Only strokes are created and kept (the fill of the given stack is dropped).
        #expect(spec.appearance.items.count == 1)
        guard case .stroke = spec.appearance.items[0] else { Issue.record("stroke"); return }
        #expect(Connectors.props(node, in: boxes.state).appearance.fills.isEmpty)
        #expect(boxes.replica.sent.last?.label == "Reshape Connector")
    }

    @Test func sidesAndEndsRoundTripThroughTheStoredForm() {
        for side in [ConnectorSide.top, .bottom, .left, .right] {
            #expect(Connectors.side(Connectors.proto(side)) == side)
        }
        #expect(Connectors.proto(nil) == .unspecified)
        #expect(Connectors.side(.unspecified) == nil)
        #expect(Connectors.side(.UNRECOGNIZED(9)) == nil)
        let free = Connectors.proto(ConnectorEnd(node: nil, side: .top, point: Point(x: 1, y: 2)))
        #expect(!free.hasNode && free.side == .unspecified)
        #expect(Connectors.storedEnd(free).node == nil && Connectors.storedEnd(free).point == Point(x: 1, y: 2))
        let attached = Connectors.proto(ConnectorEnd(node: NodeID(counter: 5, replica: 3), side: .left, point: .zero))
        #expect(Connectors.storedEnd(attached).node == OpID(counter: 5, replica: 3))
        #expect(Connectors.storedEnd(attached).side == .left)
    }

    // MARK: Scene

    @Test func sceneRoutesBetweenTheObjectsRenderedBounds() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(boxes.state)
        let object = try #require(scene.object(node))
        #expect(object.kind == .connector && object.transform == .identity && object.path == nil)
        // The 2 pt strokes grow each box by 1 pt: the ends sit on (21, 10) and (99, 10).
        #expect(Self.points(object.item) == [Point(x: 21, y: 10), Point(x: 99, y: 10)])
        #expect(scene.topLevel.last == NodeID(node))
        #expect(builder.dependencies.directDependents(of: NodeID(boxes.left)).contains(NodeID(node)))
        #expect(builder.dependencies.directDependents(of: NodeID(boxes.right)).contains(NodeID(node)))
        #expect(builder.dependencies.directDependents(of: NodeID(boxes.layer)).contains(NodeID(node)))
        let route = try #require(Connectors.route(node, in: boxes.state, scene: scene))
        #expect(route.points == Self.points(object.item))
        #expect(Connectors.route(boxes.left, in: boxes.state, scene: scene) == nil)
        #expect(Connectors.attachmentPoint(of: boxes.right, side: .top, toward: .zero, in: scene) == Point(x: 110, y: -1))
        #expect(Connectors.attachmentPoint(of: boxes.right, side: nil, toward: Point(x: 110, y: 500), in: scene) == Point(x: 110, y: 21))
        #expect(Connectors.attachmentPoint(of: OpID(counter: 999, replica: 9), side: nil, toward: .zero, in: scene) == nil)
        // Its common.transform is ignored.
        var moved = Wiretuner_Doc_V1_NodeProps()
        moved.connector.common.transform = PathEditing.proto(AffineTransform.translation(x: 500, y: 500))
        let change = try boxes.replica.perform(OpsCommand("Move", ops: [Ops.set(node, [CommonFields.transform(.connector)], values: moved)]))!
        let (after, _) = builder.apply(change, state: boxes.state, origin: .local)
        #expect(Self.points(after.object(node)?.item) == Self.points(object.item))
    }

    @Test func movingAConnectedObjectReroutesTheConnectorLocallyAndRemotely() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let before = builder.rebuild(boxes.state)
        let change = try boxes.replica.perform(MoveObjects([boxes.right], by: Vector(dx: 0, dy: 50)))!
        let (scene, summary) = builder.apply(change, state: boxes.state, origin: .local)
        #expect(summary.touchedNodes.contains(NodeID(node)))
        #expect(summary.bounds[NodeID(node)]?.old?.rect == before.object(node)?.bounds)
        #expect(Self.points(scene.object(node)?.item).last == Point(x: 99, y: 60))
        // The same change arriving on another replica reroutes its connector with no op.
        var other = Replica(8)
        other.receive(boxes.replica.sent)
        var observer = DocumentDisplayListBuilder(canvas: "c")
        observer.rebuild(other.state)
        #expect(Self.points(observer.scene.object(node)?.item).last == Point(x: 99, y: 60))
        let back = try boxes.replica.perform(MoveObjects([boxes.right], by: Vector(dx: 0, dy: -50)))!
        other.receive([back])
        let (remote, remoteSummary) = observer.apply(back, state: other.state, origin: .remote)
        #expect(remoteSummary.origin == .remote && remoteSummary.touchedNodes.contains(NodeID(node)))
        #expect(Self.points(remote.object(node)?.item).last == Point(x: 99, y: 10))
        #expect(other.sent.isEmpty)
    }

    @Test func movingAGroupOrLayerHoldingTheObjectReroutesTheConnector() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        let group = try boxes.replica.perform(GroupObjects([boxes.right]))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(boxes.state)
        #expect(builder.dependencies.directDependents(of: NodeID(group)).contains(NodeID(node)))
        let move = try boxes.replica.perform(MoveObjects([group], by: Vector(dx: 0, dy: 30)))!
        var (scene, _) = builder.apply(move, state: boxes.state, origin: .local)
        #expect(Self.points(scene.object(node)?.item).last == Point(x: 99, y: 40))
        var layerMove = Wiretuner_Doc_V1_NodeProps()
        layerMove.layer.common.transform = PathEditing.proto(AffineTransform.translation(x: 0, y: 100))
        let layerChange = try boxes.replica.perform(OpsCommand("Move layer", ops: [Ops.set(boxes.layer, [LayerFields.transformPath], values: layerMove)]))!
        (scene, _) = builder.apply(layerChange, state: boxes.state, origin: .local)
        // The layer moves the boxes, not the connector's own geometry: both ends follow.
        #expect(Self.points(scene.object(node)?.item).first == Point(x: 21, y: 110))
        #expect(Self.points(scene.object(node)?.item).last == Point(x: 99, y: 140))
    }

    @Test func aConnectorInsideTheGroupItJoinsIsLeftOutOfThatGroupsBounds() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        let group = try boxes.replica.perform(GroupObjects([boxes.left, boxes.right, node]))!.createdObjects[0]
        let inner = try boxes.replica.perform(CreateConnector(start: ConnectorEnd(node: NodeID(group), side: .top, point: .zero),
                                                              end: ConnectorEnd(point: Point(x: 60, y: -80))))!.createdObjects[0]
        try boxes.replica.perform(OpsCommand("Into group", ops: [Ops.move(inner, parent: group, position: [0xF0])]))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(boxes.state)
        // The group's own geometric bounds (the boxes) decide where `inner` leaves it.
        #expect(Self.points(scene.object(inner)?.item).first == Point(x: 60, y: 0))
        #expect(Self.points(scene.object(node)?.item) == [Point(x: 21, y: 10), Point(x: 99, y: 10)])
        #expect(scene.object(inner)?.parent == group)
        #expect(Objects.bounds(of: inner, in: boxes.state) != nil)
        #expect(Objects.bounds(of: group, in: boxes.state) != nil)
    }

    @Test func endsNamingWhatCannotBeAttachedToReadAsFreeAtTheirPoint() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        // A connector, an unknown id, a node on the Guides layer, a layer, and an empty group
        // (attachable, but with no bounds) all read as free.
        var guides = Wiretuner_Doc_V1_NodeProps()
        guides.layer.role = .guides
        guides.layer.visible = true
        let guidesLayer = try boxes.replica.perform(OpsCommand("Guides", ops: [Ops.create(parent: WellKnown.layers, position: [0xF0], props: guides)]))!.createdNodes[0]
        let guide = try Boxes.box(&boxes.replica, x: 300, y: 300)
        try boxes.replica.perform(OpsCommand("To guides", ops: [Ops.move(guide, parent: guidesLayer, position: [0x80])]))
        var groupProps = Wiretuner_Doc_V1_NodeProps()
        groupProps.group = Wiretuner_Doc_V1_GroupProps()
        let empty = try boxes.replica.perform(OpsCommand("Group", ops: [Ops.create(parent: boxes.layer, position: [0xF8], props: groupProps)]))!.createdNodes[0]
        let order = LayerOrder(boxes.state)
        #expect(Connectors.isAttachable(boxes.left, in: boxes.state, layers: order))
        #expect(!Connectors.isAttachable(node, in: boxes.state, layers: order))
        #expect(!Connectors.isAttachable(OpID(counter: 999, replica: 9), in: boxes.state, layers: order))
        #expect(!Connectors.isAttachable(guide, in: boxes.state, layers: order))
        #expect(!Connectors.isAttachable(boxes.layer, in: boxes.state, layers: order))
        #expect(Connectors.isAttachable(empty, in: boxes.state, layers: order))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(boxes.state)
        for target in [node, OpID(counter: 999, replica: 9), guide, boxes.layer, empty] {
            var props = Wiretuner_Doc_V1_NodeProps()
            var end = Connectors.proto(ConnectorEnd(node: NodeID(target), side: .top, point: Point(x: 200, y: 200)))
            end.side = .top
            props.connector.end = end
            let change = try boxes.replica.perform(OpsCommand("Attach", ops: [Ops.set(node, [ConnectorFields.end], values: props)]))!
            let (scene, _) = builder.apply(change, state: boxes.state, origin: .remote)
            #expect(Self.points(scene.object(node)?.item).last == Point(x: 200, y: 200), "target \(target)")
            if target != empty {
                #expect(Connectors.spec(node, in: boxes.state, layers: LayerOrder(boxes.state)).end.node == nil)
            }
        }
    }

    @Test func deletingAConnectedObjectFreesTheEndAndRestoringReconnects() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        let group = try boxes.replica.perform(GroupObjects([boxes.right]))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(boxes.state)
        // Move the box first so the stored point (99, 10) differs from where it is attached.
        let move = try boxes.replica.perform(MoveObjects([boxes.right], by: Vector(dx: 0, dy: 40)))!
        _ = builder.apply(move, state: boxes.state, origin: .local)
        let delete = try boxes.replica.perform(DeleteNodes([boxes.right]))!
        var (scene, summary) = builder.apply(delete, state: boxes.state, origin: .local)
        #expect(summary.touchedNodes.contains(NodeID(node)))
        #expect(Self.points(scene.object(node)?.item).last == Point(x: 99, y: 10))
        // The reference is kept, so undo (a restore) reconnects it.
        let undone = boxes.replica.undo()
        let restore = try #require(undone)
        (scene, _) = builder.apply(restore, state: boxes.state, origin: .local)
        #expect(Self.points(scene.object(node)?.item).last == Point(x: 99, y: 50))
        // Deleting an enclosing group frees it too.
        let deleteGroup = try boxes.replica.perform(DeleteNodes([group]))!
        (scene, _) = builder.apply(deleteGroup, state: boxes.state, origin: .remote)
        #expect(Self.points(scene.object(node)?.item).last == Point(x: 99, y: 10))
        // Deleting both objects leaves a plain line between the two points.
        let deleteLeft = try boxes.replica.perform(DeleteNodes([boxes.left]))!
        (scene, _) = builder.apply(deleteLeft, state: boxes.state, origin: .local)
        #expect(Self.points(scene.object(node)?.item).first == Point(x: 21, y: 10))
        #expect(Self.points(scene.object(node)?.item).last == Point(x: 99, y: 10))
    }

    // MARK: Commands

    @Test func createConnectorWritesOneChangeOnTheLayer() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        let change = try #require(boxes.replica.sent.last)
        #expect(change.label == "Connector")
        #expect(boxes.state.nodeKind(node) == .connector)
        #expect(Objects.parent(of: node, in: boxes.state) == boxes.layer)
        let props = Connectors.props(node, in: boxes.state)
        #expect(OpID(props.start.node.id) == boxes.left && props.start.side == .right && props.start.point.x == 21)
        #expect(OpID(props.end.node.id) == boxes.right && props.end.side == .left)
        #expect(props.appearance.strokes.count == 1 && props.runOffsets.isEmpty)
        // Onto another layer when asked; with no layer yet, one is made.
        var fresh = Replica(3)
        let free = try fresh.perform(CreateConnector(start: ConnectorEnd(point: .zero), end: ConnectorEnd(point: Point(x: 50, y: 50))))!.createdObjects[0]
        #expect(fresh.state.nodeKind(free) == .connector)
        #expect(Objects.parent(of: free, in: fresh.state).flatMap { fresh.state.nodeKind($0) } == .layer)
    }

    @Test func createConnectorRefusesBadEnds() throws {
        var boxes = try Boxes()
        #expect(throws: ObjectEditError.invalidValue("point")) {
            try boxes.replica.perform(CreateConnector(start: ConnectorEnd(point: Point(x: .nan, y: 0)), end: ConnectorEnd(point: .zero)))
        }
        #expect(throws: ObjectEditError.notAnObject(boxes.layer)) {
            try boxes.replica.perform(CreateConnector(start: ConnectorEnd(node: NodeID(boxes.layer), point: .zero), end: ConnectorEnd(point: .zero)))
        }
    }

    @Test func anEndDragWritesTheWholeEnd() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        let third = try Boxes.box(&boxes.replica, x: 50, y: 100)
        let change = try boxes.replica.perform(SetConnectorEnd(node, .end, to: ConnectorEnd(node: NodeID(third), side: .top, point: Point(x: 60, y: 99))))!
        #expect(change.label == "Move Connector End")
        #expect(change.ops.count == 1 && change.ops[0].set.paths.map { RegisterPath($0) } == [ConnectorFields.end])
        var end = Connectors.storedEnd(Connectors.props(node, in: boxes.state).end)
        #expect(end.node == third && end.side == .top && end.point == Point(x: 60, y: 99))
        // Freeing the end writes the point and clears the node and side.
        try boxes.replica.perform(SetConnectorEnd(node, .start, to: ConnectorEnd(point: Point(x: -40, y: -40))))
        end = Connectors.storedEnd(Connectors.props(node, in: boxes.state).start)
        #expect(end.node == nil && end.side == nil && end.point == Point(x: -40, y: -40))
        #expect(ConnectorFields.path(.start) == ConnectorFields.start && ConnectorFields.path(.end) == ConnectorFields.end)
        #expect(throws: ObjectEditError.notAnObject(boxes.left)) {
            try boxes.replica.perform(SetConnectorEnd(boxes.left, .start, to: ConnectorEnd(point: .zero)))
        }
        #expect(throws: ObjectEditError.invalidValue("point")) {
            try boxes.replica.perform(SetConnectorEnd(node, .start, to: ConnectorEnd(point: Point(x: .infinity, y: 0))))
        }
    }

    @Test func runOffsetsAreValidated() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        #expect(throws: ObjectEditError.invalidValue("run_offsets")) {
            try boxes.replica.perform(SetConnectorRunOffsets(node, offsets: Array(repeating: 1, count: 65)))
        }
        #expect(throws: ObjectEditError.invalidValue("run_offsets")) {
            try boxes.replica.perform(SetConnectorRunOffsets(node, offsets: [.nan]))
        }
        #expect(throws: ObjectEditError.notAnObject(boxes.left)) {
            try boxes.replica.perform(SetConnectorRunOffsets(boxes.left, offsets: []))
        }
        try boxes.replica.perform(SetConnectorRunOffsets(node, offsets: Array(repeating: 1, count: 64)))
        #expect(Connectors.props(node, in: boxes.state).runOffsets.count == 64)
    }

    @Test func runOffsetsSlideTheRouteAndMismatchesReadAsAutomatic() throws {
        var boxes = try Boxes()
        // Right side to the top of a box below and to the right: two stubs, three runs between.
        let low = try Boxes.box(&boxes.replica, x: 100, y: 100)
        let node = try boxes.replica.perform(CreateConnector(start: ConnectorEnd(node: NodeID(boxes.left), side: .right, point: .zero),
                                                             end: ConnectorEnd(node: NodeID(low), side: .left, point: .zero)))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let automatic = Self.points(builder.rebuild(boxes.state).object(node)?.item)
        let route = try #require(Connectors.route(node, in: boxes.state, scene: builder.scene))
        #expect(route.runCount == 1)
        let change = try boxes.replica.perform(SetConnectorRunOffsets(node, offsets: [10]))!
        let reshaped = Self.points(builder.apply(change, state: boxes.state, origin: .local).0.object(node)?.item)
        #expect(reshaped != automatic)
        let mismatch = try boxes.replica.perform(SetConnectorRunOffsets(node, offsets: [10, 10]))!
        #expect(Self.points(builder.apply(mismatch, state: boxes.state, origin: .local).0.object(node)?.item) == automatic)
    }

    @Test func reverseDirectionSwapsTheEndsAndKeepsTheReshapedLine() throws {
        var boxes = try Boxes()
        let low = try Boxes.box(&boxes.replica, x: 100, y: 100)
        let node = try boxes.replica.perform(CreateConnector(start: ConnectorEnd(node: NodeID(boxes.left), side: .right, point: Point(x: 21, y: 10)),
                                                             end: ConnectorEnd(node: NodeID(low), side: .left, point: Point(x: 99, y: 110))))!.createdObjects[0]
        try boxes.replica.perform(SetConnectorRunOffsets(node, offsets: [12]))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let forward = Self.points(builder.rebuild(boxes.state).object(node)?.item)
        let before = Connectors.props(node, in: boxes.state)
        let change = try #require(try boxes.replica.perform(ReverseConnectors([node, boxes.left])))
        #expect(change.label == "Reverse Direction" && change.ops.count == 1)
        #expect(change.ops[0].set.paths.map { RegisterPath($0) } == [ConnectorFields.start, ConnectorFields.end, ConnectorFields.runOffsets])
        let after = Connectors.props(node, in: boxes.state)
        #expect(after.start == before.end && after.end == before.start)
        #expect(after.runOffsets == [-12])
        let reversed = Self.points(builder.apply(change, state: boxes.state, origin: .local).0.object(node)?.item)
        #expect(reversed == Array(forward.reversed()))
        // Without offsets, only the ends are written; a zero offset stays zero.
        let plain = try boxes.connect()
        let swap = try #require(try boxes.replica.perform(ReverseConnectors([plain])))
        #expect(swap.ops[0].set.paths.count == 2)
        try boxes.replica.perform(SetConnectorRunOffsets(plain, offsets: [0, 3]))
        try boxes.replica.perform(ReverseConnectors([plain]))
        #expect(Connectors.props(plain, in: boxes.state).runOffsets == [-3, 0])
    }

    @Test func connectorsFollowTheirObjectsInsteadOfMoving() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        #expect(try boxes.replica.perform(MoveObjects([node], by: Vector(dx: 5, dy: 5))) == nil)
        #expect(try boxes.replica.perform(TransformObjects([node], matrix: .translation(x: 5, y: 5), about: nil, kind: .move)) == nil)
        // Deleted, styled and grouped like any object.
        #expect(Objects.isObject(node, in: boxes.state))
        let bounds = try #require(Objects.bounds(of: node, in: boxes.state))
        #expect(bounds == Rect(x: 20, y: 10, width: 80, height: 0))
        try boxes.replica.perform(DeleteNodes([node]))
        #expect(!boxes.state.isLive(node))
    }

    // MARK: Copying

    @Test func pasteReattachesEndsCopiedWithItAndFreesTheOthersAtTheirPoints() throws {
        var boxes = try Boxes()
        let node = try boxes.connect()
        // Copy the connector with its left box only.
        let payload = ClipboardPayload(copying: [boxes.left, node], from: boxes.state)
        #expect(payload.nodes.map(\.kind) == [.rect, .connector])
        let decoded = try #require(ClipboardPayload(decoding: payload.encoded()))
        let bounds = try #require(payload.bounds)
        let change = try #require(try boxes.replica.perform(Paste(decoded, placement: .top(layer: nil, center: bounds.center + Vector(dx: 0, dy: 200)))))
        let copies = change.createdRoots
        #expect(copies.count == 2)
        let props = Connectors.props(copies[1], in: boxes.state)
        let start = Connectors.storedEnd(props.start)
        let end = Connectors.storedEnd(props.end)
        #expect(start.node == copies[0] && start.side == .right && start.point == Point(x: 21, y: 210))
        #expect(end.node == nil && end.side == nil && end.point == Point(x: 99, y: 210))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(boxes.state)
        #expect(Self.points(scene.object(copies[1])?.item) == [Point(x: 21, y: 210), Point(x: 99, y: 210)])
        // Duplicate: the connector alone is copied free at its points, moved by the offset.
        let duplicate = try #require(try boxes.replica.perform(DuplicateObjects.duplicate([node])))
        let copy = Connectors.props(duplicate.createdRoots[0], in: boxes.state)
        #expect(!copy.start.hasNode && !copy.end.hasNode)
        #expect(Connectors.storedEnd(copy.start).point == Point(x: 31, y: 20))
    }

    @Test func nodeTreesNameTheNewKindsAndLeaveAConnectorsTransformAlone() throws {
        var connector = NodeTree(props: { var p = Wiretuner_Doc_V1_NodeProps(); p.connector.start.point.x = 1; return p }())
        #expect(connector.kind == .connector)
        connector.transform = .translation(x: 10, y: 0)
        #expect(connector.transform == .identity && !connector.props.connector.common.hasTransform)
        connector.transformConnectors(by: .translation(x: 10, y: 0))
        #expect(connector.props.connector.start.point.x == 11)
        var placed = NodeTree(props: { var p = Wiretuner_Doc_V1_NodeProps(); p.placedFile.content.sourceName = "a.eps"; return p }())
        #expect(placed.kind == .placedFile)
        placed.transform = .translation(x: 10, y: 0)
        #expect(placed.transform == .translation(x: 10, y: 0))
        var group = NodeTree(props: { var p = Wiretuner_Doc_V1_NodeProps(); p.group = .init(); return p }(), children: [connector])
        group.transformConnectors(by: .translation(x: 0, y: 5))
        #expect(group.children[0].props.connector.start.point.y == 5)
        #expect(NodeValues.appearanceField(.connector) == 4 && NodeValues.appearanceField(.placedFile) == nil)
        #expect(NodeValues.common(kind: .placedFile) { $0.name = "p" }.placedFile.common.name == "p")
        #expect(NodeValues.common(kind: .connector) { $0.name = "c" }.connector.common.name == "c")
        #expect(NodeValues.with(kind: .connector, appearanceField: 4, Appearances.standard).connector.appearance.strokes.count == 1)
        #expect(NodeValues.with(kind: .placedFile, appearanceField: 0, Appearances.standard) == Wiretuner_Doc_V1_NodeProps())
        #expect(NodeValues.replacing(Appearances.standard, of: .connector, in: Wiretuner_Doc_V1_NodeProps()).connector.appearance.strokes.count == 1)
        #expect(NodeValues.replacing(Appearances.standard, of: .placedFile, in: Wiretuner_Doc_V1_NodeProps()) == Wiretuner_Doc_V1_NodeProps())
    }
}

extension LayerFields {
    static let transformPath = RegisterPath([kind, 1, 4])
}
