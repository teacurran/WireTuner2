import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// ATTR-020: tile capture and expansion over a corpus, Paste In, and the lens Snapshot.
@Suite struct LensSnapshotTests {
    /// A lens-filled square of `size` at `x` on the default layer; returns it and its lens row.
    static func lens(on a: inout Replica, x: Double, size: Double = 50) throws -> (node: OpID, row: AppearanceRow) {
        let node = try LayerFixture.object(LayerFixture.rect(on: nil, x: x, size: size), on: &a)
        let row = try fillRow(node, on: &a)
        try a.perform(SetAttributeKind([(node, row)], fill: .lens))
        return (node, row)
    }

    /// The node's fill row, a black fill added first when it has none.
    static func fillRow(_ node: OpID, on a: inout Replica) throws -> AppearanceRow {
        if let row = AppearanceEditing.stack(node, in: a.state).first(where: { $0.list == .fills }) { return row }
        try a.perform(AddAppearance.fill([node]))
        return AppearanceEditing.stack(node, in: a.state).first { $0.list == .fills }!
    }

    static func fill(_ node: OpID, _ row: AppearanceRow, in state: EngineState) -> Wiretuner_Doc_V1_FillSettings {
        state.props(node).rect.appearance.fills.first { OpID(element: $0.id) == row.element }!.settings
    }

