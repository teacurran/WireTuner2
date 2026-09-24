import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// WEB-015: Release to Layers.
@Suite struct WebReleaseToLayersTests {
    /// A layer with three named rectangles grouped: returns the layer, the group and the pieces.
    static func grouped(_ replica: inout Replica) throws -> (layer: OpID, group: OpID, pieces: [OpID]) {
        let layer = try NavigationFixture.layer(&replica, "Base")
        var pieces: [OpID] = []
        for (index, name) in ["1", "2", "3"].enumerated() {
            let rect = try NavigationFixture.rect(&replica, on: layer, x: Double(index) * 20)
            try replica.perform(OpsCommand("Name", ops: [Ops.set(rect, [CommonFields.name(.rect)], values: NodeValues.common(kind: .rect) { $0.name = name })]))
            pieces.append(rect)
        }
        let group = try replica.perform(GroupObjects(pieces, layer: layer))!.createdObjects[0]
        return (layer, group, pieces)
    }

    /// The frame layers above `base`, bottom first, with the names of the objects each holds.
    static func frames(_ state: EngineState, above base: OpID) -> [(name: String, objects: [String])] {
        let order = LayerOrder(state)
        guard let start = order.index(of: base) else { return [] }
        return order.layers[(start + 1)...].map { layer in
            (layer.name, order.objects(on: layer.id, in: state).map { state.props($0).rect.common.name })
        }
    }

    @Test func eachModeProducesTheDocumentedLayersInOneChange() throws {
        let expected: [(ReleaseMode, [[String]])] = [
            (.sequence, [["1"], ["2"], ["3"]]),
            (.build, [["1"], ["1", "2"], ["1", "2", "3"]]),
            (.drop, [["2", "3"], ["1", "3"], ["1", "2"]]),
            (.trail(1), [["1"], ["1", "2"], ["2", "3"]]),
        ]
        for (mode, layers) in expected {
            var a = Replica(1)
            let (base, group, pieces) = try Self.grouped(&a)
            let change = try a.perform(ReleaseToLayers([group], mode: mode, currentLayer: base))!
            #expect(change.label == "Release to Layers")
            let frames = Self.frames(a.state, above: base)
            #expect(frames.map(\.name) == ["Frame 1", "Frame 2", "Frame 3"])
            #expect(frames.map(\.objects) == layers, "\(mode)")
            #expect(!a.state.isLive(group))
            // Every original piece exists once, moved; the rest are copies.
            #expect(pieces.allSatisfy { a.state.isLive($0) && Reachability.isReachable($0, in: a.state) })
        }
    }

    @Test func reverseRunsThePiecesTheOtherWay() throws {
        var a = Replica(1)
        let (base, group, _) = try Self.grouped(&a)
        try a.perform(ReleaseToLayers([group], mode: .sequence, reverse: true, currentLayer: base))
        #expect(Self.frames(a.state, above: base).map(\.objects) == [["3"], ["2"], ["1"]])
    }

    @Test func undoRestoresTheContainerAndRemovesTheLayersInOneStep() throws {
        var a = Replica(1)
        let (base, group, pieces) = try Self.grouped(&a)
        let before = LayerOrder(a.state).layers.map(\.id)
        try a.perform(ReleaseToLayers([group], mode: .build, currentLayer: base))
        a.undo()
        #expect(LayerOrder(a.state).layers.map(\.id) == before)
        #expect(a.state.isLive(group) && a.state.liveChildren(group) == pieces)
    }

    @Test func groupTransformsAreKeptOnThePieces() throws {
        var a = Replica(1)
        let (base, group, pieces) = try Self.grouped(&a)
        try a.perform(MoveObjects([group], by: Vector(dx: 5, dy: 7)))
        try a.perform(ReleaseToLayers([group], mode: .build, currentLayer: base))
        let layers = Self.frames(a.state, above: base)
        #expect(layers.count == 3)
        #expect(Objects.bounds(of: pieces[0], in: a.state) == Rect(x: 5, y: 7, width: 10, height: 10))
        let copies = LayerOrder(a.state).objects(on: LayerOrder(a.state).layers.last!.id, in: a.state)
        #expect(Objects.bounds(of: copies[0], in: a.state) == Rect(x: 5, y: 7, width: 10, height: 10))
    }

