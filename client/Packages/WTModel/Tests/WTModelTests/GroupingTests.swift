import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Arrange (OBJ-018), Group and Ungroup (OBJ-016) and the shape conversion of Ungroup (DRAW-009,
/// DRAW-012).
@Suite struct ArrangeTests {
    static func row(_ n: Int, on a: inout Replica) throws -> [OpID] {
        try (0..<n).map { i in try LayerFixture.object(LayerFixture.rect(on: nil, x: Double(i) * 20), on: &a) }
    }

    @Test func everyDirectionKeepsTheSelectionsOrder() throws {
        var a = Replica(0xA)
        let n = try Self.row(5, on: &a)
        let layer = Objects.parent(of: n[0], in: a.state)!
        #expect(try a.perform(Arrange([n[1], n[2]], .bringForward))?.label == "Bring Forward")
        #expect(a.state.liveChildren(layer) == [n[0], n[3], n[1], n[2], n[4]])
        try a.perform(Arrange([n[1], n[2]], .bringToFront))
        #expect(a.state.liveChildren(layer) == [n[0], n[3], n[4], n[1], n[2]])
        try a.perform(Arrange([n[4], n[1]], .sendBackward))
        #expect(a.state.liveChildren(layer) == [n[0], n[4], n[1], n[3], n[2]])
        try a.perform(Arrange([n[3], n[2]], .sendToBack))
        #expect(a.state.liveChildren(layer) == [n[3], n[2], n[0], n[4], n[1]])
        // Nothing to pass: no change.
        #expect(try a.perform(Arrange([n[1]], .bringForward)) == nil)
        #expect(try a.perform(Arrange([n[3]], .sendBackward)) == nil)
        #expect(try a.perform(Arrange(n, .sendToBack)) == nil)
        #expect(Arrange.Direction.allCases.map(\.title) == ["Bring to Front", "Bring Forward", "Send Backward", "Send to Back"])
    }

    @Test func insideAClipGroupNothingGoesBelowTheClipPath() throws {
        var a = Replica(0xA)
        let n = try Self.row(3, on: &a)
        let group = try a.perform(GroupObjects(n))!.createdObjects[0]
        var clip = Wiretuner_Doc_V1_NodeProps()
        clip.group.kind = .clip
        clip.group.clipPath.id = n[0].proto
        try a.perform(OpsCommand("clip", ops: [Ops.set(group, [RegisterPath([50, 2]), RegisterPath([50, 4])], values: clip)]))
        #expect(Arranging.clipPath(of: group, in: a.state) == n[0])
        try a.perform(Arrange([n[2]], .sendToBack))
        #expect(a.state.liveChildren(group) == [n[0], n[2], n[1]])
        #expect(try a.perform(Arrange([n[2]], .sendBackward)) == nil)
        #expect(try a.perform(Arrange([n[0]], .bringToFront)) == nil)   // the clip path stays
        #expect(Arranging.clipPath(of: n[1], in: a.state) == nil)
        #expect(Arranging.siblingAfter(OpID(counter: 99, replica: 9), in: a.state) == nil)
        #expect(Arranging.siblingBefore(OpID(counter: 99, replica: 9), in: a.state) == nil)
        #expect(Arranging.siblingBefore(n[0], in: a.state) == nil)
    }
}

@Suite struct GroupingTests {
    @Test func groupingCollectsAcrossLayersOntoTheActiveLayerInOrder() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Base", "Top"], on: &a)
        let low = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &a)
        let high = try LayerFixture.object(LayerFixture.rect(on: layers[1]), on: &a)
        let lowToo = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 30), on: &a)
        let change = try a.perform(GroupObjects([high, low, lowToo], layer: layers[1], rememberLayerInfo: true))!
        #expect(change.label == "Group")
        let group = change.createdObjects[0]
        #expect(Objects.parent(of: group, in: a.state) == layers[1])
        #expect(a.state.liveChildren(group) == [low, lowToo, high])
        #expect(Objects.transform(of: group, in: a.state) == .identity)
        #expect(Ungroup.origins(of: group, in: a.state) == [low: layers[0], lowToo: layers[0], high: layers[1]])
        // Ungroup with Remember layer info returns each to its layer.
        try a.perform(Ungroup([group], rememberLayerInfo: true))
        #expect(Objects.parent(of: low, in: a.state) == layers[0])
        #expect(Objects.parent(of: high, in: a.state) == layers[1])
        #expect(!a.state.isLive(group))
        #expect(try a.perform(GroupObjects([])) == nil)
    }

    @Test func groupingSiblingsGroupsThemInPlace() throws {
        var a = Replica(0xA)
        let n = try ArrangeTests.row(4, on: &a)
        let group = try a.perform(GroupObjects([n[1], n[2]]))!.createdObjects[0]
        let layer = Objects.parent(of: n[0], in: a.state)!
        #expect(a.state.liveChildren(layer) == [n[0], group, n[3]])
    }

    @Test func ungroupBakesTheGroupsMatrixIntoEachMember() throws {
        var a = Replica(0xA)
        let n = try ArrangeTests.row(3, on: &a)
        let group = try a.perform(GroupObjects([n[0], n[1]]))!.createdObjects[0]
        try a.perform(TransformObjects([group], matrix: .rotation(radians: 0.7), about: Point(x: 5, y: 5), kind: .rotate))
        let before = [n[0], n[1]].map { Objects.pasteboardTransform(of: $0, in: a.state) }
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let sceneBefore = builder.rebuild(a.state)
        let change = try a.perform(Ungroup([group]))!
        #expect(change.label == "Ungroup")
        for (member, transform) in zip([n[0], n[1]], before) {
            #expect(nearly(Objects.pasteboardTransform(of: member, in: a.state), transform))
        }
        let layer = Objects.parent(of: n[2], in: a.state)!
        #expect(a.state.liveChildren(layer) == [n[0], n[1], n[2]])
        // Visually unchanged: every member's painted bounds are the same.
        let sceneAfter = builder.rebuild(a.state)
        for member in [n[0], n[1]] {
            let old = sceneBefore.object(member)!.bounds!, new = sceneAfter.object(member)!.bounds!
            #expect(abs(old.minX - new.minX) < 1e-9 && abs(old.maxY - new.maxY) < 1e-9)
        }
        a.undo()
        #expect(a.state.isLive(group) && a.state.liveChildren(group) == [n[0], n[1]])
    }

    @Test func ungroupingAShapeConvertsItToAPath() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(CreateShape(.rectangle(.uniform(3)), size: Size(width: 20, height: 10), transform: .translation(x: 4, y: 4)), on: &a)
        let star = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 10, autoInner: true), center: Point(x: 50, y: 50)), on: &a)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 8, height: 8)), on: &a)
        let outline = [rect, star, ellipse].map { Objects.localPath($0, in: a.state)! }
        let change = try a.perform(Ungroup([rect, star, ellipse]))!
        let paths = change.createdRoots
        #expect(paths.count == 3)
        for (index, path) in paths.enumerated() {
            #expect(a.state.nodeKind(path) == .path)
            #expect(a.path(path).contours.map { $0.drawn.map(\.anchor) } == outline[index].contours.map { $0.drawn.map(\.anchor) })
            let closed = a.path(path).contours.allSatisfy { $0.closed }
            #expect(closed)
        }
        #expect(Objects.transform(of: paths[0], in: a.state) == .translation(x: 4, y: 4))
        #expect(a.state.props(paths[0]).path.appearance.strokes.count == 1)
        #expect(![rect, star, ellipse].contains(where: a.state.isLive))
        a.undo()
        #expect(a.state.isLive(rect) && a.state.isLive(star))
        // A path is left alone.
        let line = try LayerFixture.object(PathFixture.open([(0, 0), (5, 5)]), on: &a)
        #expect(try a.perform(Ungroup([line])) == nil)
    }

    @Test func stackingOrderFollowsLayersThenSiblings() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Base", "Top"], on: &a)
        let top = try LayerFixture.object(LayerFixture.rect(on: layers[1]), on: &a)
        let base = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &a)
        let m = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &a)
        let group = try a.perform(GroupObjects([m]))!.createdObjects[0]
        #expect(Objects.stackingOrder([top, m, base, group], in: a.state) == [base, group, m, top])
        #expect(Objects.stackingOrder([top, OpID(counter: 999, replica: 3)], in: a.state) == [top, OpID(counter: 999, replica: 3)])
    }
}

