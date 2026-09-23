import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

private func p(_ x: Double, _ y: Double, in inHandle: Vector = .zero, out outHandle: Vector = .zero, kind: PointKind = .corner) -> VectorPoint {
    VectorPoint(anchor: Point(x: x, y: y), inHandle: inHandle, outHandle: outHandle, kind: kind)
}

/// A replica holding one path; `ids` are the stored point ids.
private struct PathCase {
    var replica = Replica(7)
    var node: OpID
    var contour: OpID
    var ids: [OpID] = []

    init(_ command: CreatePath) throws {
        let change = try replica.perform(command)
        (node, contour) = PathFixture.ids(change, in: replica.state)
        ids = path.contours[0].points.map(\.id)
    }

    init(open coordinates: [(Double, Double)]) throws { try self.init(PathFixture.open(coordinates)) }
    init(closed coordinates: [(Double, Double)]) throws { try self.init(PathFixture.closed(coordinates)) }

    var path: VectorPath { replica.path(node) }
    var drawn: [VectorPoint] { path.contour(contour)!.drawn }

    /// Performs `command`, checks it changed something, undoes it and checks the typed path is back.
    mutating func performAndUndo(_ command: any Command, check: (VectorPath) -> Void = { _ in }) throws {
        let before = path
        let change = try replica.perform(command)
        #expect(change != nil)
        #expect(change?.label == command.label)
        check(path)
        replica.undo()
        #expect(path == before)
    }
}

@Suite struct PathCommandTests {
    @Test func createPathReadsBackWithALayer() throws {
        var replica = Replica(7)
        let change = try replica.perform(PathFixture.open([(0, 0), (10, 0), (10, 10)]))
        #expect(change?.label == "Path")
        let (node, contour) = PathFixture.ids(change, in: replica.state)
        let path = replica.path(node)
        #expect(path.contours.count == 1)
        #expect(path.contours[0].id == contour)
        #expect(PathFixture.anchors(path.contours[0]) == [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10)])
        let layers = replica.state.liveChildren(WellKnown.layers)
        #expect(layers.count == 1)
        #expect(replica.state.props(layers[0]).layer.common.name == "Foreground")
        #expect(replica.state.liveChildren(layers[0]) == [node])
        let props = replica.state.props(node).path
        #expect(props.appearance.strokes.count == 1)
        #expect(props.appearance.strokes[0].settings.basic.width == 1)
        // A second path reuses the layer and goes on top.
        let second = try replica.perform(PathFixture.open([(0, 0), (1, 1)]))!.createdObjects[0]
        #expect(replica.state.liveChildren(WellKnown.layers).count == 1)
        #expect(replica.state.liveChildren(layers[0]) == [node, second])
        // Undo removes the node.
        replica.undo()
        #expect(!replica.state.isLive(second))
    }

    @Test func createPathWithEveryOption() throws {
        var replica = Replica(7)
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        let command = CreatePath(label: "Pen", contours: [NewContour(closed: true, points: [p(0, 0), p(5, 0, out: Vector(dx: 1, dy: 1)), p(5, 5)]), NewContour(points: [])],
                                 appearance: appearance, transform: .translation(x: 3, y: 4), evenOdd: true, fillWhenOpen: true, name: "Mine")
        let change = try replica.perform(command)
        #expect(change?.label == "Pen")
        let node = change!.createdObjects[0]
        let props = replica.state.props(node).path
        #expect(props.common.name == "Mine" && props.evenOdd && props.fillWhenOpen)
        #expect(props.common.transform.tx == 3 && props.common.transform.ty == 4)
        #expect(props.appearance.fills.count == 1 && props.appearance.strokes.isEmpty)
        let path = replica.path(node)
        #expect(path.contours.count == 2 && path.contours[0].closed && path.contours[1].points.isEmpty)
        #expect(path.contours[0].points[1].outHandle == Vector(dx: 1, dy: 1))
        let line = CreatePath.line(from: Point(x: 0, y: 0), to: Point(x: 3, y: 4))
        #expect(line.label == "Line" && line.contours[0].points.count == 2)
        let tooMany = CreatePath(contours: [NewContour(points: Array(repeating: p(0, 0), count: VectorContour.maximumPoints + 1))])
        #expect(throws: PathEditError.contourFull(.zero)) { try replica.perform(tooMany) }
    }