    /// A corpus of what a tile holds: rectangles (square and rounded), an ellipse, a polygon, a
    /// curved path, and a group -- with a nested group -- of filled, stroked and gradient-filled
    /// members.
    static func corpus(on a: inout Replica) throws -> [OpID] {
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil, x: 10), on: &a)
        let rounded = try LayerFixture.object(CreateShape(.rectangle(CornerRadii(topLeft: 3, topRight: 3, bottomRight: 3, bottomLeft: 3)),
                                                          size: Size(width: 30, height: 12), transform: .translation(x: 40, y: 5)), on: &a)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 8, height: 14), transform: .translation(x: 0, y: 30)), on: &a)
        let polygon = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 6, radius: 9), center: Point(x: 60, y: 40)), on: &a)
        let curve = [VectorPoint(anchor: Point(x: 0, y: 60), outHandle: Vector(dx: 10, dy: -10)), VectorPoint(anchor: Point(x: 30, y: 60), inHandle: Vector(dx: -10, dy: -10), kind: .curve),
                     VectorPoint(anchor: Point(x: 45, y: 75))]
        let path = try LayerFixture.object(CreatePath(contours: [NewContour(points: curve)]), on: &a)
        let inner = try a.perform(GroupObjects([ellipse, polygon]))!.createdObjects[0]
        let outer = try a.perform(GroupObjects([inner, path]))!.createdObjects[0]
        var ramp = Wiretuner_Doc_V1_GradientFill()
        ramp.type = .linear
        for (offset, grey) in [(0.0, 0.0), (1.0, 1.0)] {
            var stop = Wiretuner_Doc_V1_GradientStop()
            stop.offset = offset
            stop.color = Appearances.basicFill(red: grey, green: grey, blue: grey).settings.basic.color
            ramp.stops.append(stop)
        }
        try a.perform(ApplyGradient([rounded], gradient: ramp))
        return [rect, rounded, outer]
    }

    @Test func captureThenExpandRoundTripsTheCorpus() throws {
        var a = Replica(0xA)
        let nodes = try Self.corpus(on: &a)
        let payload = ClipboardPayload(copying: nodes, from: a.state)
        let tile = try Subtrees.tile(from: payload)
        #expect(tile.nodes.count == 7)
        let back = try #require(Subtrees.payload(from: tile))
        // Expanding and capturing again gives the same tile, byte for byte.
        let again = try Subtrees.tile(from: back)
        #expect(again == tile)
        // Every node's props survive but for the roots' shift to the origin.
        let origin = try #require(payload.bounds)
        for (original, copied) in zip(payload.nodes, back.nodes) {
            var shifted = original
            shifted.transform = original.transform.concatenating(.translation(x: -origin.minX, y: -origin.minY))
            #expect(Self.stripped(shifted) == Self.stripped(copied))
        }
        #expect(SubtreeRendering.items(tile).count == 3)
    }

    /// A tree without its source ids (a tile strips them).
    static func stripped(_ tree: NodeTree) -> NodeTree {
        NodeTree(props: tree.props, children: tree.children.map(stripped))
    }

    @Test func pasteInWritesTheTileWhole() throws {
        var a = Replica(0xA)
        let target = try LayerFixture.object(LayerFixture.rect(on: nil, x: 200), on: &a)
        let row = try Self.fillRow(target, on: &a)
        try a.perform(SetAttributeKind([(target, row)], fill: .tiled))
        let art = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 5, height: 5)), on: &a)
        let command = try EditAttribute.pasteIn([(target, row)], ClipboardPayload(copying: [art], from: a.state))
        let change = try #require(try a.perform(command))
        #expect(change.label == "Paste In")
        #expect(change.ops.count == 1 && change.ops[0].set.paths.count == 1)
        #expect(Self.fill(target, row, in: a.state).tiled.tile.nodes.count == 1)
        #expect(throws: PasteInError.empty) { try EditAttribute.pasteIn([(target, row)], ClipboardPayload(nodes: [])) }
    }

    @Test func aSnapshotFreezesWhatIsBeneathInTheLensSpace() throws {
        var a = Replica(0xA)
        let below = try LayerFixture.object(LayerFixture.rect(on: nil, x: 110, size: 20), on: &a)
        let far = try LayerFixture.object(LayerFixture.rect(on: nil, x: 500), on: &a)
        let text = try a.perform(CreateTextBlock(.area(Rect(x: 105, y: 5, width: 30, height: 20)), text: "Hi"))
        let (lens, row) = try Self.lens(on: &a, x: 100)
        let above = try LayerFixture.object(LayerFixture.rect(on: nil, x: 120), on: &a)
        let change = try #require(try a.perform(SnapshotLens([(lens, row)])))
        #expect(change.label == "Snapshot")
        #expect(change.ops.count == 1 && change.ops[0].set.paths.map(RegisterPath.init).count == 2)
        let settings = Self.fill(lens, row, in: a.state)
        #expect(settings.lens.snapshot)
        let contents = settings.lens.snapshotContents
        #expect(contents.nodes.count == 1, "only the overlapping object beneath; not \(far), \(above) or the text \(String(describing: text))")
        let items = SubtreeRendering.items(contents)
        #expect(items.first?.ownBounds.map { abs($0.minX - 10) < 1e-9 && abs($0.width - 20) < 1e-9 } == true, "object-local: 10 in from the lens's left")
        // The fill draws the frozen picture.
        guard case .lens(let paint) = Appearances.fill(settings, evenOdd: false).paint else { Issue.record("lens"); return }
        #expect(paint.snapshot?.count == 1)
        _ = below
        // Undo takes both registers back.
        a.undo()
        #expect(!Self.fill(lens, row, in: a.state).lens.snapshot)
    }

    @Test func aLensInsideAGroupSeesEarlierSiblingsAndLayers() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Back", "Hidden", "Front"], on: &a)
        let back = try LayerFixture.object(LayerFixture.rect(on: layers[0], x: 0, size: 100), on: &a)
        let hidden = try LayerFixture.object(LayerFixture.rect(on: layers[1], x: 0, size: 100), on: &a)
        try a.perform(SetLayerFlag([layers[1]], .visible, false))
        let sibling = try LayerFixture.object(LayerFixture.rect(on: layers[2], x: 10, size: 20), on: &a)
        let lens = try LayerFixture.object(LayerFixture.rect(on: layers[2], x: 5, size: 40), on: &a)
        let row = try Self.fillRow(lens, on: &a)
        try a.perform(SetAttributeKind([(lens, row)], fill: .lens))
        let group = try a.perform(GroupObjects([sibling, lens]))!.createdObjects[0]
        try a.perform(TransformObjects([group], matrix: .translation(x: 3, y: 0), kind: .move))
        let contents = try LensSnapshots.capture(lens: lens, in: a.state)
        #expect(contents.nodes.count == 2, "the back layer's square and the earlier sibling; not the hidden layer's \(hidden) or \(back)'s copy twice")
        #expect(contents.nodes.allSatisfy { $0.parent == -1 })
    }

    @Test func snapshotRefusesWhatIsNotALensAndTooMuchArtwork() throws {
        var a = Replica(0xA)
        let plain = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        let row = try Self.fillRow(plain, on: &a)
        #expect(throws: LensSnapshotError.notALens) { try a.perform(SnapshotLens([(plain, row)])) }
        let stroke = AppearanceEditing.stack(plain, in: a.state).first { $0.list == .strokes }!
        #expect(throws: LensSnapshotError.notALens) { try a.perform(SnapshotLens([(plain, stroke)])) }
        // Beneath the lens: a group of two squares, one of them with a long note.
        let other = try LayerFixture.object(LayerFixture.rect(on: nil, x: 5), on: &a)
        try a.perform(GroupObjects([plain, other]))
        var props = Wiretuner_Doc_V1_NodeProps()
        props.rect.common.note = String(repeating: "x", count: 4_000)
        try a.perform(OpsCommand("Note", ops: [Ops.set(plain, [RegisterPath([21, 1, 2])], values: props)]))
        let (lens, lensRow) = try Self.lens(on: &a, x: 0)
        #expect(try LensSnapshots.capture(lens: lens, in: a.state).nodes.count == 3)
        #expect(throws: LensSnapshotError.tooLarge) { try LensSnapshots.capture(lens: lens, in: a.state, maximumNodes: 3, maximumNodeBytes: 3_000) }
        #expect(throws: LensSnapshotError.tooLarge) { try LensSnapshots.capture(lens: lens, in: a.state, maximumNodes: 2, maximumNodeBytes: 5_000) }
        #expect(try a.perform(SnapshotLens([(lens, lensRow)])) != nil)
        #expect(LensSnapshotError.tooLarge.message.contains("too much artwork under this lens") && LensSnapshotError.notALens.message.contains("lens"))
        // A lens with no geometry sees nothing.
        #expect(try LensSnapshots.capture(lens: OpID(counter: 999, replica: 9), in: a.state).nodes.isEmpty)
    }
}

