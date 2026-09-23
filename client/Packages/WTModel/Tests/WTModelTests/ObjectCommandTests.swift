import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

func nearly(_ a: WTGeometry.AffineTransform, _ b: WTGeometry.AffineTransform, _ tolerance: Double = 1e-9) -> Bool {
    abs(a.a - b.a) < tolerance && abs(a.b - b.b) < tolerance && abs(a.c - b.c) < tolerance && abs(a.d - b.d) < tolerance
        && abs(a.tx - b.tx) < tolerance && abs(a.ty - b.ty) < tolerance
}

/// Move, transform, point transform, lock, name and note (OBJ-008, OBJ-031, OBJ-020, OBJ-002).
@Suite struct ObjectCommandTests {
    @Test func aMoveOfFiftyObjectsIsOneChangeOfFiftyWrites() throws {
        var a = Replica(0xA)
        var nodes: [OpID] = []
        for i in 0..<50 { nodes.append(try LayerFixture.object(LayerFixture.rect(on: nil, x: Double(i) * 20), on: &a)) }
        let change = try a.perform(MoveObjects(nodes, by: Vector(dx: 5, dy: -2)))!
        #expect(change.label == "Move 50 objects")
        #expect(change.ops.count == 50)
        #expect(change.ops.allSatisfy { if case .set = $0.op { true } else { false } })
        #expect(Objects.bounds(of: nodes[1], in: a.state) == Rect(x: 25, y: -2, width: 10, height: 10))
        #expect(MoveObjects([nodes[0]], by: .zero).label == "Move")
        #expect(throws: ObjectEditError.invalidValue("delta")) { try a.perform(MoveObjects(nodes, by: Vector(dx: .nan, dy: 0))) }
    }

    @Test func aMemberMovesTheSameDistanceOnScreen() throws {
        var a = Replica(0xA)
        let m1 = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let m2 = try LayerFixture.object(LayerFixture.rect(on: nil, x: 20), on: &a)
        let group = try a.perform(GroupObjects([m1, m2]))!.createdObjects[0]
        try a.perform(TransformObjects([group], matrix: .scale(2), kind: .scale))
        let before = Objects.bounds(of: m1, in: a.state)!
        try a.perform(MoveObjects([m1], by: Vector(dx: 10, dy: 0)))
        let after = Objects.bounds(of: m1, in: a.state)!
        #expect(abs(after.minX - before.minX - 10) < 1e-9)
        #expect(Objects.pasteboardTransform(of: m1, in: a.state).a == 2)
    }