    @Test func drawingLayerSkipsHiddenLockedAndGuideLayers() throws {
        var replica = Replica(7)
        var position: [UInt8] = [0x80]
        func layer(_ build: (inout Wiretuner_Doc_V1_LayerProps) -> Void) -> Wiretuner_Doc_V1_Op {
            var props = Wiretuner_Doc_V1_NodeProps()
            props.layer.visible = true
            build(&props.layer)
            position = try! PathEditing.keys(between: position, and: nil, count: 1)[0]
            return Ops.create(parent: WellKnown.layers, position: position, props: props)
        }
        let visible = try replica.perform(OpsCommand("L", ops: [layer { _ in }]))!.createdNodes[0]
        try replica.perform(OpsCommand("L", ops: [layer { $0.visible = false }]))
        try replica.perform(OpsCommand("L", ops: [layer { $0.locked = true }]))
        try replica.perform(OpsCommand("L", ops: [layer { $0.role = .guides }]))
        // A non-layer child of the layers collection is skipped too.
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group = Wiretuner_Doc_V1_GroupProps()
        try replica.perform(OpsCommand("G", ops: [Ops.create(parent: WellKnown.layers, position: [0xF0], props: group)]))
        #expect(PathEditing.drawingLayer(in: replica.state) == visible)
        let node = try replica.perform(PathFixture.open([(0, 0), (1, 1)]))!.createdObjects[0]
        #expect(replica.state.store.placement(node)?.parent == visible)
    }

