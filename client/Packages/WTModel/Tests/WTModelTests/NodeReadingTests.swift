import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

@Suite struct NodeReadingTests {
    @Test func idsConvertBothWays() {
        let id = OpID(counter: 12, replica: 0xFFFF_FFFF_FFFF)
        #expect(OpID(NodeID(id)) == id)
        #expect(NodeID(id) == NodeID(counter: 12, replica: 0xFFFF_FFFF_FFFF))
        #expect(OpID(element: id.elementID) == id)
        #expect(OpID(element: Wiretuner_Doc_V1_ElementId()) == nil)
        #expect(WellKnown.document == .wellKnown(0) && WellKnown.settings == .wellKnown(1) && WellKnown.pages == .wellKnown(2))
        #expect(NodeKind.allCases.count == 5)
    }

    @Test func wellKnownAndUnknownNodesReadEmpty() {
        let state = EngineState()
        #expect(state.props(WellKnown.layers) == Wiretuner_Doc_V1_NodeProps())
        #expect(state.props(OpID(counter: 5, replica: 5)) == Wiretuner_Doc_V1_NodeProps())
        #expect(state.nodeKind(WellKnown.layers) == nil)
        #expect(state.isLive(WellKnown.layers))
        #expect(!state.isLive(OpID(counter: 5, replica: 5)))
        // The settings node has a kind but nothing written.
        #expect(state.props(WellKnown.settings).settings == Wiretuner_Doc_V1_SettingsProps())
    }

    @Test func nestedSequencesReadLiveElementsInOrderWithIDs() throws {
        var replica = Replica(7)
        let change = try replica.perform(CreatePath(contours: [
            NewContour(points: [VectorPoint(anchor: Point(x: 1, y: 2)), VectorPoint(anchor: Point(x: 3, y: 4), inHandle: Vector(dx: 1, dy: 0))]),
            NewContour(closed: true, points: [VectorPoint(anchor: Point(x: 5, y: 6)), VectorPoint(anchor: Point(x: 7, y: 8))]),
        ]))!
        let node = change.createdObjects[0]
        let contours = replica.state.liveElements(node, PathFields.contours)
        let props = replica.state.props(node).path
        #expect(props.contours.map { OpID(element: $0.id) } == contours)
        #expect(props.contours[1].closed)
        #expect(props.contours[0].points.map(\.anchor.x) == [1, 3])
        #expect(props.contours[0].points[1].inHandle.x == 1)
        #expect(props.contours[0].points.allSatisfy { OpID(element: $0.id) != nil })
        #expect(replica.state.position(node, PathFields.contours, contours[0]) != nil)

        // Delete a point and a whole contour: they and everything under them are left out.
        let first = props.contours[0].points.map { OpID(element: $0.id)! }
        try replica.perform(DeletePoints(node: node, points: [(contours[0], first[0])]))
        try replica.perform(OpsCommand("Delete contour", ops: [Ops.elementDelete(node, [PathFields.contour(contours[1])])]))
        // A write to a point of the deleted contour still lands in its register, but is not read.
        let hiddenPoint = replica.state.liveElements(node, PathFields.points(contours[1]))[0]
        var value = Wiretuner_Doc_V1_PathPoint()
        value.anchor.x = 99
        try replica.perform(OpsCommand("Move", ops: [Ops.set(node, [PathFields.anchor(contours[1], hiddenPoint)], values: PathEditing.pointValues(value))]))
        let after = replica.state.props(node).path
        #expect(after.contours.count == 1)
        #expect(after.contours[0].points.map(\.anchor.x) == [3])
        #expect(replica.state.liveElements(node, PathFields.points(contours[0])) == [first[1]])
        #expect(replica.state.store.elementOrder(node, PathFields.points(contours[0])).count == 2)
    }

    @Test func aSequenceWhoseElementsAreAllDeletedReadsEmpty() throws {
        var replica = Replica(7)
        let (node, contour) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (1, 1)])), in: replica.state)
        try replica.perform(OpsCommand("Delete contour", ops: [Ops.elementDelete(node, [PathFields.contour(contour)])]))
        let path = replica.state.props(node).path
        #expect(path.contours.isEmpty)
        #expect(path.appearance.strokes.count == 1)
    }

    @Test func wireHelpersEncodeLikeSwiftProtobuf() throws {
        #expect(Wire.varint(0) == [0])
        #expect(Wire.varint(300) == [0xAC, 0x02])
        let id = OpID(counter: 300, replica: 0x0102_0304_0506_0708)
        let decoded = try Wiretuner_Doc_V1_ElementId(serializedBytes: Wire.elementID(id))
        #expect(OpID(element: decoded) == id)
        #expect(Wire.field(1, [7]) == [0x0A, 0x01, 0x07])
    }

    @Test func childrenAndKindsSkipDeletedNodes() throws {
        var replica = Replica(7)
        let a = try replica.perform(PathFixture.open([(0, 0), (1, 1)]))!.createdObjects[0]
        let b = try replica.perform(PathFixture.open([(0, 0), (1, 1)]))!.createdObjects[0]
        let layer = replica.state.liveChildren(WellKnown.layers)[0]
        #expect(replica.state.nodeKind(layer) == .layer && replica.state.nodeKind(a) == .path)
        try replica.perform(DeleteNodes([a]))
        #expect(replica.state.liveChildren(layer) == [b])
        #expect(replica.state.store.children(layer) == [a, b])
    }
}

@Suite struct NodeValuesTests {
    @Test func everyKindHasItsFields() {
        var stack = Wiretuner_Doc_V1_AppearanceProps()
        stack.rasterDpi = 72
        #expect(NodeValues.with(kind: .group, appearanceField: 6, stack).group.appearance.rasterDpi == 72)
        #expect(NodeValues.with(kind: .layer, appearanceField: 0, stack) == Wiretuner_Doc_V1_NodeProps())
        var transform = Wiretuner_Doc_V1_Transform()
        transform.tx = 3
        #expect(NodeValues.with(kind: .layer, transform: transform).layer.common.transform.tx == 3)
        #expect(NodeValues.common(NodeValues.with(kind: .layer, transform: transform))?.transform.tx == 3)
        var text = Wiretuner_Doc_V1_NodeProps()
        text.text = Wiretuner_Doc_V1_TextProps()
        #expect(NodeValues.common(text) == nil)
        #expect(NodeKind.allCases.map(NodeValues.appearanceField) == [3, 4, 3, 6, nil])
    }
}