    @Test func rotatingARectangleWritesOnlyItsTransform() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let before = a.state.props(rect).rect
        let pivot = Point(x: 37, y: -12)
        let command = TransformObjects([rect], matrix: .rotation(radians: .pi / 6), about: pivot, kind: .rotate)
        let change = try a.perform(command)!
        #expect(change.label == "Rotate")
        #expect(change.ops.count == 1)
        let after = a.state.props(rect).rect
        #expect(after.size == before.size && after.corners == before.corners)
        #expect(nearly(Objects.transform(of: rect, in: a.state), .rotation(radians: .pi / 6, around: pivot)))
        #expect(a.state.nodeKind(rect) == .rect)
        #expect(TransformObjects([rect, rect], matrix: .identity, kind: .skew).label == "Skew 2 objects")
    }

    @Test func strokesOptionScalesStrokeWidthsInTheSameChange() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let group = try a.perform(GroupObjects([try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)]))!.createdObjects[0]
        let change = try a.perform(TransformObjects([rect, group], matrix: .scale(2), kind: .scale, options: TransformOptions(strokes: true)))!
        #expect(change.ops.count == 3)   // two transforms and one width
        #expect(a.state.props(rect).rect.appearance.strokes[0].settings.basic.width == 2)
        try a.perform(TransformObjects([rect], matrix: .scale(2), kind: .scale))
        #expect(a.state.props(rect).rect.appearance.strokes[0].settings.basic.width == 2)
        #expect(throws: ObjectEditError.degenerateTransform) { try a.perform(TransformObjects([rect], matrix: .scale(0), kind: .scale)) }
    }

    @Test func copiesAreProgressivelyTransformed() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let above = try LayerFixture.object(LayerFixture.rect(on: nil, x: 99), on: &a)
        let pivot = Point(x: 50, y: 50)
        let change = try a.perform(TransformObjects([rect], matrix: .rotation(radians: .pi / 6), about: pivot, kind: .rotate,
                                                    options: TransformOptions(strokes: true), copies: 3))!
        #expect(change.label == "Rotate with 3 copies")
        #expect(TransformObjects([rect], matrix: .identity, kind: .move, copies: 1).label == "Move with 1 copy")
        let copies = change.createdRoots
        #expect(copies.count == 3)
        #expect(Objects.transform(of: rect, in: a.state) == .identity)
        for (k, copy) in copies.enumerated() {
            let angle = Double(k + 1) * .pi / 6
            #expect(nearly(Objects.transform(of: copy, in: a.state), .rotation(radians: angle, around: pivot)))
        }
        let layer = Objects.parent(of: rect, in: a.state)!
        #expect(a.state.liveChildren(layer) == [rect] + copies + [above])
    }

    @Test func pointTransformsWritePointRegisters() throws {
        var a = Replica(0xA)
        var command = PathFixture.open([(0, 0), (10, 0), (20, 0)])
        command.contours[0].points[1].outHandle = Vector(dx: 2, dy: 0)
        command.contours[0].points[2].automatic = true
        let (node, contour) = PathFixture.ids(try a.perform(command), in: a.state)
        let ids = a.path(node).contours[0].points.map(\.id)
        let change = try a.perform(TransformPoints(node: node, points: [(contour, ids[1]), (contour, ids[2])],
                                                   matrix: .scale(2), about: .zero, kind: .scale))!
        #expect(change.label == "Scale Points")
        #expect(TransformPoints(node: node, points: [(contour, ids[1])], matrix: .identity, kind: .rotate).label == "Rotate Point")
        let points = a.path(node).contours[0].points
        #expect(points.map(\.anchor) == [Point(x: 0, y: 0), Point(x: 20, y: 0), Point(x: 40, y: 0)])
        #expect(points[1].outHandle == Vector(dx: 4, dy: 0))
        #expect(Objects.transform(of: node, in: a.state) == .identity)
        #expect(throws: ObjectEditError.degenerateTransform) {
            try a.perform(TransformPoints(node: node, points: [(contour, ids[1])], matrix: .scale(0), kind: .scale))
        }
        try a.perform(SetLocked([node], locked: true))
        #expect(try a.perform(TransformPoints(node: node, points: [(contour, ids[1])], matrix: .scale(3), kind: .scale)) == nil)
    }

    @Test func lockedObjectsAreNotMovedTransformedDeletedOrRestacked() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let other = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let lock = try a.perform(SetLocked([rect], locked: true))!
        #expect(lock.label == "Lock")
        #expect(SetLocked([rect, other], locked: false).label == "Unlock 2 objects")
        #expect(try a.perform(MoveObjects([rect], by: Vector(dx: 1, dy: 0))) == nil)
        #expect(try a.perform(TransformObjects([rect], matrix: .scale(2), kind: .scale)) == nil)
        #expect(try a.perform(DeleteNodes([rect])) == nil)
        #expect(try a.perform(Arrange([rect], .bringToFront)) == nil)
        #expect(try a.perform(Ungroup([rect])) == nil)
        // Members of a locked group are locked; Unlock on a member does nothing.
        let m = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let group = try a.perform(GroupObjects([m, other]))!.createdObjects[0]
        try a.perform(SetLocked([group], locked: true))
        #expect(Objects.isInLockedGroup(m, in: a.state))
        #expect(try a.perform(SetLocked([m], locked: false)) == nil)
        #expect(try a.perform(MoveObjects([m], by: Vector(dx: 1, dy: 0))) == nil)
        try a.perform(SetLocked([rect], locked: false))
        #expect(try a.perform(MoveObjects([rect], by: Vector(dx: 1, dy: 0))) != nil)
    }

    @Test func namesAndNotes() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (1, 1)]), on: &a)
        #expect(try a.perform(SetNameOrNote([rect], .name, String(repeating: "n", count: 300)))?.label == "Change name")
        #expect(a.state.props(rect).rect.common.name.count == 256)
        #expect(try a.perform(SetNameOrNote([rect, path], .note, "hello"))?.label == "Change note of 2 objects")
        #expect(a.state.props(path).path.common.note == "hello")
        #expect(throws: ObjectEditError.notAnObject(OpID(counter: 9, replica: 9))) { try Objects.kind(OpID(counter: 9, replica: 9), in: a.state) }
    }

    @Test func boundsAndPaths() throws {
        var a = Replica(0xA)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 10, height: 20), transform: .translation(x: 5, y: 5)), on: &a)
        #expect(Objects.bounds(of: ellipse, in: a.state) == Rect(x: 5, y: 5, width: 10, height: 20))
        let empty = try a.perform(OpsCommand("group", ops: [Ops.create(parent: Objects.parent(of: ellipse, in: a.state)!, position: [0x10], props: {
            var props = Wiretuner_Doc_V1_NodeProps()
            props.group.kind = .group
            return props
        }())]))!.createdNodes[0]
        #expect(Objects.bounds(of: empty, in: a.state) == nil)
        #expect(Objects.localPath(empty, in: a.state) == nil)
        let line = try LayerFixture.object(PathFixture.open([(0, 0)]), on: &a)
        #expect(Objects.bounds(of: line, in: a.state) == nil)
        #expect(Objects.bounds(of: OpID(counter: 99, replica: 1), in: a.state) == nil)
        #expect(Objects.label("Rotate", count: 1) == "Rotate")
    }

    @Test func compositeRunsEachCommandInOneChange() throws {
        var a = Replica(0xA)
        let r1 = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let r2 = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let change = try a.perform(CompositeCommand("Both", [MoveObjects([r1], by: Vector(dx: 1, dy: 0)), SetLocked([r2], locked: true)]))!
        #expect(change.label == "Both" && change.ops.count == 2)
    }
}