    @Test func movePoints() throws {
        var f = try PathCase(open: [(0, 0), (10, 0), (10, 10)])
        let ids = f.ids
        try f.performAndUndo(MovePoints(node: f.node, contour: f.contour, point: ids[1], to: Point(x: 20, y: 5))) { path in
            #expect(path.contours[0].points[1].anchor == Point(x: 20, y: 5))
        }
        let two = MovePoints(node: f.node, moves: [.init(contour: f.contour, point: ids[0], anchor: Point(x: 1, y: 1)),
                                                   .init(contour: f.contour, point: ids[2], anchor: Point(x: 2, y: 2))])
        #expect(two.label == "Move Points")
        try f.performAndUndo(two)
        #expect(throws: PathEditError.invalidValue("anchor")) {
            try f.replica.perform(MovePoints(node: f.node, contour: f.contour, point: ids[0], to: Point(x: .nan, y: 0)))
        }
    }

    @Test func errorsAreThrownBeforeAnythingIsAppended() throws {
        var f = try PathCase(open: [(0, 0), (10, 0)])
        let other = OpID(counter: 999, replica: 9)
        #expect(throws: PathEditError.notAPath(other)) { try f.replica.perform(SetEvenOdd(node: other, evenOdd: true)) }
        #expect(throws: PathEditError.notAPath(WellKnown.layers)) { try f.replica.perform(SetFlatness(node: WellKnown.layers, flatness: 1)) }
        #expect(throws: PathEditError.unknownContour(other)) { try f.replica.perform(SetClosed(node: f.node, closed: true, contours: [other])) }
        #expect(throws: PathEditError.unknownPoint(other)) { try f.replica.perform(MovePoints(node: f.node, contour: f.contour, point: other, to: .zero)) }
        #expect(throws: PathEditError.invalidValue("flatness")) { try f.replica.perform(SetFlatness(node: f.node, flatness: -1)) }
        // A deleted path is not a path.
        try f.replica.perform(DeleteNodes([f.node]))
        #expect(throws: PathEditError.notAPath(f.node)) { try f.replica.perform(ReverseContours(node: f.node)) }
    }

    @Test func setHandlesTandemAndIndependent() throws {
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0, in: Vector(dx: -2, dy: 0), out: Vector(dx: 2, dy: 0), kind: .curve), p(20, 0)])]))
        let mid = f.ids[1]
        // Curve: moving the leaving handle swings the arriving one opposite, keeping its length.
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: mid, out: Vector(dx: 0, dy: 4))) { path in
            let point = path.contours[0].points[1]
            #expect(point.outHandle == Vector(dx: 0, dy: 4))
            #expect(point.inHandle.isApproximatelyEqual(to: Vector(dx: 0, dy: -2)))
        }
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: mid, in: Vector(dx: -3, dy: 0))) { path in
            #expect(path.contours[0].points[1].outHandle.isApproximatelyEqual(to: Vector(dx: 2, dy: 0)))
        }
        // Unlinked: only the given handle.
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: mid, out: Vector(dx: 0, dy: 4), linked: false)) { path in
            #expect(path.contours[0].points[1].inHandle == Vector(dx: -2, dy: 0))
        }
        // Both given: written as given; a zero handle retracts.
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: mid, in: .zero, out: Vector(dx: 1, dy: 0))) { path in
            #expect(path.contours[0].points[1].inHandle == .zero)
        }
        // A corner point's handles are independent even when linked.
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: f.ids[0], out: Vector(dx: 1, dy: 1))) { path in
            #expect(path.contours[0].points[0].inHandle == .zero)
        }
        #expect(throws: PathEditError.invalidValue("handle")) {
            try f.replica.perform(SetHandles(node: f.node, contour: f.contour, point: mid, out: Vector(dx: .infinity, dy: 0)))
        }
        #expect(SetHandles.opposite(.zero, length: 3) == .zero)
        // Neither handle given: nothing to write.
        #expect(try f.replica.perform(SetHandles(node: f.node, contour: f.contour, point: f.ids[0])) == nil)
    }

    @Test func curveHandleFromARetractedOppositeMirrors() throws {
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0, kind: .curve), p(20, 0)])]))
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: f.ids[1], out: Vector(dx: 3, dy: 4))) { path in
            #expect(path.contours[0].points[1].inHandle.isApproximatelyEqual(to: Vector(dx: -3, dy: -4)))
        }
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: f.ids[1], in: Vector(dx: 3, dy: 4))) { path in
            #expect(path.contours[0].points[1].outHandle.isApproximatelyEqual(to: Vector(dx: -3, dy: -4)))
        }
    }

    @Test func connectorHandlesStayOnTheStraightSide() throws {
        // Straight segment arriving from the left; the leaving handle is projected onto +x.
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0, out: Vector(dx: 2, dy: 0), kind: .connector), p(20, 10, in: Vector(dx: -1, dy: 0))])]))
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: f.ids[1], in: Vector(dx: 5, dy: 5), out: Vector(dx: 3, dy: 3))) { path in
            let point = path.contours[0].points[1]
            #expect(point.outHandle == Vector(dx: 3, dy: 0))
            #expect(point.inHandle == .zero)
        }
        // Straight segment leaving to the right: the arriving handle is projected onto -x.
        var g = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 10, out: Vector(dx: 1, dy: 0)), p(10, 0, in: Vector(dx: -2, dy: 0), kind: .connector), p(20, 0)])]))
        try g.performAndUndo(SetHandles(node: g.node, contour: g.contour, point: g.ids[1], in: Vector(dx: -4, dy: 2), out: Vector(dx: 1, dy: 1))) { path in
            let point = path.contours[0].points[1]
            #expect(point.inHandle == Vector(dx: -4, dy: 0))
            #expect(point.outHandle == .zero)
        }
        // Neither side straight: as given.
        var h = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0, out: Vector(dx: 1, dy: 0)), p(10, 0, in: Vector(dx: -1, dy: 0), out: Vector(dx: 1, dy: 0), kind: .connector), p(20, 0, in: Vector(dx: -1, dy: 0))])]))
        try h.performAndUndo(SetHandles(node: h.node, contour: h.contour, point: h.ids[1], out: Vector(dx: 1, dy: 1))) { path in
            #expect(path.contours[0].points[1].outHandle == Vector(dx: 1, dy: 1))
        }
    }

    @Test func draggingAnAutomaticPointsHandleClearsAutomatic() throws {
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), VectorPoint(anchor: Point(x: 10, y: 5), kind: .curve, automatic: true), p(20, 0)])]))
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: f.ids[1], out: Vector(dx: 2, dy: 0))) { path in
            #expect(!path.contours[0].points[1].automatic)
        }
    }

    @Test func handlesOnAReversedContourAreStoredSwapped() throws {
        var f = try PathCase(open: [(0, 0), (10, 0), (20, 0)])
        try f.replica.perform(ReverseContours(node: f.node))
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: f.ids[1], out: Vector(dx: -3, dy: 0))) { path in
            let stored = path.contours[0].points[1]
            #expect(stored.inHandle == Vector(dx: -3, dy: 0))
            #expect(path.contours[0].drawn[1].outHandle == Vector(dx: -3, dy: 0))
        }
        try f.performAndUndo(SetHandles(node: f.node, contour: f.contour, point: f.ids[1], in: Vector(dx: 3, dy: 0))) { path in
            #expect(path.contours[0].points[1].outHandle == Vector(dx: 3, dy: 0))
        }
    }

    @Test func pointKindsAndRelinking() throws {
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0, in: Vector(dx: 0, dy: 2), out: Vector(dx: 3, dy: 0)), p(20, 0)])]))
        let mid = f.ids[1]
        try f.performAndUndo(SetPointKind(node: f.node, points: [(f.contour, mid)], kind: .curve)) { path in
            let point = path.contours[0].points[1]
            #expect(point.kind == .curve)
            #expect(point.inHandle.isApproximatelyEqual(to: Vector(dx: -2, dy: 0)))
            #expect(!point.handlesUnlinked)
        }
        try f.performAndUndo(SetPointKind(node: f.node, points: [(f.contour, mid)], kind: .connector)) { path in
            #expect(path.contours[0].points[1].inHandle == Vector(dx: 0, dy: 2))
        }
        // One retracted handle: mirrored from the other.
        var g = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0, in: Vector(dx: -4, dy: 0)), p(20, 0)])]))
        try g.performAndUndo(SetPointKind(node: g.node, points: [(g.contour, g.ids[1])], kind: .curve)) { path in
            #expect(path.contours[0].points[1].outHandle.isApproximatelyEqual(to: Vector(dx: 4, dy: 0)))
        }
        // Both retracted: only the kind changes.
        try g.performAndUndo(SetPointKind(node: g.node, points: [(g.contour, g.ids[0])], kind: .curve)) { path in
            #expect(path.contours[0].points[0].outHandle == .zero && path.contours[0].points[0].kind == .curve)
        }
    }

    @Test func retractAndAutomatic() throws {
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 5, in: Vector(dx: -1, dy: 0), out: Vector(dx: 1, dy: 0)), p(20, 0)])]))
        try f.performAndUndo(RetractHandles(node: f.node, points: [(f.contour, f.ids[1])])) { path in
            #expect(path.contours[0].points[1].inHandle == .zero && path.contours[0].points[1].outHandle == .zero)
        }
        try f.performAndUndo(SetAutomatic(node: f.node, points: [(f.contour, f.ids[1])], automatic: true)) { path in
            #expect(path.contours[0].points[1].automatic)
            #expect(path.contours[0].drawn[1].outHandle == Vector(dx: 20.0 / 6, dy: -5.0 / 6 + 5.0 / 6))
        }
        try f.replica.perform(SetAutomatic(node: f.node, points: [(f.contour, f.ids[1])], automatic: true))
        try f.performAndUndo(SetAutomatic(node: f.node, points: [(f.contour, f.ids[1])], automatic: false)) { path in
            let point = path.contours[0].points[1]
            #expect(!point.automatic)
            #expect(point.outHandle == Vector(dx: 20.0 / 6, dy: 0))
        }
    }

    @Test func insertPointsAtEveryPlacement() throws {
        var f = try PathCase(open: [(0, 0), (10, 0), (20, 0)])
        let ids = f.ids
        func anchors(_ path: VectorPath) -> [Double] { path.contours[0].drawn.map(\.anchor.x) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .end, points: [p(30, 0), p(40, 0)])) { #expect(anchors($0) == [0, 10, 20, 30, 40]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .start, points: [p(-20, 0), p(-10, 0)])) { #expect(anchors($0) == [-20, -10, 0, 10, 20]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .after(ids[0]), points: [p(5, 0)])) { #expect(anchors($0) == [0, 5, 10, 20]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .before(ids[0]), points: [p(-5, 0)])) { #expect(anchors($0) == [-5, 0, 10, 20]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .after(ids[2]), points: [p(25, 0)])) { #expect(anchors($0) == [0, 10, 20, 25]) }
        // Nothing to insert: no change.
        #expect(try f.replica.perform(InsertPoints(node: f.node, contour: f.contour, at: .end, points: [])) == nil)
        let unknown = OpID(counter: 999, replica: 9)
        #expect(throws: PathEditError.unknownPoint(unknown)) { try f.replica.perform(InsertPoints(node: f.node, contour: f.contour, at: .after(unknown), points: [p(1, 1)])) }
        #expect(throws: PathEditError.unknownPoint(unknown)) { try f.replica.perform(InsertPoints(node: f.node, contour: f.contour, at: .before(unknown), points: [p(1, 1)])) }
    }

    @Test func insertPointsOnAReversedContourKeepDrawingOrder() throws {
        var f = try PathCase(open: [(0, 0), (10, 0), (20, 0)])
        let ids = f.ids
        try f.replica.perform(ReverseContours(node: f.node))
        func anchors(_ path: VectorPath) -> [Double] { path.contours[0].drawn.map(\.anchor.x) }
        #expect(anchors(f.path) == [20, 10, 0])
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .end, points: [p(-10, 0, out: Vector(dx: -1, dy: 0)), p(-20, 0)])) { path in
            #expect(anchors(path) == [20, 10, 0, -10, -20])
            #expect(path.contours[0].drawn[3].outHandle == Vector(dx: -1, dy: 0))
        }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .start, points: [p(30, 0)])) { #expect(anchors($0) == [30, 20, 10, 0]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .after(ids[1]), points: [p(5, 0)])) { #expect(anchors($0) == [20, 10, 5, 0]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .before(ids[1]), points: [p(15, 0)])) { #expect(anchors($0) == [20, 15, 10, 0]) }
    }

    @Test func insertPointsOnAStartRotatedContourAndIntoAnEmptyOne() throws {
        var f = try PathCase(closed: [(0, 0), (10, 0), (20, 0), (30, 0)])
        try f.replica.perform(DeleteSegment(node: f.node, contour: f.contour, from: f.ids[1]))   // opens: 20, 30, 0, 10
        func anchors(_ path: VectorPath) -> [Double] { path.contours[0].drawn.map(\.anchor.x) }
        #expect(anchors(f.path) == [20, 30, 0, 10])
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .end, points: [p(15, 0)])) { #expect(anchors($0) == [20, 30, 0, 10, 15]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .start, points: [p(17, 0)])) { #expect(anchors($0) == [17, 20, 30, 0, 10]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .before(f.ids[2]), points: [p(18, 0), p(19, 0)])) { #expect(anchors($0) == [18, 19, 20, 30, 0, 10]) }
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .after(f.ids[3]), points: [p(35, 0)])) { #expect(anchors($0) == [20, 30, 35, 0, 10]) }
        // Reversed and rotated: prepending moves the start to the new drawn-first point.
        var r = try PathCase(closed: [(0, 0), (10, 0), (20, 0), (30, 0)])
        try r.replica.perform(ReverseContours(node: r.node))
        try r.replica.perform(DeleteSegment(node: r.node, contour: r.contour, from: r.ids[2]))
        #expect(anchors(r.path) == [10, 0, 30, 20])
        try r.performAndUndo(InsertPoints(node: r.node, contour: r.contour, at: .start, points: [p(11, 0), p(12, 0)])) { #expect(anchors($0) == [11, 12, 10, 0, 30, 20]) }
        // A contour whose points are all deleted takes inserts after its tombstones.
        try f.replica.perform(DeletePoints(node: f.node, points: f.ids.map { (f.contour, $0) }))
        try f.performAndUndo(InsertPoints(node: f.node, contour: f.contour, at: .start, points: [p(1, 0), p(2, 0)])) { #expect(anchors($0) == [1, 2]) }
        // A contour that never had points.
        var g = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(1, 0)]), NewContour(points: [])]))
        let empty = g.path.contours[1].id
        try g.performAndUndo(InsertPoints(node: g.node, contour: empty, at: .end, points: [p(5, 5)])) { #expect($0.contours[1].points.count == 1) }
    }

    @Test func aFullContourRefusesInserts() throws {
        // Checked before any state is read, so a synthetic contour suffices.
        let full = VectorContour(id: OpID(counter: 5, replica: 1), points: Array(repeating: p(0, 0), count: VectorContour.maximumPoints))
        #expect(full.isFull)
        #expect(throws: PathEditError.contourFull(full.id)) {
            try PathEditing.insert([p(1, 1)], into: full, of: .zero, at: .end, state: EngineState())
        }
    }

    @Test func insertPointOnSegmentKeepsTheCurve() throws {
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0, out: Vector(dx: 0, dy: -10)), p(30, 0, in: Vector(dx: 0, dy: -10))])]))
        let original = f.path.contours[0].segments[0].cubic
        try f.performAndUndo(InsertPointOnSegment(node: f.node, contour: f.contour, from: f.ids[0], t: 0.5)) { path in
            let contour = path.contours[0]
            #expect(contour.points.count == 3)
            let segments = contour.segments
            #expect(segments[0].to.anchor.isApproximatelyEqual(to: original.evaluate(0.5)))
            #expect(segments[0].cubic.evaluate(0.5).isApproximatelyEqual(to: original.evaluate(0.25), tolerance: 1e-9))
            #expect(segments[1].cubic.evaluate(0.5).isApproximatelyEqual(to: original.evaluate(0.75), tolerance: 1e-9))
            #expect(segments[0].to.kind == .curve)
        }
        var line = try PathCase(open: [(0, 0), (10, 0)])
        try line.performAndUndo(InsertPointOnSegment(node: line.node, contour: line.contour, from: line.ids[0], t: 0.25)) { path in
            #expect(path.contours[0].drawn.map(\.anchor.x) == [0, 2.5, 10])
            #expect(path.contours[0].drawn[1].kind == .corner)
        }
        #expect(throws: PathEditError.invalidValue("t")) { try line.replica.perform(InsertPointOnSegment(node: line.node, contour: line.contour, from: line.ids[0], t: 1)) }
        #expect(throws: PathEditError.unknownPoint(line.ids[1])) { try line.replica.perform(InsertPointOnSegment(node: line.node, contour: line.contour, from: line.ids[1], t: 0.5)) }
    }

    @Test func deletePoints() throws {
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(10, 0), p(20, 0)]), NewContour(points: [p(0, 5), p(10, 5)])]))
        let second = f.path.contours[1]
        let one = DeletePoints(node: f.node, points: [(f.contour, f.ids[1])])
        #expect(one.label == "Delete Point")
        try f.performAndUndo(one) { #expect($0.contours[0].points.count == 2) }
        let many = DeletePoints(node: f.node, points: [(f.contour, f.ids[0]), (second.id, second.points[0].id), (f.contour, f.ids[2])])
        #expect(many.label == "Delete Points")
        try f.performAndUndo(many) { path in
            #expect(path.contours[0].points.count == 1 && !path.contours[1].isRenderable)
        }
    }

    @Test func deleteSegmentOpensSplitsOrTrims() throws {
        var closed = try PathCase(closed: [(0, 0), (10, 0), (10, 10), (0, 10)])
        let closedIDs = closed.ids
        try closed.performAndUndo(DeleteSegment(node: closed.node, contour: closed.contour, from: closedIDs[3])) { path in
            let contour = path.contours[0]
            #expect(!contour.closed && contour.start == closedIDs[0])
            #expect(contour.drawn.map(\.id) == closedIDs)
        }
        var open = try PathCase(open: [(0, 0), (10, 0), (20, 0), (30, 0), (40, 0)])
        try open.performAndUndo(DeleteSegment(node: open.node, contour: open.contour, from: open.ids[0])) { #expect($0.contours[0].drawn.map(\.anchor.x) == [10, 20, 30, 40]) }
        try open.performAndUndo(DeleteSegment(node: open.node, contour: open.contour, from: open.ids[3])) { #expect($0.contours[0].drawn.map(\.anchor.x) == [0, 10, 20, 30]) }
        try open.performAndUndo(DeleteSegment(node: open.node, contour: open.contour, from: open.ids[1])) { path in
            #expect(path.contours.count == 2)
            #expect(path.contours[0].drawn.map(\.anchor.x) == [0, 10])
            #expect(path.contours[1].drawn.map(\.anchor.x) == [20, 30, 40])
        }
        #expect(throws: PathEditError.unknownPoint(open.ids[4])) { try open.replica.perform(DeleteSegment(node: open.node, contour: open.contour, from: open.ids[4])) }
    }

    @Test func closedEvenOddFlatnessAndReverse() throws {
        var f = try PathCase(CreatePath(contours: [NewContour(points: [p(0, 0), p(1, 0)]), NewContour(closed: true, points: [p(0, 5), p(1, 5)])]))
        let close = SetClosed(node: f.node, closed: true)
        #expect(close.label == "Close Path")
        try f.performAndUndo(close) { #expect($0.contours.allSatisfy { $0.closed }) }
        let open = SetClosed(node: f.node, closed: false, contours: [f.path.contours[1].id])
        #expect(open.label == "Open Path")
        try f.performAndUndo(open) { #expect(!$0.contours[1].closed) }
        try f.performAndUndo(SetEvenOdd(node: f.node, evenOdd: true)) { #expect($0.evenOdd) }
        try f.performAndUndo(SetFlatness(node: f.node, flatness: 3)) { #expect($0.flatness == 3) }
        try f.performAndUndo(ReverseContours(node: f.node)) { #expect($0.contours.allSatisfy { $0.reversed }) }
        let contour = f.contour
        try f.performAndUndo(ReverseContours(node: f.node, contours: [contour])) { #expect($0.contours[0].reversed && !$0.contours[1].reversed) }
    }

    @Test func joinAppendsOrPrependsInTheRightDirection() throws {
        for (targetEnd, sourceEnd, expected) in [
            (ContourEnd.end, ContourEnd.start, [0.0, 10, 100, 110]),
            (.end, .end, [0, 10, 110, 100]),
            (.start, .end, [100, 110, 0, 10]),
            (.start, .start, [110, 100, 0, 10]),
        ] {
            var replica = Replica(3)
            let (target, targetContour) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0)])), in: replica.state)
            let sourceCommand = CreatePath(contours: [NewContour(points: [p(0, 0, out: Vector(dx: 1, dy: 0)), p(10, 0)])], transform: .translation(x: 100, y: 0))
            let (source, sourceContour) = PathFixture.ids(try replica.perform(sourceCommand), in: replica.state)
            let before = replica.path(target)
            let join = JoinPaths(target: target, targetContour: targetContour, targetEnd: targetEnd, source: source, sourceContour: sourceContour, sourceEnd: sourceEnd)
            #expect(try replica.perform(join)?.label == "Join")
            #expect(replica.path(target).contours[0].drawn.map(\.anchor.x) == expected)
            #expect(!replica.state.isLive(source))
            replica.undo()
            #expect(replica.path(target) == before && replica.state.isLive(source))
        }
    }

    @Test func joinRefusals() throws {
        var replica = Replica(3)
        let (target, targetContour) = PathFixture.ids(try replica.perform(PathFixture.open([(0, 0), (10, 0)])), in: replica.state)
        let (closed, closedContour) = PathFixture.ids(try replica.perform(PathFixture.closed([(0, 0), (10, 0), (5, 5)])), in: replica.state)
        #expect(throws: PathEditError.invalidValue("join a path to itself")) {
            try replica.perform(JoinPaths(target: target, targetContour: targetContour, targetEnd: .end, source: target, sourceContour: targetContour, sourceEnd: .start))
        }
        #expect(throws: PathEditError.invalidValue("closed contour")) {
            try replica.perform(JoinPaths(target: target, targetContour: targetContour, targetEnd: .end, source: closed, sourceContour: closedContour, sourceEnd: .start))
        }
    }

    @Test func splitOpenAndClosed() throws {
        var open = try PathCase(open: [(0, 0), (10, 0), (20, 0), (30, 0)])
        let before = open.path
        let change = try open.replica.perform(SplitPath(node: open.node, contour: open.contour, point: open.ids[1]))
        #expect(change?.label == "Split")
        #expect(open.drawn.map(\.anchor.x) == [0, 10])
        let copy = change!.createdObjects[0]
        #expect(open.replica.path(copy).contours[0].drawn.map(\.anchor.x) == [10, 20, 30])
        #expect(open.replica.state.props(copy).path.appearance.strokes.count == 1)
        open.replica.undo()
        #expect(open.path == before && !open.replica.state.isLive(copy))
        // At an end: nothing to do.
        #expect(try open.replica.perform(SplitPath(node: open.node, contour: open.contour, point: open.ids[0])) == nil)
        #expect(throws: PathEditError.unknownPoint(open.node)) { try open.replica.perform(SplitPath(node: open.node, contour: open.contour, point: open.node)) }

        var closed = try PathCase(closed: [(0, 0), (10, 0), (10, 10)])
        try closed.performAndUndo(SplitPath(node: closed.node, contour: closed.contour, point: closed.ids[1])) { path in
            let contour = path.contours[0]
            #expect(!contour.closed)
            #expect(contour.drawn.map(\.anchor) == [Point(x: 10, y: 0), Point(x: 10, y: 10), Point(x: 0, y: 0), Point(x: 10, y: 0)])
        }
    }
}