/// The merge tests of OBJ-016, OBJ-018 and DRAW-009/DRAW-012's conversion.
@Suite struct GroupingMergeTests {
    @Test func overlappingGroupsLeaveEachObjectInExactlyOneGroup() throws {
        var pair = Pair()
        let n = try ArrangeTests.row(3, on: &pair.a)
        pair.sync()
        let g1 = try pair.a.perform(GroupObjects([n[0], n[1]]))!.createdObjects[0]
        let g2 = try pair.b.perform(GroupObjects([n[1], n[2]]))!.createdObjects[0]
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for node in n {
            let parent = Objects.parent(of: node, in: pair.a.state)
            #expect(parent == g1 || parent == g2)
        }
        #expect(Objects.parent(of: n[0], in: pair.a.state) == g1)
        #expect(Objects.parent(of: n[2], in: pair.a.state) == g2)
    }

    @Test func ungroupVersusMemberMoveKeepsOneMatrixWithTheLoserRetained() throws {
        var pair = Pair()
        let n = try ArrangeTests.row(2, on: &pair.a)
        let group = try pair.a.perform(GroupObjects(n))!.createdObjects[0]
        try pair.a.perform(MoveObjects([group], by: Vector(dx: 100, dy: 0)))
        pair.sync()
        try pair.a.perform(Ungroup([group]))
        try pair.b.perform(MoveObjects([n[0]], by: Vector(dx: 0, dy: 50)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(group))
        #expect(pair.a.state.store.losingWrites(n[0], CommonFields.transform(.rect)).count >= 1)
    }

    @Test func concurrentBringToFrontKeepsBothObjects() throws {
        var pair = Pair()
        let n = try ArrangeTests.row(3, on: &pair.a)
        pair.sync()
        try pair.a.perform(Arrange([n[0]], .bringToFront))
        try pair.b.perform(Arrange([n[1]], .bringToFront))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let layer = Objects.parent(of: n[2], in: pair.a.state)!
        let children = pair.a.state.liveChildren(layer)
        #expect(Set(children) == Set(n))
        #expect(children.first == n[2])
    }

    @Test func resizeVersusCornerRadiusKeepsBoth() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        try pair.a.perform(SetShapesSize([rect], width: 40))
        try pair.b.perform(SetCornerRadius([rect], radius: 3))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let props = pair.a.state.props(rect).rect
        #expect(props.size.width == 40 && props.corners.topLeft == 3)
    }

    @Test func conversionVersusRadiusEditLeavesThePathAndTheEditOnTheDeletedShape() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        let path = try pair.a.perform(Ungroup([rect]))!.createdRoots[0]
        try pair.b.perform(SetCornerRadius([rect], radius: 2))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.isLive(path) && !pair.a.state.isLive(rect))
        #expect(pair.a.state.props(rect).rect.corners.topLeft == 2)
    }

    @Test func polygonConversionVersusHandleDrag() throws {
        var pair = Pair()
        let star = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 10), center: .zero), on: &pair.a)
        pair.sync()
        let path = try pair.a.perform(Ungroup([star]))!.createdRoots[0]
        try pair.b.perform(SetPolygonFields([star], .init(radius: 20, rotation: 0.3)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.isLive(path) && !pair.a.state.isLive(star))
        #expect(pair.a.state.props(star).polygon.radius == 20)
    }
}
