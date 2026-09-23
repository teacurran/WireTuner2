import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// NodeCopier, the clipboard payload, Paste (and In Front / Behind), Cut, Clone, Duplicate and the
/// duplicate memory (OBJ-010, OBJ-011, OBJ-012).
@Suite struct ClipboardTests {
    /// Everything a document can hold now: a styled path with two contours, a rectangle with radii,
    /// an ellipse, a star and a group of two with a clip path.
    static func corpus(on a: inout Replica) throws -> [OpID] {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        var path = CreatePath(contours: [
            NewContour(closed: true, points: PathFixture.points([(0, 0), (10, 0), (10, 10)])),
            NewContour(points: [VectorPoint(anchor: Point(x: 20, y: 0), outHandle: Vector(dx: 5, dy: 0), kind: .curve),
                                VectorPoint(anchor: Point(x: 30, y: 10), automatic: true)]),
        ], appearance: appearance, transform: .translation(x: 5, y: 5), evenOdd: true, name: "Path")
        path.fillWhenOpen = true
        let pathID = try LayerFixture.object(path, on: &a)
        let rect = try LayerFixture.object(CreateShape(.rectangle(CornerRadii(topLeft: 2, topRight: 3)), size: Size(width: 20, height: 10)), on: &a)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 8, height: 4)), on: &a)
        let star = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 10, autoInner: true), center: Point(x: 50, y: 50)), on: &a)
        let m1 = try LayerFixture.object(LayerFixture.rect(on: nil, x: 100), on: &a)
        let m2 = try LayerFixture.object(PathFixture.closed([(100, 0), (110, 0), (110, 10)]), on: &a)
        let group = try a.perform(GroupObjects([m1, m2]))!.createdObjects[0]
        var clip = Wiretuner_Doc_V1_NodeProps()
        clip.group.clipPath.id = m2.proto
        try a.perform(OpsCommand("clip", ops: [Ops.set(group, [RegisterPath([50, 4])], values: clip)]))
        return [pathID, rect, ellipse, star, group]
    }

    /// The node's props with every element id and `clip_path` cleared, for comparing copies.
    static func normalized(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_NodeProps {
        var props = props
        func clear(_ appearance: inout Wiretuner_Doc_V1_AppearanceProps) {
            for i in appearance.fills.indices { appearance.fills[i].clearID() }
            for i in appearance.strokes.indices { appearance.strokes[i].clearID() }
        }
        switch props.kind {
        case .path?:
            for c in props.path.contours.indices {
                props.path.contours[c].clearID()
                for p in props.path.contours[c].points.indices { props.path.contours[c].points[p].clearID() }
            }
            clear(&props.path.appearance)
        case .rect?: clear(&props.rect.appearance)
        case .ellipse?: clear(&props.ellipse.appearance)
        case .polygon?: clear(&props.polygon.appearance)
        case .group?: props.group.clearClipPath(); clear(&props.group.appearance)
        default: break
        }
        return props
    }

    @Test func everyKindRoundTripsLosslesslyExceptIDs() throws {
        var a = Replica(0xA)
        let corpus = try Self.corpus(on: &a)
        let payload = ClipboardPayload(copying: corpus, from: a.state, document: "doc-1")
        let decoded = try #require(ClipboardPayload(decoding: payload.encoded()))
        #expect(decoded == payload)
        #expect(payload.sourceDocument == "doc-1")
        #expect(payload.layerNames == Array(repeating: "Foreground", count: 5))
        #expect(payload.bounds != nil)
        var b = Replica(0xB)
        let change = try b.perform(Paste(decoded))!
        #expect(change.label == "Paste 5 objects")
        let pasted = change.createdRoots
        #expect(pasted.count == 5)
        for (source, copy) in zip(corpus, pasted) {
            #expect(source != copy)
            #expect(Self.normalized(b.state.props(copy)) == Self.normalized(a.state.props(source)))
            #expect(NodeTree(copy, state: b.state).flattened.count == NodeTree(source, state: a.state).flattened.count)
        }
        // The clip path points at the copied member.
        let group = pasted[4]
        let clip = OpID(b.state.props(group).group.clipPath.id)
        #expect(b.state.liveChildren(group).contains(clip))
    }

    @Test func pastedNodesAreIndependentOfTheSource() throws {
        var a = Replica(0xA)
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (10, 0)]), on: &a)
        let payload = ClipboardPayload(copying: [path], from: a.state)
        let copy = try a.perform(Paste(payload))!.createdRoots[0]
        let contour = a.path(path).contours[0]
        try a.perform(MovePoints(node: path, contour: contour.id, point: contour.points[0].id, to: Point(x: 3, y: 3)))
        #expect(a.path(copy).contours[0].points[0].anchor == Point(x: 0, y: 0))
        #expect(Paste(payload).label == "Paste")
    }

    @Test func pasteCentresOnTheViewAndTakesTheActiveLayer() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Base", "Top"], on: &a)
        let rect = try LayerFixture.object(LayerFixture.rect(on: layers[1], x: 0, size: 10), on: &a)
        let payload = ClipboardPayload(copying: [rect], from: a.state)
        let copy = try a.perform(Paste(payload, placement: .top(layer: layers[0], center: Point(x: 100, y: 100))))!.createdRoots[0]
        #expect(Objects.parent(of: copy, in: a.state) == layers[0])
        #expect(Objects.bounds(of: copy, in: a.state) == Rect(x: 95, y: 95, width: 10, height: 10))
        // An empty payload pastes nothing.
        #expect(try a.perform(Paste(ClipboardPayload(nodes: []))) == nil)
    }

    @Test func rememberLayerInfoFindsOrCreatesTheLayerByName() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Art", "Notes"], on: &a)
        let onNotes = try LayerFixture.object(LayerFixture.rect(on: layers[1]), on: &a)
        let payload = ClipboardPayload(copying: [onNotes], from: a.state)
        var b = Replica(0xB)
        _ = try LayerFixture.layers(["Art"], on: &b)
        let change = try b.perform(Paste(payload, placement: .top(layer: nil, center: nil), rememberLayerInfo: true))!
        let notes = LayerOrder(b.state).layers.first { $0.name == "Notes" }
        #expect(notes != nil)
        #expect(Objects.parent(of: change.createdRoots[0], in: b.state) == notes?.id)
        // Pasting again finds it.
        let again = try b.perform(Paste(payload, rememberLayerInfo: true))!
        #expect(again.createdNodes.count == 1)
        #expect(Objects.parent(of: again.createdRoots[0], in: b.state) == notes?.id)
        // Two copies from the same missing layer create it once.
        var c = Replica(0xC)
        let twice = ClipboardPayload(nodes: payload.nodes + payload.nodes, layerNames: ["Notes", "Notes"])
        let created = try c.perform(Paste(twice, rememberLayerInfo: true))!
        #expect(LayerOrder(c.state).layers.filter { $0.name == "Notes" }.count == 1)
        #expect(created.createdRoots.count == 2)
    }

    @Test func pasteInFrontAndBehindAGroupMember() throws {
        var a = Replica(0xA)
        let m1 = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let m2 = try LayerFixture.object(LayerFixture.rect(on: nil, x: 20), on: &a)
        let group = try a.perform(GroupObjects([m1, m2]))!.createdObjects[0]
        let other = try LayerFixture.object(LayerFixture.rect(on: nil, x: 40), on: &a)
        let payload = ClipboardPayload(copying: [other], from: a.state)
        let front = try a.perform(Paste(payload, placement: .inFront(of: m1)))!.createdRoots[0]
        #expect(a.state.liveChildren(group) == [m1, front, m2])
        let behind = try a.perform(Paste(payload, placement: .behind(m1)))!.createdRoots[0]
        #expect(a.state.liveChildren(group) == [behind, m1, front, m2])
        // At the copied position, in the group's space.
        #expect(Objects.bounds(of: front, in: a.state) == Objects.bounds(of: other, in: a.state))
        // In a clip group, never below the clip path.
        var clip = Wiretuner_Doc_V1_NodeProps()
        clip.group.kind = .clip
        clip.group.clipPath.id = behind.proto
        try a.perform(OpsCommand("clip", ops: [Ops.set(group, [RegisterPath([50, 2]), RegisterPath([50, 4])], values: clip)]))
        let below = try a.perform(Paste(payload, placement: .behind(behind)))!.createdRoots[0]
        #expect(a.state.liveChildren(group).prefix(2) == [behind, below])
        #expect(throws: ObjectEditError.notAnObject(OpID(counter: 99, replica: 9))) {
            try a.perform(Paste(payload, placement: .inFront(of: OpID(counter: 99, replica: 9))))
        }
    }

    @Test func cutDeletesAndSkipsLockedObjects() throws {
        var a = Replica(0xA)
        let one = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let two = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        try a.perform(SetLocked([two], locked: true))
        let change = try a.perform(CutObjects([one, two]))!
        #expect(change.label == "Cut")
        #expect(!a.state.isLive(one) && a.state.isLive(two))
    }

    @Test func cloneAndDuplicateSitAboveTheSource() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let above = try LayerFixture.object(LayerFixture.rect(on: nil, x: 50), on: &a)
        let clone = try a.perform(DuplicateObjects.clone([rect]))!
        #expect(clone.label == "Clone")
        let cloned = clone.createdRoots[0]
        #expect(Objects.bounds(of: cloned, in: a.state) == Objects.bounds(of: rect, in: a.state))
        let duplicate = try a.perform(DuplicateObjects.duplicate([rect]))!
        #expect(duplicate.label == "Duplicate")
        let copy = duplicate.createdRoots[0]
        #expect(Objects.bounds(of: copy, in: a.state) == Rect(x: 10, y: 10, width: 10, height: 10))
        let layer = Objects.parent(of: rect, in: a.state)!
        #expect(a.state.liveChildren(layer) == [rect, copy, cloned, above])
        // Undo removes the copy.
        a.undo()
        #expect(!a.state.isLive(copy))
    }

    @Test func powerDuplicateRepeatsTheRememberedTransformation() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        // Duplicate → move 20 pt → Duplicate: the third copy is 20 pt from the second.
        let second = try a.perform(DuplicateObjects.duplicate([rect]))!.createdRoots[0]
        var memory = DuplicateMemory(nodes: [second])
        #expect(memory.matrix == DuplicateMemory.defaultOffset)
        let move = AffineTransform.translation(x: 20, y: 0)
        try a.perform(MoveObjects([second], by: Vector(dx: 20, dy: 0)))
        memory.record(.move, matrix: move)
        let third = try a.perform(DuplicateObjects.duplicate([second], memory: memory))!.createdRoots[0]
        #expect(Objects.bounds(of: third, in: a.state)!.minX == Objects.bounds(of: second, in: a.state)!.minX + 20)
        // A memory for another selection does not apply.
        #expect(DuplicateObjects.duplicate([rect], memory: memory).offset == DuplicateMemory.defaultOffset)
        // Duplicate → rotate 30° about a point → Duplicate: the next copy is rotated 60°.
        let pivot = Point(x: 100, y: 100)
        let rotate = TransformObjects([], matrix: .rotation(radians: .pi / 6), about: pivot, kind: .rotate)
        let r2 = try a.perform(DuplicateObjects.duplicate([rect]))!.createdRoots[0]
        try a.perform(TransformObjects([r2], matrix: .rotation(radians: .pi / 6), about: pivot, kind: .rotate))
        var rotation = DuplicateMemory(nodes: [r2])
        rotation.record(.rotate, matrix: rotate.effectiveMatrix)
        let r3 = try a.perform(DuplicateObjects.duplicate([r2], memory: rotation))!.createdRoots[0]
        let t2 = Objects.transform(of: r2, in: a.state), t3 = Objects.transform(of: r3, in: a.state)
        let expected = t2.concatenating(rotate.effectiveMatrix)
        #expect(abs(t3.a - expected.a) < 1e-9 && abs(t3.tx - expected.tx) < 1e-9 && abs(t3.ty - expected.ty) < 1e-9)
        #expect(abs(atan2(t3.b, t3.a) - .pi / 3) < 1e-9)
        // Scale followed by skew resets the memory to the skew alone.
        var mixed = DuplicateMemory(nodes: [rect])
        mixed.record(.move, matrix: move)
        mixed.record(.scale, matrix: .scale(2))
        #expect(mixed.kinds == [.move, .scale])
        mixed.record(.skew, matrix: .shear(x: 0.5, y: 0))
        #expect(mixed.recorded == .shear(x: 0.5, y: 0))
        #expect(mixed.kinds == [.skew])
    }

    @Test func lastTransformRepeats() {
        let command = TransformObjects([OpID(counter: 1, replica: 1)], matrix: .scale(2), about: Point(x: 1, y: 1), kind: .scale,
                                       options: TransformOptions(strokes: true))
        let last = LastTransform(command)
        let again = last.again([OpID(counter: 2, replica: 1)])
        #expect(again.matrix == command.matrix && again.center == command.center && again.kind == .scale && again.options.strokes)
        #expect(again.nodes == [OpID(counter: 2, replica: 1)])
    }

    @Test func malformedPayloadsDecodeToNothing() {
        #expect(ClipboardPayload(decoding: [0xFF]) == nil)
        #expect(ClipboardPayload(decoding: [0x08, 0x01]) == nil)   // a varint where records are expected
        #expect(ClipboardPayload(decoding: Wire.field(1, [0xFF])) == nil)
        #expect(ClipboardPayload(decoding: Wire.field(1, Wire.field(1, [0xFF]))) == nil)
        #expect(ClipboardPayload(decoding: Wire.field(1, Wire.field(2, [0xFF]))) == nil)
        #expect(ClipboardPayload(decoding: Wire.field(1, Wire.field(3, [0xFF]))) == nil)
        #expect(ClipboardPayload(decoding: Wire.field(4, [0xFF])) == nil)
        #expect(ClipboardPayload(decoding: Wire.field(9, []))?.isEmpty == true)
        #expect(ClipboardPayload(decoding: Wire.field(1, Wire.field(9, [])))?.nodes.count == 1)
    }

    @Test func wireReaderReadsEveryWireType() {
        let bytes: [UInt8] = [0x08, 0x96, 0x01, 0x11, 1, 2, 3, 4, 5, 6, 7, 8, 0x1D, 1, 2, 3, 4, 0x22, 0x02, 0xAA, 0xBB]
        let fields = WireReader.fields(bytes)
        #expect(fields?.map(\.number) == [1, 2, 3, 4])
        #expect(fields?.map(\.wireType) == [0, 1, 5, 2])
        #expect(fields?.last?.payload == [0xAA, 0xBB])
        #expect(WireReader.fields([0x00]) == nil)            // field number 0
        #expect(WireReader.fields([0x0B]) == nil)            // a group
        #expect(WireReader.fields([0x08, 0x80]) == nil)      // a truncated varint
        #expect(WireReader.fields([0x11, 1, 2]) == nil)      // a truncated fixed64
        #expect(WireReader.fields([0x12, 0x05, 1]) == nil)   // a truncated record
    }
}