/// The merge tests of OBJ-002, OBJ-008, OBJ-020 and OBJ-031.
@Suite struct ObjectMergeTests {
    struct Shared {
        var pair = Pair()
        let node: OpID

        init(_ command: any Command) throws {
            node = try LayerFixture.object(command, on: &pair.a)
            pair.sync()
        }

        func converged() {
            #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        }
    }

    @Test func moveVersusMoveConvergesOnTheGreaterOpIDsMatrixWithTheLoserRetained() throws {
        var s = try Shared(LayerFixture.rect(on: nil))
        let a = try s.pair.a.perform(MoveObjects([s.node], by: Vector(dx: 10, dy: 0)))!
        let b = try s.pair.b.perform(MoveObjects([s.node], by: Vector(dx: 0, dy: 10)))!
        s.pair.sync()
        s.converged()
        let aWins = OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica)
        #expect(Objects.transform(of: s.node, in: s.pair.a.state) == .translation(x: aWins ? 10 : 0, y: aWins ? 0 : 10))
        #expect(s.pair.a.state.store.losingWrites(s.node, CommonFields.transform(.rect)).count == 1)
    }

    @Test func moveAndRemotePointEditBothApply() throws {
        var s = try Shared(PathFixture.open([(0, 0), (10, 0)]))
        let contour = s.pair.a.path(s.node).contours[0]
        try s.pair.a.perform(MoveObjects([s.node], by: Vector(dx: 5, dy: 5)))
        try s.pair.b.perform(MovePoints(node: s.node, contour: contour.id, point: contour.points[1].id, to: Point(x: 20, y: 0)))
        s.pair.sync()
        s.converged()
        #expect(Objects.transform(of: s.node, in: s.pair.a.state) == .translation(x: 5, y: 5))
        #expect(s.pair.a.path(s.node).contours[0].points[1].anchor == Point(x: 20, y: 0))
    }