    @Test func existingLayersFillFromTheCurrentOneUpAndNumberingContinues() throws {
        var a = Replica(1)
        let layers = try LayerFixture.layers(["Bottom", "Frame 4", "Top"], on: &a)
        var pieces: [OpID] = []
        for index in 0..<4 {
            pieces.append(try NavigationFixture.rect(&a, on: layers[0], x: Double(index) * 20))
        }
        let marker = try NavigationFixture.rect(&a, on: layers[1], x: 500)
        try a.perform(ReleaseToLayers(pieces, mode: .sequence, useExistingLayers: true, sendToBack: true, currentLayer: layers[0]))
        let order = LayerOrder(a.state)
        #expect(order.layers.map(\.name) == ["Bottom", "Frame 4", "Top", "Frame 5"])
        #expect(order.objects(on: layers[0], in: a.state) == [pieces[0]])
        // Send to back puts the piece behind what the layer holds.
        #expect(order.objects(on: layers[1], in: a.state) == [pieces[1], marker])
        #expect(order.objects(on: order.layers[3].id, in: a.state) == [pieces[3]])
        // Without Send to back pieces go in front.
        var b = Replica(2)
        let other = try LayerFixture.layers(["One", "Two"], on: &b)
        let x = try NavigationFixture.rect(&b, on: other[0])
        let y = try NavigationFixture.rect(&b, on: other[0], x: 30)
        let held = try NavigationFixture.rect(&b, on: other[1], x: 90)
        try b.perform(ReleaseToLayers([x, y], mode: .sequence, useExistingLayers: true, currentLayer: other[0]))
        #expect(LayerOrder(b.state).objects(on: other[1], in: b.state) == [held, y])
    }

    @Test func aBlendReleasesItsStepsAndLeavesItsEnds() throws {
        var a = Replica(0xA)
        let one = try BlendCommandTests.square(&a, x: 0)
        let two = try BlendCommandTests.square(&a, x: 100, red: 0)
        try a.perform(Blend([one, two]))
        let blend = try #require(BlendCommandTests.blend(of: one, a.state))
        try a.perform(EditBlend.steps([blend], 3))
        let base = try #require(LayerOrder(a.state).layer(of: one, in: a.state))
        try a.perform(ReleaseToLayers([blend], mode: .sequence, currentLayer: base))
        #expect(!a.state.isLive(blend))
        let order = LayerOrder(a.state)
        #expect(order.objects(on: base, in: a.state) == [one, two])
        let frames = order.layers.filter { $0.name.hasPrefix("Frame") }
        #expect(frames.count == 3)
        let steps = frames.map { order.objects(on: $0.id, in: a.state) }
        #expect(steps.allSatisfy { $0.count == 1 && a.state.nodeKind($0[0]) == .path })
        // The steps run left to right.
        let xs = steps.compactMap { Objects.bounds(of: $0[0], in: a.state)?.minX }
        #expect(xs == xs.sorted() && xs.first! > 0 && xs.last! < 100)
    }