/// The merge tests of OBJ-010, OBJ-011 and OBJ-012.
@Suite struct ClipboardMergeTests {
    @Test func cutVersusRemoteEditLeavesTheEditOnTheDeletedNodeAndThePastePreEdit() throws {
        var pair = Pair()
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (10, 0)]), on: &pair.a)
        pair.sync()
        let payload = ClipboardPayload(copying: [path], from: pair.a.state)
        try pair.a.perform(CutObjects([path]))
        let contour = pair.b.path(path).contours[0]
        try pair.b.perform(MovePoints(node: path, contour: contour.id, point: contour.points[0].id, to: Point(x: 7, y: 7)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(!pair.a.state.isLive(path))
        #expect(pair.a.path(path).contours[0].points[0].anchor == Point(x: 7, y: 7))
        let copy = try pair.a.perform(Paste(payload))!.createdRoots[0]
        #expect(pair.a.path(copy).contours[0].points[0].anchor == Point(x: 0, y: 0))
    }

    @Test func pasteInFrontStaysInTheParentThePasterSaw() throws {
        var pair = Pair()
        let m1 = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        let m2 = try LayerFixture.object(LayerFixture.rect(on: nil, x: 20), on: &pair.a)
        let group = try pair.a.perform(GroupObjects([m1, m2]))!.createdObjects[0]
        let loose = try LayerFixture.object(LayerFixture.rect(on: nil, x: 40), on: &pair.a)
        pair.sync()
        let layer = Objects.parent(of: group, in: pair.a.state)!
        let payload = ClipboardPayload(copying: [loose], from: pair.a.state)
        let copy = try pair.a.perform(Paste(payload, placement: .inFront(of: m1)))!.createdRoots[0]
        try pair.b.perform(MoveObjectsToLayer([m1], to: layer))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(Objects.parent(of: copy, in: pair.b.state) == group)
        #expect(Objects.parent(of: m1, in: pair.b.state) == layer)
    }

    @Test func concurrentDuplicatesBothAppear() throws {
        var pair = Pair()
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &pair.a)
        pair.sync()
        let a = try pair.a.perform(DuplicateObjects.duplicate([rect]))!.createdRoots[0]
        let b = try pair.b.perform(DuplicateObjects.clone([rect]))!.createdRoots[0]
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        #expect(pair.a.state.isLive(a) && pair.a.state.isLive(b))
    }
}
