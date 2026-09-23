import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

private func p(_ x: Double, _ y: Double) -> VectorPoint { VectorPoint(anchor: Point(x: x, y: y)) }

private func groupProps(tx: Double = 0) -> Wiretuner_Doc_V1_NodeProps {
    var props = Wiretuner_Doc_V1_NodeProps()
    props.group = Wiretuner_Doc_V1_GroupProps()
    if tx != 0 { props.group.common.transform = PathEditing.proto(AffineTransform.translation(x: tx, y: 0)) }
    return props
}

@Suite struct SceneTests {
    @Test func sceneDrawsThePathTaggedWithItsNode() throws {
        var replica = Replica(7)
        let change = try replica.perform(PathFixture.closed([(0, 0), (10, 0), (10, 10)]))
        let (node, contour) = PathFixture.ids(change, in: replica.state)
        var builder = DocumentDisplayListBuilder(canvas: "c", background: [.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 1, height: 1)), paint: .solid(.white)))])
        let scene = builder.rebuild(replica.state)
        #expect(scene.displayList.nodeIDs == [nil, NodeID(node)])
        #expect(scene.topLevel == [NodeID(node)])
        let object = try #require(scene.object(node))
        #expect(object.kind == .path && object.itemPath == [1] && object.parent == nil)
        #expect(scene.object(atItemPath: [1])?.id == node)
        #expect(scene.object(atItemPath: [0]) == nil)
        let ids = replica.path(node).contours[0].points.map(\.id)
        #expect(object.point(leafPath: [1], element: 0) == PointRef(contour: contour, point: ids[0]))
        #expect(object.point(leafPath: [1], element: 2)?.point == ids[2])
        #expect(object.point(leafPath: [1], element: 3)?.point == ids[0])   // the closing segment
        #expect(object.point(leafPath: [1], element: 4) == nil)             // close
        #expect(object.point(leafPath: [1], element: 9) == nil)
        #expect(object.point(leafPath: [2], element: 0) == nil)
        #expect(object.contour(leafPath: [1], index: 0) == contour)
        #expect(object.contour(leafPath: [1], index: 1) == nil)
        #expect(object.contour(leafPath: [5], index: 0) == nil)
        #expect(object.bounds != nil)
        guard case .path(let item) = scene.displayList.items[1] else { Issue.record("item"); return }
        #expect(item.path.elements.count == 5)
        #expect(builder.scene == scene)
    }

    @Test func curvesShapesTransformsAndTheLayersTransform() throws {
        var replica = Replica(7)
        let curve = try replica.perform(CreatePath(contours: [NewContour(points: [VectorPoint(anchor: .zero, outHandle: Vector(dx: 5, dy: 0)), p(10, 10)])], transform: .translation(x: 100, y: 0)))!.createdObjects[0]
        let rect = try replica.perform(CreateShape(.rectangle(.uniform(0)), size: Size(width: 10, height: 10)))!.createdObjects[0]
        let ellipse = try replica.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)))!.createdObjects[0]
        let layer = replica.state.liveChildren(WellKnown.layers)[0]
        var layerMove = Wiretuner_Doc_V1_NodeProps()
        layerMove.layer.common.transform = PathEditing.proto(AffineTransform.translation(x: 0, y: 50))
        try replica.perform(OpsCommand("Move layer", ops: [Ops.set(layer, [RegisterPath([150, 1, 4])], values: layerMove)]))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(replica.state)
        #expect(scene.topLevel == [curve, rect, ellipse].map(NodeID.init))
        #expect(scene.object(curve)?.transform == AffineTransform.translation(x: 100, y: 50))
        #expect(scene.object(rect)?.path?.contours[0].points.count == 4)
        #expect(scene.object(ellipse)?.kind == .ellipse)
        guard case .path(let item) = scene.displayList.items[0] else { Issue.record("item"); return }
        if case .cubicCurve = item.path.elements[1] {} else { Issue.record("expected a cubic") }
        #expect(item.transform == AffineTransform.translation(x: 100, y: 50))
    }

    @Test func invisibleLayersCanvasObjectsAndEmptyPathsAreSkipped() throws {
        var replica = Replica(7)
        let visible = try replica.perform(PathFixture.open([(0, 0), (10, 0)]))!.createdObjects[0]
        let layer = replica.state.liveChildren(WellKnown.layers)[0]
        // A hidden layer's objects are skipped.
        var hidden = Wiretuner_Doc_V1_NodeProps()
        hidden.layer.visible = false
        let hiddenLayer = try replica.perform(OpsCommand("L", ops: [Ops.create(parent: WellKnown.layers, position: [0x10], props: hidden)]))!.createdNodes[0]
        var path = Wiretuner_Doc_V1_NodeProps()
        path.path = Wiretuner_Doc_V1_PathProps()
        try replica.perform(OpsCommand("P", ops: [Ops.create(parent: hiddenLayer, position: [0x80], props: path)]))
        // A path on a master page's canvas is not drawn on the pasteboard.
        var onMaster = Wiretuner_Doc_V1_NodeProps()
        onMaster.path.common.canvas.id = OpID(counter: 1, replica: 9).proto
        try replica.perform(OpsCommand("P", ops: [Ops.create(parent: layer, position: [0xF0], props: onMaster)]))
        // A path with no renderable contour, and a node of a kind WTModel does not draw.
        try replica.perform(OpsCommand("P", ops: [Ops.create(parent: layer, position: [0xF1], props: path)]))
        var text = Wiretuner_Doc_V1_NodeProps()
        text.text = Wiretuner_Doc_V1_TextProps()
        try replica.perform(OpsCommand("T", ops: [Ops.create(parent: layer, position: [0xF2], props: text)]))
        // An empty group draws nothing.
        try replica.perform(OpsCommand("G", ops: [Ops.create(parent: layer, position: [0xF3], props: groupProps())]))
        // Non-layer children of the layers collection are ignored.
        try replica.perform(OpsCommand("G", ops: [Ops.create(parent: WellKnown.layers, position: [0xF4], props: groupProps())]))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(replica.state)
        #expect(scene.topLevel == [NodeID(visible)])
    }

    @Test func groupsNestTheirMembersWithFlattenedTransforms() throws {
        var replica = Replica(7)
        let a = try replica.perform(PathFixture.open([(0, 0), (10, 0)]))!.createdObjects[0]
        let b = try replica.perform(CreateShape(.rectangle(.uniform(0)), size: Size(width: 5, height: 5)))!.createdObjects[0]
        let layer = replica.state.liveChildren(WellKnown.layers)[0]
        let group = try replica.perform(OpsCommand("Group", ops: [Ops.create(parent: layer, position: [0xF0], props: groupProps(tx: 20))]))!.createdNodes[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(replica.state)
        let change = try replica.perform(OpsCommand("Group", ops: [Ops.move(a, parent: group, position: [0x80]), Ops.move(b, parent: group, position: [0x90])]))!
        let (scene, summary) = builder.apply(change, state: replica.state, origin: .local)
        #expect(scene.topLevel == [NodeID(group)])
        #expect(summary.isStructural)
        #expect(summary.touchedNodes.isSuperset(of: [NodeID(a), NodeID(b), NodeID(group)]))
        let member = try #require(scene.object(a))
        #expect(member.itemPath == [0, 0] && member.parent == group)
        #expect(member.transform == AffineTransform.translation(x: 20, y: 0))
        #expect(scene.object(atItemPath: [0, 1])?.id == b)
        guard case .group(let item) = scene.displayList.items[0], case .path(let first) = item.children[0] else { Issue.record("group"); return }
        #expect(first.transform == AffineTransform.translation(x: 20, y: 0))
        // Moving the group moves the members: they are in the summary with new bounds.
        let move = try replica.perform(SetTransforms([(group, .translation(x: 40, y: 0))]))!
        let (moved, movedSummary) = builder.apply(move, state: replica.state, origin: .remote)
        #expect(movedSummary.origin == .remote && !movedSummary.isStructural)
        let old = try #require(movedSummary.bounds[NodeID(a)]?.old?.rect.minX)
        let new = try #require(movedSummary.bounds[NodeID(a)]?.new?.rect.minX)
        #expect(new - old == 20)
        #expect(moved.object(b)?.transform == AffineTransform.translation(x: 40, y: 0))
        // A nested group of a transformed group.
        let inner = try replica.perform(OpsCommand("Inner", ops: [Ops.create(parent: group, position: [0xA0], props: groupProps(tx: 1)), ]))!
        let innerID = inner.createdNodes[0]
        let c = try replica.perform(PathFixture.open([(0, 0), (1, 0)]))!.createdObjects[0]
        let nest = try replica.perform(OpsCommand("Nest", ops: [Ops.move(c, parent: innerID, position: [0x80])]))!
        builder.rebuild(replica.state)
        _ = nest
        #expect(builder.scene.object(c)?.transform == AffineTransform.translation(x: 41, y: 0))
        #expect(builder.scene.object(c)?.itemPath == [0, 2, 0])
    }

    @Test func summariesNameTouchedNodesFieldsAndBounds() throws {
        var replica = Replica(7)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(replica.state)
        let create = try replica.perform(PathFixture.open([(0, 0), (10, 0)]))!
        let node = create.createdObjects[0]
        let (_, created) = builder.apply(create, state: replica.state, origin: .local)
        #expect(created.isStructural && created.origin == .local)
        #expect(created.bounds[NodeID(node)]?.old == nil)
        #expect(created.bounds[NodeID(node)]?.new?.canvas == "c")
        let contour = replica.state.liveElements(node, PathFields.contours)[0]
        let point = replica.path(node).contours[0].points[1].id
        let move = try replica.perform(MovePoints(node: node, contour: contour, point: point, to: Point(x: 30, y: 0)))!
        let (_, moved) = builder.apply(move, state: replica.state, origin: .local)
        #expect(!moved.isStructural)
        #expect(moved.touched(NodeID(node), field: FieldPath(PathFields.anchor(contour, point))))
        #expect(moved.bounds[NodeID(node)]?.old?.rect.maxX ?? 0 < moved.bounds[NodeID(node)]?.new?.rect.maxX ?? 0)
        // A write to a node that draws nothing is touched without bounds.
        let layer = replica.state.liveChildren(WellKnown.layers)[0]
        let rename = try replica.perform(OpsCommand("Rename", ops: [Ops.set(layer, [RegisterPath([150, 1, 1])], values: Fixture.layer(name: "X"))]))!
        let (_, renamed) = builder.apply(rename, state: replica.state, origin: .local)
        #expect(renamed.touchedNodes.contains(NodeID(layer)))
        #expect(renamed.bounds[NodeID(layer)] == nil)
        #expect(renamed.bounds[NodeID(node)] != nil)   // everything on a touched layer
        // Delete.
        let delete = try replica.perform(DeleteNodes([node]))!
        let (after, deleted) = builder.apply(delete, state: replica.state, origin: .local)
        #expect(deleted.isStructural && after.topLevel.isEmpty)
        #expect(deleted.bounds[NodeID(node)]?.new == nil && deleted.bounds[NodeID(node)]?.old != nil)
    }

    @Test func reorderIsStructural() throws {
        var replica = Replica(7)
        let a = try replica.perform(PathFixture.open([(0, 0), (10, 0)]))!.createdObjects[0]
        let b = try replica.perform(PathFixture.open([(0, 5), (10, 5)]))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(replica.state)
        let layer = replica.state.liveChildren(WellKnown.layers)[0]
        let top = try PathEditing.topPosition(in: layer, state: replica.state)
        let raise = try replica.perform(OpsCommand("Bring to Front", ops: [Ops.move(a, parent: layer, position: top)]))!
        let (scene, summary) = builder.apply(raise, state: replica.state, origin: .local)
        #expect(summary.isStructural)
        #expect(scene.topLevel == [NodeID(b), NodeID(a)])
    }

    @Test func everyOpKindNamesItsNode() {
        let node = OpID(counter: 3, replica: 1)
        let field = RegisterPath([20, 4])
        var mark = Wiretuner_Doc_V1_TextMark()
        mark.node = node.proto
        mark.text = field.proto
        var markOp = Wiretuner_Doc_V1_Op()
        markOp.textMark = mark
        let ops: [Wiretuner_Doc_V1_Op] = [
            Ops.create(parent: node, position: [0x80], props: Wiretuner_Doc_V1_NodeProps()),
            Ops.set(node, [field], values: Wiretuner_Doc_V1_NodeProps()),
            Ops.move(node, parent: WellKnown.layers, position: [0x80]),
            Ops.setDeleted(node),
            Ops.elementInsert(node, field, positions: [[0x80]]),
            Ops.elementMove(node, field.element(node), position: [0x80]),
            Ops.elementDelete(node, [field.element(node)]),
            Ops.setAdd(node, field, values: Wiretuner_Doc_V1_NodeProps()),
            Ops.setRemove(node, field, values: Wiretuner_Doc_V1_NodeProps()),
            Ops.textInsert(node, field, "a"),
            Ops.textDelete(node, field, first: node, count: 1),
            markOp,
        ]
        for op in ops {
            #expect(DocumentDisplayListBuilder.targets(op).first?.0 == node)
        }
        #expect(DocumentDisplayListBuilder.targets(Ops.noop()).isEmpty)
        #expect(DocumentDisplayListBuilder.targets(Ops.move(node, parent: WellKnown.layers, position: [0x80])).count == 2)
    }

    @Test func openContoursWithoutFillWhenOpenDropOrSplitTheirFills() throws {
        var replica = Replica(7)
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        // Only open contours: the fill is dropped.
        let open = try replica.perform(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0), p(10, 10)])], appearance: appearance))!.createdObjects[0]
        // Open and closed contours: one item per attribute, the fill over the closed contour only.
        let mixed = try replica.perform(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0)]), NewContour(closed: true, points: [p(0, 5), p(5, 5), p(5, 9)])],
                                                   appearance: appearance))!.createdObjects[0]
        // fill_when_open: one item painting the fill everywhere.
        let filled = try replica.perform(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0), p(10, 10)])], appearance: appearance, fillWhenOpen: true))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(replica.state)
        guard case .path(let openItem) = scene.displayList.items[0] else { Issue.record("open"); return }
        #expect(openItem.appearance.items.count == 1)
        guard case .group(let group) = scene.displayList.items[1] else { Issue.record("mixed"); return }
        #expect(group.children.count == 2)
        guard case .path(let fillItem) = group.children[0], case .path(let strokeItem) = group.children[1] else { Issue.record("children"); return }
        #expect(fillItem.path.elements.count == 5 && strokeItem.path.elements.count == 7)
        let object = try #require(scene.object(mixed))
        let closedContour = replica.path(mixed).contours[1]
        #expect(object.point(leafPath: [1, 0], element: 0)?.point == closedContour.points[0].id)
        #expect(object.point(leafPath: [1, 1], element: 0)?.point == replica.path(mixed).contours[0].points[0].id)
        #expect(object.contour(leafPath: [1, 0], index: 0) == closedContour.id)
        #expect(object.contour(leafPath: [1, 1], index: 1) == closedContour.id)
        guard case .path(let filledItem) = scene.displayList.items[2] else { Issue.record("filled"); return }
        #expect(filledItem.appearance.items.count == 2)
        _ = (open, filled)
    }

    @Test func setBackgroundKeepsObjectsAndIsStructural() throws {
        var replica = Replica(7)
        let node = try replica.perform(PathFixture.open([(0, 0), (10, 0)]))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(replica.state)
        let page = DisplayItem.fill(FillItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 5, height: 5)), paint: .solid(.white)))
        let (scene, summary) = builder.setBackground([page, page], state: replica.state)
        #expect(summary.isStructural && summary.touchedNodes.isEmpty)
        #expect(scene.displayList.nodeIDs == [nil, nil, NodeID(node)])
        #expect(builder.background.count == 2)
        #expect(scene.object(node)?.itemPath == [2])
    }

    @Test func transformedLeavesItemsWithoutTransformsAlone() {
        let text = DisplayItem.text(TextRunItem(text: "a", origin: .zero, bounds: Rect(x: 0, y: 0, width: 1, height: 1)))
        #expect(DocumentDisplayListBuilder.transformed(text, by: .translation(x: 5, y: 0)) == text)
        let group = DisplayItem.group(GroupItem(children: [.path(PathItem(path: DisplayPath(), appearance: Appearance()))]))
        guard case .group(let moved) = DocumentDisplayListBuilder.transformed(group, by: .translation(x: 5, y: 0)),
              case .path(let child) = moved.children[0] else { Issue.record("group"); return }
        #expect(child.transform == AffineTransform.translation(x: 5, y: 0))
    }

    @Test func fieldPathsMirrorRegisterPaths() {
        let element = OpID(counter: 4, replica: 2)
        let path = FieldPath(RegisterPath(segments: [.field(20), .field(2), .element(element), .field(2)]))
        #expect(path.segments == [.field(20), .field(2), .element(NodeID(element)), .field(2)])
        #expect(OpID(NodeID(element)) == element)
    }
}