@Suite struct NodeCommandTests {
    @Test func createShapes() throws {
        var replica = Replica(4)
        let radii = CornerRadii(topLeft: 1, topRight: 2, bottomRight: 3, bottomLeft: 4)
        let size = Size(width: 20, height: 10)
        let rect = CreateShape(.rectangle(radii), size: size, transform: AffineTransform.translation(x: 5, y: 6))
        #expect(rect.label == "Rectangle")
        let node = try replica.perform(rect)!.createdObjects[0]
        let props = replica.state.props(node).rect
        #expect(props.size.width == 20 && !props.corners.uniform && props.corners.bottomLeft == 4)
        #expect(props.common.transform.tx == 5 && props.appearance.strokes.count == 1)
        let ellipse = CreateShape(.ellipse, size: Size(width: 3, height: 4))
        #expect(ellipse.label == "Ellipse")
        let other = try replica.perform(ellipse)!.createdObjects[0]
        #expect(replica.state.props(other).ellipse.size.height == 4)
        #expect(replica.state.props(other).ellipse.common.transform == Wiretuner_Doc_V1_Transform())
        let ellipseMoved = try replica.perform(CreateShape(.ellipse, size: Size(width: 3, height: 4), transform: .translation(x: 1, y: 0)))!.createdObjects[0]
        #expect(replica.state.props(ellipseMoved).ellipse.common.transform.tx == 1)
        #expect(throws: PathEditError.invalidValue("size")) { try replica.perform(CreateShape(.ellipse, size: Size(width: 0, height: 4))) }
        replica.undo()
        #expect(!replica.state.isLive(ellipseMoved))
    }