    @Test func rotateVersusScaleIsOneWholeMatrix() throws {
        var s = try Shared(LayerFixture.rect(on: nil))
        try s.pair.a.perform(TransformObjects([s.node], matrix: .rotation(radians: 0.5), kind: .rotate))
        try s.pair.b.perform(TransformObjects([s.node], matrix: .scale(3), kind: .scale))
        s.pair.sync()
        s.converged()
        let t = Objects.transform(of: s.node, in: s.pair.a.state)
        #expect(nearly(t, .rotation(radians: 0.5)) || nearly(t, .scale(3)))
        #expect(s.pair.a.state.store.losingWrites(s.node, CommonFields.transform(.rect)).count == 1)
    }

    @Test func remoteRotationAndLocalXEditLeaveOneWholeMatrix() throws {
        var s = try Shared(LayerFixture.rect(on: nil))
        try s.pair.a.perform(TransformObjects([s.node], matrix: .rotation(radians: 0.3), kind: .rotate))
        try s.pair.b.perform(MoveObjects([s.node], by: Vector(dx: 40, dy: 0)))
        s.pair.sync()
        s.converged()
        let t = Objects.transform(of: s.node, in: s.pair.a.state)
        #expect(nearly(t, .rotation(radians: 0.3)) || nearly(t, .translation(x: 40, y: 0)))
    }

    @Test func rotateAndPointEditBothApply() throws {
        var s = try Shared(PathFixture.open([(0, 0), (10, 0)]))
        let contour = s.pair.a.path(s.node).contours[0]
        try s.pair.a.perform(TransformObjects([s.node], matrix: .rotation(radians: 1), kind: .rotate))
        try s.pair.b.perform(MovePoints(node: s.node, contour: contour.id, point: contour.points[0].id, to: Point(x: -5, y: 0)))
        s.pair.sync()
        s.converged()
        #expect(nearly(Objects.transform(of: s.node, in: s.pair.a.state), .rotation(radians: 1)))
        #expect(s.pair.a.path(s.node).contours[0].points[0].anchor == Point(x: -5, y: 0))
    }

    @Test func lockVersusRemoteMoveIsMovedAndLocked() throws {
        var s = try Shared(LayerFixture.rect(on: nil))
        try s.pair.a.perform(SetLocked([s.node], locked: true))
        try s.pair.b.perform(MoveObjects([s.node], by: Vector(dx: 3, dy: 0)))
        s.pair.sync()
        s.converged()
        #expect(Objects.isLocked(s.node, in: s.pair.a.state))
        #expect(Objects.transform(of: s.node, in: s.pair.a.state) == .translation(x: 3, y: 0))
    }

    @Test func lockVersusUnlockConvergesByOpID() throws {
        var s = try Shared(LayerFixture.rect(on: nil))
        try s.pair.a.perform(SetLocked([s.node], locked: true))
        s.pair.sync()
        let a = try s.pair.a.perform(SetLocked([s.node], locked: false))!
        let b = try s.pair.b.perform(SetLocked([s.node], locked: true))!
        s.pair.sync()
        s.converged()
        let aWins = OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica)
        #expect(Objects.isLocked(s.node, in: s.pair.a.state) == !aWins)
    }

    @Test func fanOutVersusRemoteEditOfOneIsPerNodeLastWriterWins() throws {
        var pair = Pair()
        let rects = try (0..<3).map { _ in try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a) }
        pair.sync()
        let a = try pair.a.perform(SetCornerRadius(rects, radius: 4))!
        let b = try pair.b.perform(SetCornerRadius([rects[1]], radius: 1, corners: [.topLeft]))!
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // A's write to the second rectangle is its change's second op.
        let aWins = OpID(counter: a.startCounter + 1, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica)
        #expect(pair.a.state.props(rects[1]).rect.corners.topLeft == (aWins ? 4 : 1))
        #expect(pair.a.state.props(rects[0]).rect.corners.topLeft == 4 && pair.a.state.props(rects[2]).rect.corners.bottomLeft == 4)
        #expect(pair.a.state.props(rects[1]).rect.corners.topRight == 4)
        // Undo reverts every register still holding the fanned-out value.
        pair.a.undo()
        #expect(pair.a.state.props(rects[0]).rect.corners.topLeft == 0)
        #expect(pair.a.state.props(rects[1]).rect.corners.topRight == 0)
        #expect(pair.a.state.props(rects[1]).rect.corners.topLeft == (aWins ? 0 : 1))
    }
}
