import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The merge semantics of connectors.adoc through two in-process replicas (DRAW-035/036): each
/// case converges, and each replica's scene draws the same route.
@Suite struct ConnectorMergeTests {
    /// Two replicas sharing three boxes and a connector from `a` to `b`, created on A.
    struct Shared {
        var pair = Pair()
        let a: OpID
        let b: OpID
        let c: OpID
        let connector: OpID

        init() throws {
            a = try ConnectorTests.Boxes.box(&pair.a, x: 0, y: 0)
            b = try ConnectorTests.Boxes.box(&pair.a, x: 100, y: 0)
            c = try ConnectorTests.Boxes.box(&pair.a, x: 50, y: 100)
            connector = try pair.a.perform(CreateConnector(start: ConnectorEnd(node: NodeID(a), side: .right, point: Point(x: 21, y: 10)),
                                                           end: ConnectorEnd(node: NodeID(b), side: .left, point: Point(x: 99, y: 10))))!.createdObjects[0]
            pair.sync()
        }

        /// Both replicas hold the same state and draw the same connector; returns its props.
        func merged() -> Wiretuner_Doc_V1_ConnectorProps {
            #expect(pair.a.state.stateHash == pair.b.state.stateHash)
            var left = DocumentDisplayListBuilder(canvas: "c")
            var right = DocumentDisplayListBuilder(canvas: "c")
            #expect(left.rebuild(pair.a.state).object(connector)?.item == right.rebuild(pair.b.state).object(connector)?.item)
            return Connectors.props(connector, in: pair.a.state)
        }

        /// Whether A's change `a` beats B's change `b` on a register both wrote first.
        static func aWins(_ a: Wiretuner_Doc_V1_Change, _ b: Wiretuner_Doc_V1_Change) -> Bool {
            OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica)
        }
    }

    @Test func reattachingTheTwoEndsConcurrentlyKeepsBoth() throws {
        var s = try Shared()
        try s.pair.a.perform(SetConnectorEnd(s.connector, .start, to: ConnectorEnd(node: NodeID(s.c), side: .top, point: Point(x: 60, y: 99))))
        try s.pair.b.perform(SetConnectorEnd(s.connector, .end, to: ConnectorEnd(node: NodeID(s.c), side: .bottom, point: Point(x: 60, y: 121))))
        s.pair.sync()
        let props = s.merged()
        #expect(Connectors.storedEnd(props.start).node == s.c && Connectors.storedEnd(props.start).side == .top)
        #expect(Connectors.storedEnd(props.end).node == s.c && Connectors.storedEnd(props.end).side == .bottom)
    }

    @Test func reattachingOneEndConcurrentlyTakesAllThreeFieldsFromOneWriter() throws {
        var s = try Shared()
        let a = try s.pair.a.perform(SetConnectorEnd(s.connector, .end, to: ConnectorEnd(node: NodeID(s.c), side: .top, point: Point(x: 60, y: 99))))!
        let b = try s.pair.b.perform(SetConnectorEnd(s.connector, .end, to: ConnectorEnd(node: NodeID(s.a), side: .bottom, point: Point(x: 10, y: 21))))!
        s.pair.sync()
        let end = Connectors.storedEnd(s.merged().end)
        if Shared.aWins(a, b) {
            #expect(end.node == s.c && end.side == .top && end.point == Point(x: 60, y: 99))
        } else {
            #expect(end.node == s.a && end.side == .bottom && end.point == Point(x: 10, y: 21))
        }
    }

    @Test func deleteVersusAttachLeavesAFreeEndThatRestoringReconnects() throws {
        var s = try Shared()
        try s.pair.a.perform(DeleteNodes([s.c]))
        try s.pair.b.perform(SetConnectorEnd(s.connector, .end, to: ConnectorEnd(node: NodeID(s.c), side: .top, point: Point(x: 60, y: 99))))
        s.pair.sync()
        // The attach applied and the reference dangles: a free end at the point.
        #expect(Connectors.storedEnd(s.merged().end).node == s.c)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        #expect(ConnectorTests.points(builder.rebuild(s.pair.b.state).object(s.connector)?.item).last == Point(x: 60, y: 99))
        // A restores it; B's observer reconnects the connector with no op of its own.
        let restore = try s.pair.a.perform(OpsCommand("Restore", ops: [Ops.setDeleted(s.c, false)]))!
        let sentBefore = s.pair.b.sent.count
        s.pair.sync()
        let (scene, summary) = builder.apply(restore, state: s.pair.b.state, origin: .remote)
        #expect(summary.touchedNodes.contains(NodeID(s.connector)))
        #expect(ConnectorTests.points(scene.object(s.connector)?.item).last == Point(x: 60, y: 99))
        #expect(scene.object(s.connector)?.item != nil)
        #expect(Connectors.spec(s.connector, in: s.pair.b.state, layers: LayerOrder(s.pair.b.state)).end.node == NodeID(s.c))
        #expect(s.pair.b.sent.count == sentBefore)
        _ = s.merged()
    }

    @Test func attachVersusDetachConverges() throws {
        var s = try Shared()
        let a = try s.pair.a.perform(SetConnectorEnd(s.connector, .end, to: ConnectorEnd(node: NodeID(s.c), side: .left, point: Point(x: 49, y: 110))))!
        let b = try s.pair.b.perform(SetConnectorEnd(s.connector, .end, to: ConnectorEnd(point: Point(x: 300, y: 300))))!
        s.pair.sync()
        let end = Connectors.storedEnd(s.merged().end)
        #expect(end.node == (Shared.aWins(a, b) ? s.c : nil))
    }

    @Test func concurrentReshapesKeepOneWholeList() throws {
        var s = try Shared()
        let a = try s.pair.a.perform(SetConnectorRunOffsets(s.connector, offsets: [5, 6]))!
        let b = try s.pair.b.perform(SetConnectorRunOffsets(s.connector, offsets: [-1]))!
        s.pair.sync()
        #expect(s.merged().runOffsets == (Shared.aWins(a, b) ? [5, 6] : [-1]))
    }

    @Test func reverseVersusReattachConverges() throws {
        var s = try Shared()
        try s.pair.a.perform(ReverseConnectors([s.connector]))
        try s.pair.b.perform(SetConnectorEnd(s.connector, .end, to: ConnectorEnd(node: NodeID(s.c), side: .top, point: Point(x: 60, y: 99))))
        s.pair.sync()
        let props = s.merged()
        let nodes = [Connectors.storedEnd(props.start).node, Connectors.storedEnd(props.end).node]
        // The swap and the re-attach both wrote `end`: one of them holds it; `start` is A's.
        #expect(nodes[0] == s.b)
        #expect(nodes[1] == s.a || nodes[1] == s.c)
    }

    @Test func aRemoteMoveOfAConnectedBoxReroutesWithoutAnOp() throws {
        var s = try Shared()
        var observer = DocumentDisplayListBuilder(canvas: "c")
        observer.rebuild(s.pair.b.state)
        let move = try s.pair.a.perform(MoveObjects([s.b], by: Vector(dx: 0, dy: 70)))!
        s.pair.sync()
        let (scene, summary) = observer.apply(move, state: s.pair.b.state, origin: .remote)
        #expect(summary.touchedNodes == [NodeID(s.b), NodeID(s.connector)])
        #expect(ConnectorTests.points(scene.object(s.connector)?.item).last == Point(x: 99, y: 80))
        #expect(s.pair.b.sent.isEmpty)
    }
}