    @Test func transformsSizesAndDeletes() throws {
        var replica = Replica(4)
        let rect = try replica.perform(CreateShape(.rectangle(.uniform(0)), size: Size(width: 20, height: 10)))!.createdObjects[0]
        let ellipse = try replica.perform(CreateShape(.ellipse, size: Size(width: 20, height: 10)))!.createdObjects[0]
        let path = try replica.perform(PathFixture.open([(0, 0), (1, 1)]))!.createdObjects[0]
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group = Wiretuner_Doc_V1_GroupProps()
        let layer = replica.state.liveChildren(WellKnown.layers)[0]
        let groupNode = try replica.perform(OpsCommand("G", ops: [Ops.create(parent: layer, position: [0xF0], props: group)]))!.createdNodes[0]
        let move = SetTransforms([(rect, .translation(x: 1, y: 2)), (ellipse, .translation(x: 3, y: 0)), (path, .scale(2)), (groupNode, .translation(x: 0, y: 9))])
        #expect(move.label == "Move")
        try replica.perform(move)
        #expect(replica.state.props(rect).rect.common.transform.ty == 2)
        #expect(replica.state.props(ellipse).ellipse.common.transform.tx == 3)
        #expect(replica.state.props(path).path.common.transform.a == 2)
        #expect(replica.state.props(groupNode).group.common.transform.ty == 9)
        try replica.perform(SetTransforms([(rect, .identity)], label: "Reset"))
        #expect(replica.state.props(rect).rect.common.transform == Wiretuner_Doc_V1_Transform())
        replica.undo()
        #expect(replica.state.props(rect).rect.common.transform.ty == 2)
        #expect(throws: PathEditError.notAPath(layer)) { try replica.perform(SetTransforms([(layer, .identity)])) }

        let resize = SetShapeSize(node: rect, size: Size(width: 5, height: 6))
        #expect(resize.label == "Resize")
        try replica.perform(resize)
        try replica.perform(SetShapeSize(node: ellipse, size: Size(width: 7, height: 8)))
        #expect(replica.state.props(rect).rect.size.height == 6 && replica.state.props(ellipse).ellipse.size.width == 7)
        #expect(throws: PathEditError.notAPath(path)) { try replica.perform(SetShapeSize(node: path, size: Size(width: 1, height: 1))) }
        #expect(throws: PathEditError.invalidValue("size")) { try replica.perform(SetShapeSize(node: rect, size: Size(width: -1, height: 1))) }

        let delete = DeleteNodes([rect, WellKnown.layers, OpID(counter: 999, replica: 9)])
        #expect(delete.label == "Delete")
        #expect(try replica.perform(delete)?.ops.count == 1)
        #expect(!replica.state.isLive(rect))
        #expect(try replica.perform(DeleteNodes([rect])) == nil)
        replica.undo()
        #expect(replica.state.isLive(rect))
    }

    @Test func changeHelpersNameWhatAChangeCreated() throws {
        var replica = Replica(4)
        let change = try replica.perform(CreatePath(contours: [NewContour(points: [p(0, 0), p(1, 0), p(2, 0)])]))!
        #expect(change.createdNodes.count == 2)   // the layer, then the path
        #expect(change.createdObjects.count == 1 && change.createdObjects[0] == change.createdNodes[1])
        #expect(change.opIDs.count == change.ops.count)
        #expect(change.opIDs[0] == OpID(counter: change.startCounter, replica: change.replica))
        let node = change.createdObjects[0]
        let contours = change.insertedElements(node, PathFields.contours)
        #expect(contours.count == 1)
        #expect(change.insertedElements(node, PathFields.points(contours[0])) == replica.path(node).contours[0].points.map(\.id))
        #expect(change.insertedElements(OpID(counter: 1, replica: 1), PathFields.contours).isEmpty)
    }
}
