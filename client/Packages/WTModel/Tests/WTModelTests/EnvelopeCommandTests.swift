import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-039 (model half): envelopes in the scene, the envelope commands, presets and the read-time
/// normalizations.
@Suite struct EnvelopeCommandTests {
    static func square(_ replica: inout Replica, x: Double = 0, y: Double = 0, size: Double = 20) throws -> OpID {
        var appearance = Appearances.standard
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        appearance.strokes = []
        return try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([
            (x, y), (x + size, y), (x + size, y + size), (x, y + size),
        ]))], appearance: appearance), on: &replica)
    }

    static func envelope(of node: OpID, _ state: EngineState) -> OpID? {
        state.store.placement(node).flatMap { WrapperKind.of($0.parent, in: state) == .envelope ? $0.parent : nil }
    }

    static func scene(_ state: EngineState) -> DocumentScene {
        var builder = DocumentDisplayListBuilder(canvas: "c")
        return builder.rebuild(state)
    }

    static func spec(_ envelope: OpID, _ state: EngineState) -> (group: GroupItem, spec: EnvelopeSpec)? {
        guard case .group(let group)? = scene(state).object(envelope)?.item, case .envelope(let spec)? = group.live else { return nil }
        return (group, spec)
    }

    /// The drawn bounds of the envelope's warped contents.
    static func drawn(_ envelope: OpID, _ state: EngineState) -> Rect? {
        scene(state).object(envelope)?.item.bounds
    }

    /// The envelope's contour and its points in drawing order.
    static func points(_ envelope: OpID, _ state: EngineState) -> (contour: OpID, points: [OpID]) {
        let contour = EnvelopeReading.contour(envelope, in: state)!
        return (contour.id, contour.drawn.map(\.id))
    }

    static func moveAnchor(_ envelope: OpID, contour: OpID, point: OpID, to anchor: Point) -> OpsCommand {
        let values = EnvelopeFields.values { $0.contours = [.with { $0.points = [.with { $0.anchor = PathEditing.proto(anchor) }] }] }
        return OpsCommand("Move Point", ops: [Ops.set(envelope, [EnvelopeFields.anchor(contour, point)], values: values)])
    }

    // MARK: Creating and drawing

    @Test func createWrapsTheSelectionAndDrawsItUnwarped() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a)
        let two = try Self.square(&a, x: 40, y: 10)
        let change = try #require(try a.perform(CreateEnvelope([two, one])))
        #expect(change.label == "Create envelope")
        let envelope = try #require(Self.envelope(of: one, a.state))
        #expect(Self.envelope(of: two, a.state) == envelope && a.state.liveChildren(envelope) == [one, two], "stacking order kept")
        let props = a.state.props(envelope).envelope
        #expect(props.sourceBounds.x == 0 && props.sourceBounds.y == 0 && props.sourceBounds.width == 60 && props.sourceBounds.height == 30)
        #expect(EnvelopeReading.title(envelope, in: a.state) == "Envelope" && !EnvelopeReading.needsPoints(envelope, in: a.state))
        // The scene draws the envelope as a live group; a rectangle equal to the source is the identity.
        let (group, spec) = try #require(Self.spec(envelope, a.state))
        #expect(group.children.count == 2 && spec.corners == [0, 1, 2, 3] && spec.transform == .identity && !spec.showMap)
        let scene = Self.scene(a.state)
        #expect(scene.object(envelope)?.kind == .envelope && scene.object(one)?.parent == envelope && WrapperKind.envelope.nodeKind == .envelope)
        let bounds = try #require(Self.drawn(envelope, a.state))
        #expect(abs(bounds.minX) < 1e-6 && abs(bounds.maxX - 60) < 1e-6 && abs(bounds.maxY - 30) < 1e-6)
        #expect(NodeKind.envelope.title == "Envelope" && a.state.displayName(of: envelope) == "Envelope")
        // Undo unwraps.
        a.undo()
        #expect(Self.envelope(of: one, a.state) == nil && !a.state.isLive(envelope))
    }

    @Test func draggingAnEnvelopePointWarpsTheContents() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a, size: 40)
        try a.perform(CreateEnvelope([path]))
        let envelope = try #require(Self.envelope(of: path, a.state))
        let (contour, points) = Self.points(envelope, a.state)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(a.state)
        let change = try #require(try a.perform(Self.moveAnchor(envelope, contour: contour, point: points[2], to: Point(x: 60, y: 70))))
        let (scene, summary) = builder.apply(change, state: a.state, origin: .local)
        let bounds = try #require(scene.object(envelope)?.item.bounds)
        #expect(abs(bounds.maxX - 60) < 1e-6 && abs(bounds.maxY - 70) < 1e-6, "the bottom-right corner follows the point")
        #expect(summary.touchedNodes.contains(NodeID(envelope)))
        // Editing the contents repaints the envelope around them.
        let move = try #require(try a.perform(MoveObjects([path], by: Vector(dx: 1, dy: 0))))
        let (_, moved) = builder.apply(move, state: a.state, origin: .local)
        #expect(moved.touchedNodes.contains(NodeID(envelope)))
    }

    @Test func anEnvelopeInsideATransformedGroupWarpsInItsOwnSpace() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a, size: 40)
        let group = try #require(try a.perform(GroupObjects([path]))).createdObjects[0]
        try a.perform(OpsCommand("Rotate", ops: [Objects.setTransform(group, kind: .group, AffineTransform.rotation(radians: 0.3).concatenating(.translation(x: 100, y: 0)))]))
        try a.perform(CreateEnvelope([path], bounds: nil))
        let envelope = try #require(Self.envelope(of: path, a.state))
        let (_, spec) = try #require(Self.spec(envelope, a.state))
        #expect(spec.transform == Objects.pasteboardTransform(of: envelope, in: a.state) && !spec.transform.isIdentity)
        // The source rectangle is in the group's space: the square's own bounds.
        let source = a.state.props(envelope).envelope.sourceBounds
        #expect(abs(source.width - 40) < 1e-6 && abs(source.height - 40) < 1e-6 && abs(source.x) < 1e-6)
        // Unwarped, it draws where the square did.
        let before = try #require(Self.scene(a.state).object(path)?.item.bounds)
        let after = try #require(Self.drawn(envelope, a.state))
        #expect(abs(before.minX - after.minX) < 1e-6 && abs(before.maxY - after.maxY) < 1e-6)
    }

    @Test func objectsFromSeveralParentsAreCollectedOntoTheLayer() throws {
        var a = Replica(0xA)
        let one = try Self.square(&a)
        let inGroup = try Self.square(&a, x: 50)
        let group = try #require(try a.perform(GroupObjects([inGroup]))).createdObjects[0]
        try a.perform(MoveObjects([group], by: Vector(dx: 10, dy: 0)))
        try a.perform(CreateEnvelope([one, inGroup], bounds: Rect(x: 0, y: 0, width: 80, height: 20)))
        let envelope = try #require(Self.envelope(of: one, a.state))
        #expect(Self.envelope(of: inGroup, a.state) == envelope)
        #expect(Objects.transform(of: inGroup, in: a.state).tx == 10, "the member keeps its place on the page")
        #expect(a.state.props(envelope).envelope.sourceBounds.width == 80)
        #expect(throws: EnvelopeError.nothingToEnvelope) { try a.perform(CreateEnvelope([])) }
        var bad = EnvelopePreset.rectangle
        bad.corners = [0, 0, 1, 2]
        #expect(throws: EnvelopeError.invalidPreset) { try a.perform(CreateEnvelope([one], preset: bad)) }
    }

    // MARK: Presets

    @Test func presetsPlaceEncodeAndDecode() throws {
        #expect(EnvelopePreset.defaults.count == 5 && EnvelopePreset.defaults.allSatisfy(\.isValid))
        let arch = EnvelopePreset.arch.points(in: Rect(x: 10, y: 20, width: 100, height: 50))
        #expect(arch[1].anchor == Point(x: 60, y: 5) && arch[1].outHandle == Vector(dx: 30, dy: 0))
        for preset in EnvelopePreset.defaults {
            #expect(EnvelopePreset(encoded: preset.encoded) == preset)
        }
        var named = EnvelopePreset.flag
        named.name = "A | B"
        #expect(EnvelopePreset(encoded: named.encoded)?.name == "A | B")
        #expect(EnvelopePreset(encoded: "nonsense") == nil)
        #expect(EnvelopePreset(encoded: "0,1,2,3|1,2,3|x") == nil)
        #expect(EnvelopePreset(encoded: "0,1,2,9|0,0,0,0,0,0,0 1,0,0,0,0,0,0 1,1,0,0,0,0,0 0,1,0,0,0,0,0|x") == nil)
        #expect(EnvelopePreset.decode([]) == EnvelopePreset.defaults)
        #expect(EnvelopePreset.decode(["junk", named.encoded]) == [named])
        #expect(EnvelopePreset(name: "x", points: [], corners: [], normalizedTo: .zero) == nil)
        #expect(!EnvelopePreset(name: "x", points: [VectorPoint(anchor: Point(x: .nan, y: 0))] + EnvelopePreset.rectangle.points, corners: [1, 2, 3, 4]).isValid)
    }

    @Test func aPresetMakesTheEnvelopeAndOneCanBeSavedFromIt() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a, size: 40)
        try a.perform(CreateEnvelope([path], preset: .bulge))
        let envelope = try #require(Self.envelope(of: path, a.state))
        let (_, points) = Self.points(envelope, a.state)
        #expect(points.count == 8)
        #expect(EnvelopeReading.corners(envelope, in: a.state) == [points[0], points[2], points[4], points[6]])
        let bounds = try #require(Self.drawn(envelope, a.state))
        #expect(bounds.maxX > 40 && bounds.minY < 0, "the contents bulge")
        let saved = try #require(EnvelopePreset(name: "Mine", envelope: envelope, in: a.state))
        #expect(saved.corners == EnvelopePreset.bulge.corners && saved.points.count == 8)
        #expect(abs(saved.points[1].anchor.y - (-0.2)) < 1e-9)
        // No outline: nothing to save.
        let other = try Self.square(&a, x: 100)
        #expect(EnvelopePreset(name: "x", envelope: other, in: a.state) == nil)
    }

    // MARK: Paste as envelope, map, copy as path

    @Test func pasteAsEnvelopeUsesTheCopiedShape() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a, size: 40)
        var copied = Wiretuner_Doc_V1_PathProps()
        copied.contours = [Subtrees.proto(VectorContour(closed: true, points: PathFixture.points([(0, 0), (20, -10), (40, 0), (40, 40), (0, 40)])))]
        copied.common.transform = PathEditing.proto(AffineTransform.translation(x: 5, y: 0))
        let change = try #require(try a.perform(PasteAsEnvelope([path], path: copied)))
        #expect(change.label == "Paste as envelope")
        let envelope = try #require(Self.envelope(of: path, a.state))
        let contour = try #require(EnvelopeReading.contour(envelope, in: a.state))
        #expect(contour.drawn.map(\.anchor.x) == [5, 25, 45, 45, 5], "placed where the path was")
        let ids = contour.drawn.map(\.id)
        #expect(EnvelopeReading.corners(envelope, in: a.state) == [ids[0], ids[2], ids[3], ids[4]])
        var open = copied
        open.contours[0].closed = false
        #expect(PasteAsEnvelope.outline(open) == nil)
        #expect(throws: EnvelopeError.invalidShape) { try a.perform(PasteAsEnvelope([path], path: open)) }
        #expect(throws: EnvelopeError.nothingToEnvelope) { try a.perform(PasteAsEnvelope([], path: copied)) }
    }

    @Test func showMapIsLocalAndCopyAsPathGivesTheOutline() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a, size: 40)
        try a.perform(CreateEnvelope([path]))
        let envelope = try #require(Self.envelope(of: path, a.state))
        let show = ToggleEnvelopeMap([path], in: a.state)
        #expect(show.show && show.label == "Show map")
        let change = try #require(try a.perform(show))
        #expect(a.state.props(envelope).envelope.showMap)
        #expect(LocalOnly.strip(change, schema: a.state.schema).ops.allSatisfy { $0.set.paths.isEmpty }, "never leaves the device")
        let (group, spec) = try #require(Self.spec(envelope, a.state))
        #expect(spec.showMap && group.children.count == 1)
        let hide = ToggleEnvelopeMap([envelope], in: a.state)
        #expect(!hide.show && hide.label == "Hide map")
        try a.perform(hide)
        #expect(!a.state.props(envelope).envelope.showMap)
        // Copy as Path: the outline with the envelope's place on the page.
        try a.perform(MoveObjects([envelope], by: Vector(dx: 7, dy: 0)))
        let copied = try #require(EnvelopeReading.asPath(envelope, in: a.state))
        #expect(copied.path.contours.count == 1 && copied.path.contours[0].points.count == 4 && copied.path.common.transform.tx == 7)
        #expect(EnvelopeReading.asPath(path, in: a.state) == nil)
        #expect(throws: WrapperError.notAWrapper(WellKnown.layers)) { try a.perform(ToggleEnvelopeMap([WellKnown.layers], in: a.state)) }
    }

    // MARK: Release and remove

    @Test func removeAndRelease() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a, size: 40)
        let other = try Self.square(&a, x: 100, size: 40)
        try a.perform(CreateEnvelope([path]))
        try a.perform(CreateEnvelope([other]))
        let envelopes = [path, other].compactMap { Self.envelope(of: $0, a.state) }
        #expect(envelopes.count == 2)
        try a.perform(MoveObjects([envelopes[0]], by: Vector(dx: 5, dy: 0)))
        let remove = try #require(try a.perform(RemoveEnvelope([path])))
        #expect(remove.label == "Remove envelope" && Self.envelope(of: path, a.state) == nil && !a.state.isLive(envelopes[0]))
        #expect(Objects.transform(of: path, in: a.state).tx == 5, "the envelope's transform is baked in")
        a.undo()
        #expect(Self.envelope(of: path, a.state) == envelopes[0])

        let (contour, points) = Self.points(envelopes[1], a.state)
        try a.perform(Self.moveAnchor(envelopes[1], contour: contour, point: points[2], to: Point(x: 160, y: 70)))
        let release = try #require(try a.perform(ReleaseEnvelope([other])))
        #expect(release.label == "Release envelope" && !a.state.isLive(envelopes[1]))
        #expect(Self.envelope(of: other, a.state) == envelopes[1], "the contents stay inside the deleted envelope")
        let released = try #require(ColorFixture.created(release).first)
        let baked = try #require(Self.scene(a.state).object(released)?.item.bounds)
        #expect(abs(baked.maxX - 160) < 0.5 && abs(baked.maxY - 70) < 0.5, "the warped shape is kept")
        a.undo()
        #expect(a.state.isLive(envelopes[1]) && !a.state.isLive(released))
        #expect(try a.perform(ReleaseEnvelope([])) == nil)
        #expect(throws: WrapperError.notAWrapper(released)) { try a.perform(RemoveEnvelope([released])) }
    }

    // MARK: Read-time normalizations

    @Test func aDeletedCornerFallsBackToTheNearestLivePoint() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a, size: 40)
        try a.perform(CreateEnvelope([path], preset: .arch))
        let envelope = try #require(Self.envelope(of: path, a.state))
        let (contour, points) = Self.points(envelope, a.state)
        // Deleting the top-right corner: the corner reads as the nearest survivor in stored order.
        try a.perform(OpsCommand("Delete", ops: [Ops.elementDelete(envelope, [EnvelopeFields.points(contour).element(points[2])])]))
        let corners = EnvelopeReading.corners(envelope, in: a.state)
        #expect(corners[0] == points[0] && corners[1] == points[3] && corners[2] == points[3] && corners[3] == points[4])
        #expect(!EnvelopeReading.needsPoints(envelope, in: a.state))
        // Fewer than four points: the contents draw unwarped and the panel says why.
        try a.perform(OpsCommand("Delete", ops: [Ops.elementDelete(envelope, [EnvelopeFields.points(contour).element(points[1])])]))
        #expect(EnvelopeReading.needsPoints(envelope, in: a.state) && EnvelopeReading.needsPointsMessage == "Envelope needs four points")
        let bounds = try #require(Self.drawn(envelope, a.state))
        #expect(abs(bounds.width - 40) < 1e-6 && abs(bounds.height - 40) < 1e-6)
        // An unset corner register reads nil (WTRender takes the nearest point).
        try a.perform(OpsCommand("Clear", ops: [Ops.set(envelope, [EnvelopeFields.corners], values: EnvelopeFields.values { _ in })]))
        #expect(EnvelopeReading.corners(envelope, in: a.state) == [nil, nil, nil, nil])
        // A corner naming a point this contour never held reads nil too.
        try a.perform(OpsCommand("Stray", ops: [Ops.set(envelope, [EnvelopeFields.corners], values: EnvelopeFields.values {
            $0.corners.tl = OpID(counter: 999, replica: 0xF).elementID
        })]))
        #expect(EnvelopeReading.corners(envelope, in: a.state)[0] == nil)
    }

    @Test func extraContoursEmptyEnvelopesAndMissingOutlines() throws {
        var a = Replica(0xA)
        let path = try Self.square(&a, size: 40)
        try a.perform(CreateEnvelope([path]))
        let envelope = try #require(Self.envelope(of: path, a.state))
        // A second contour (a merge) draws with the map only; the first stays the envelope.
        let insert = Ops.elementInsert(envelope, EnvelopeFields.contours, positions: [[0xF0]], values: EnvelopeFields.values {
            $0.contours = [.with { $0.closed = true }]
        })
        let change = try #require(try a.perform(OpsCommand("Contour", ops: [insert])))
        let second = OpID(counter: change.startCounter, replica: change.replica)
        try a.perform(OpsCommand("Points", ops: [Ops.elementInsert(envelope, EnvelopeFields.points(second), positions: [[0x10], [0x20]], values: EnvelopeFields.values {
            $0.contours = [.with { $0.points = [.with { $0.anchor = PathEditing.proto(Point(x: 0, y: 90)) }, .with { $0.anchor = PathEditing.proto(Point(x: 9, y: 90)) }] }]
        })]))
        let spec = EnvelopeReading.spec(envelope, in: a.state)
        #expect(spec.contour.contours.count == 2 && spec.corners == [0, 1, 2, 3])
        // No outline at all: nothing warps, corners unresolved.
        let (contour, _) = Self.points(envelope, a.state)
        try a.perform(OpsCommand("Delete", ops: [Ops.elementDelete(envelope, [EnvelopeFields.contour(contour), EnvelopeFields.contour(second)])]))
        #expect(EnvelopeReading.contour(envelope, in: a.state) == nil && EnvelopeReading.corners(envelope, in: a.state) == [nil, nil, nil, nil])
        #expect(EnvelopeReading.spec(envelope, in: a.state).contour.isEmpty && EnvelopeReading.needsPoints(envelope, in: a.state))
        #expect(EnvelopePreset(name: "x", envelope: envelope, in: a.state) == nil)
        // An envelope with no live contents draws nothing and says so.
        try a.perform(OpsCommand("Delete", ops: [Ops.setDeleted(path)]))
        #expect(EnvelopeReading.title(envelope, in: a.state) == "Empty envelope" && Self.scene(a.state).object(envelope) == nil)
    }

    // MARK: Merges

    @Test func envelopePointDragVersusContentEditBothKeep() throws {
        var pair = Pair()
        let path = try Self.square(&pair.a, size: 40)
        let text = try TextFixture.block(&pair.a, "Warp", at: Point(x: 5, y: 30))
        try pair.a.perform(CreateEnvelope([path, text], bounds: Rect(x: 0, y: 0, width: 60, height: 40)))
        pair.sync()
        let envelope = try #require(Self.envelope(of: path, pair.a.state))
        let (contour, points) = Self.points(envelope, pair.a.state)
        try pair.a.perform(Self.moveAnchor(envelope, contour: contour, point: points[1], to: Point(x: 70, y: -10)))
        try pair.b.perform(InsertText(node: text, text: "ed", at: .end))
        try pair.b.perform(MoveObjects([path], by: Vector(dx: 3, dy: 0)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        for replica in [pair.a, pair.b] {
            #expect(TextNode(text, in: replica.state)?.string == "Warped")
            #expect(Objects.transform(of: path, in: replica.state).tx == 3)
            #expect(EnvelopeReading.contour(envelope, in: replica.state)?.drawn[1].anchor == Point(x: 70, y: -10))
        }
    }

    @Test func releaseVersusContentEditIsReviewedAndRestoreBringsItBack() throws {
        var pair = Pair()
        let path = try Self.square(&pair.a, size: 40)
        try pair.a.perform(CreateEnvelope([path]))
        pair.sync()
        let envelope = try #require(Self.envelope(of: path, pair.a.state))
        try pair.a.perform(ReleaseEnvelope([envelope]))
        try pair.b.perform(MoveObjects([path], by: Vector(dx: 3, dy: 0)))
        pair.sync()
        #expect(!pair.b.state.isEffectivelyLive(path), "the edited contents are under the deleted envelope")
        pair.a.undo()
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(replica.state.isLive(envelope) && Objects.transform(of: path, in: replica.state).tx == 3)
        }
    }

    @Test func removeVersusContentEditLandsOnTheFreedObject() throws {
        var pair = Pair()
        let path = try Self.square(&pair.a)
        try pair.a.perform(CreateEnvelope([path]))
        pair.sync()
        let envelope = try #require(Self.envelope(of: path, pair.a.state))
        try pair.a.perform(RemoveEnvelope([path]))
        try pair.b.perform(MoveObjects([path], by: Vector(dx: 7, dy: 0)))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(!replica.state.isLive(envelope) && Self.envelope(of: path, replica.state) == nil)
            #expect(Objects.transform(of: path, in: replica.state).tx == 7)
        }
    }
}