/// ATTR-020's merge tests.
@Suite struct LensSnapshotMergeTests {
    @Test func concurrentTilePastesConvergeOnTheLaterTileWhole() throws {
        var pair = Pair()
        let target = try LayerFixture.object(LayerFixture.rect(on: nil, x: 200), on: &pair.a)
        let row = try LensSnapshotTests.fillRow(target, on: &pair.a)
        try pair.a.perform(SetAttributeKind([(target, row)], fill: .tiled))
        let one = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 5, height: 5)), on: &pair.a)
        let two = try LayerFixture.object(PathFixture.closed([(0, 0), (9, 0), (9, 9)]), on: &pair.a)
        pair.sync()
        try pair.a.perform(try EditAttribute.pasteIn([(target, row)], ClipboardPayload(copying: [one], from: pair.a.state)))
        try pair.b.perform(try EditAttribute.pasteIn([(target, row)], ClipboardPayload(copying: [two, one], from: pair.b.state)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // Replica B's write has the greater id: its whole tile, both nodes.
        #expect(LensSnapshotTests.fill(target, row, in: pair.a.state).tiled.tile.nodes.count == 2)
    }

    @Test func concurrentSnapshotsEachStayCompletePictures() throws {
        var pair = Pair()
        _ = try LayerFixture.object(LayerFixture.rect(on: nil, x: 110, size: 20), on: &pair.a)
        let (lens, row) = try LensSnapshotTests.lens(on: &pair.a, x: 100)
        pair.sync()
        // B moves something under the lens first, so the two pictures differ.
        let extra = try LayerFixture.object(LayerFixture.rect(on: nil, x: 130, size: 5), on: &pair.b)
        try pair.b.perform(Arrange([extra], .sendToBack))
        try pair.a.perform(SnapshotLens([(lens, row)]))
        try pair.b.perform(SnapshotLens([(lens, row)]))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let settings = LensSnapshotTests.fill(lens, row, in: pair.a.state)
        #expect(settings.lens.snapshot && settings.lens.snapshotContents.nodes.count == 2, "B's picture, whole")
    }
}