    @Test func aMovedBlendOfStrokedShapesReleasesEachStepAsAGroup() throws {
        var a = Replica(0xA)
        func square(_ x: Double, red: Double) throws -> OpID {
            var appearance = Wiretuner_Doc_V1_AppearanceProps()
            appearance.fills = [Appearances.basicFill(red: red, green: 0, blue: 1 - red)]
            appearance.strokes = [Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)]
            return try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(x, 0), (x + 10, 0), (x + 10, 10), (x, 10)]))],
                                                      appearance: appearance), on: &a)
        }
        let one = try square(0, red: 1)
        let two = try square(100, red: 0)
        try a.perform(Blend([one, two]))
        let blend = try #require(BlendCommandTests.blend(of: one, a.state))
        try a.perform(EditBlend.steps([blend], 2))
        try a.perform(MoveObjects([blend], by: Vector(dx: 0, dy: 30)))
        try a.perform(ReleaseToLayers([blend], mode: .sequence))
        let order = LayerOrder(a.state)
        let frames = order.layers.filter { $0.name.hasPrefix("Frame") }
        #expect(frames.count == 2)
        let steps = frames.map { order.objects(on: $0.id, in: a.state) }
        #expect(steps.allSatisfy { $0.count == 1 && a.state.nodeKind($0[0]) == .group })
        // The key objects keep the blend's move.
        #expect(Objects.bounds(of: one, in: a.state)?.minY == 30)
    }

    @Test @MainActor func aTextBlockReleasesOneCharacterPerLayer() throws {
        var a = Replica(1)
        let layer = try NavigationFixture.layer(&a)
        let text = try a.perform(CreateTextBlock(.point(Point(x: 0, y: 0)), text: "Hi!", layer: layer))!.createdObjects[0]
        // Without a text layout the block is one piece.
        var b = Replica(2)
        b.receive(a.sent)
        try b.perform(ReleaseToLayers([text], mode: .sequence, currentLayer: layer))
        #expect(LayerOrder(b.state).layers.filter { $0.name.hasPrefix("Frame") }.count == 1)
        let fonts = DocumentFontIndex(state: a.state)
        try a.perform(ReleaseToLayers([text], mode: .sequence, currentLayer: layer, textLayout: TextSceneLayout(engine: fonts.layoutEngine)))
        #expect(!a.state.isLive(text))
        let order = LayerOrder(a.state)
        let frames = order.layers.filter { $0.name.hasPrefix("Frame") }
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { layer in order.objects(on: layer.id, in: a.state).allSatisfy { a.state.nodeKind($0) == .path } })
    }

    @Test func severalObjectsAreEachAPieceAndSequenceTakesGroupsApart() throws {
        var a = Replica(1)
        let (base, group, _) = try Self.grouped(&a)
        let loose = try NavigationFixture.rect(&a, on: base, x: 300)
        try a.perform(OpsCommand("Name", ops: [Ops.set(loose, [CommonFields.name(.rect)], values: NodeValues.common(kind: .rect) { $0.name = "4" })]))
        var b = Replica(2)
        b.receive(a.sent)
        try a.perform(ReleaseToLayers([loose, group], mode: .sequence, currentLayer: base))
        #expect(Self.frames(a.state, above: base).map(\.objects) == [["1"], ["2"], ["3"], ["4"]])
        try b.perform(ReleaseToLayers([loose, group], mode: .build, currentLayer: base))
        let layers = LayerOrder(b.state).layers.filter { $0.name.hasPrefix("Frame") }
        #expect(layers.count == 2)
        #expect(LayerOrder(b.state).objects(on: layers[0].id, in: b.state) == [group])
    }

    @Test func refusals() throws {
        var a = Replica(1)
        let (base, group, _) = try Self.grouped(&a)
        #expect(throws: ReleaseError.nothingToRelease) { try a.perform(ReleaseToLayers([base], mode: .sequence)) }
        #expect(throws: ReleaseError.invalidTrail) { try a.perform(ReleaseToLayers([group], mode: .trail(0))) }
        #expect(ReleaseMode.trail(2).pieces(onLayer: 3, count: 5) == [1, 2, 3])
    }

    @Test func twoReplicasReleasingTheSameGroupConvergeWithEachOriginalOnce() throws {
        var pair = Pair()
        let (base, group, pieces) = try Self.grouped(&pair.a)
        pair.sync()
        try pair.a.perform(ReleaseToLayers([group], mode: .sequence, currentLayer: base))
        try pair.b.perform(ReleaseToLayers([group], mode: .build, currentLayer: base))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let state = pair.a.state
        let order = LayerOrder(state)
        #expect(order.layers.filter { $0.name.hasPrefix("Frame") }.count == 6)
        // Each original piece exists exactly once, on one layer of one of the two sets.
        for piece in pieces {
            let holders = order.layers.filter { order.objects(on: $0.id, in: state).contains(piece) }
            #expect(holders.count == 1)
        }
        #expect(!state.isLive(group))
    }
}
