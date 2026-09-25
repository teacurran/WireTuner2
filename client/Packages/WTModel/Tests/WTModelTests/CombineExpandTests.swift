import CoreGraphics
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-049: btn:[Expand] for a Combine.
@Suite struct CombineExpandTests {
    /// Two overlapping squares grouped, the group filled red with a live Combine; returns the
    /// group and its members.
    static func combined(on a: inout Replica, attachBend: Bool = false) throws -> (group: OpID, members: [OpID]) {
        let one = try LayerFixture.object(LayerFixture.rect(on: nil, x: 0, size: 20), on: &a)
        let two = try LayerFixture.object(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20), transform: .translation(x: 10, y: 10)), on: &a)
        let group = try a.perform(GroupObjects([one, two]))!.createdObjects[0]
        try a.perform(AddAppearance.fill([group], Appearances.basicFill(red: 1, green: 0, blue: 0)))
        if attachBend {
            let fill = AppearanceEditing.stack(group, in: a.state).first { $0.list == .fills }!
            try a.perform(AddEffect([group], kind: .bend, attachTo: [group: fill]))
        }
        try a.perform(AddEffect([group], kind: .combine))
        try a.perform(AddAppearance.stroke([group]))
        return (group, [one, two])
    }

    static func item(_ node: OpID, in state: EngineState) -> DisplayItem? {
        var scene = DocumentDisplayListBuilder(canvas: "test")
        return scene.rebuild(state).object(node)?.item
    }

    /// RGBA bytes of `item` drawn at 2× over `region`.
    static func pixels(_ item: DisplayItem, region: Rect) -> [UInt8] {
        let viewport = Viewport(scrollOrigin: region.origin, zoom: 2, size: Size(width: region.width * 2, height: region.height * 2))
        let image = CoreGraphicsRenderer().renderBitmap(DisplayList(canvas: "test", items: [item]), viewport: viewport)!
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    /// The share of pixels that differ by more than a few levels in any channel.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var differing = 0
        for pixel in stride(from: 0, to: min(a.count, b.count), by: 4) where (0..<4).contains(where: { abs(Int(a[pixel + $0]) - Int(b[pixel + $0])) > 24 }) {
            differing += 1
        }
        return Double(differing) / Double(a.count / 4)
    }

    @Test func expandingDrawsWhatTheLiveGroupDrew() throws {
        var a = Replica(0xA)
        let (group, _) = try Self.combined(on: &a, attachBend: true)
        #expect(CombineReading.canExpand(group, in: a.state))
        let live = try #require(Self.item(group, in: a.state))
        let region = Rect(x: -20, y: -20, width: 80, height: 80)
        let before = Self.pixels(live, region: region)
        let change = try #require(try a.perform(ExpandCombine([group, group])))
        #expect(change.label == "Expand Combine")
        let path = change.createdObjects[0]
        #expect(!a.state.isLive(group) && a.state.nodeKind(path) == .path)
        #expect(Objects.parent(of: path, in: a.state) == Objects.parent(of: group, in: a.state))
        let props = a.state.props(path).path
        #expect(props.contours.count == 1 && !props.common.hasTransform)
        #expect(props.appearance.fills.count == 1 && props.appearance.strokes.count == 1)
        #expect(props.appearance.effects.map(\.settings.kind) == [.bend], "the Combine is gone, the Bend stays")
        let fill = try #require(props.appearance.fills.first)
        #expect(props.appearance.effects[0].attachedTo == fill.id, "the Bend stays attached to the fill")
        let expanded = try #require(Self.item(path, in: a.state))
        #expect(Self.difference(before, Self.pixels(expanded, region: region)) < 0.01)
        // Undo brings the group back and removes the path.
        a.undo()
        #expect(a.state.isLive(group) && !a.state.isLive(path))
    }

    @Test func expandingInsideATransformedGroupKeepsThePlace() throws {
        var a = Replica(0xA)
        let (group, _) = try Self.combined(on: &a)
        let outer = try a.perform(GroupObjects([group]))!.createdObjects[0]
        try a.perform(TransformObjects([outer], matrix: AffineTransform.scale(x: 2, y: 1.5).concatenating(.translation(x: 100, y: 50)), kind: .scale))
        let bounds = try #require(Objects.bounds(of: group, in: a.state))
        let path = try #require(try a.perform(ExpandCombine([group]))).createdObjects[0]
        #expect(Objects.parent(of: path, in: a.state) == outer)
        let expanded = try #require(Objects.bounds(of: path, in: a.state))
        #expect(abs(expanded.minX - bounds.minX) < 0.01 && abs(expanded.maxY - bounds.maxY) < 0.01)
    }

    @Test func onlyGroupsWithALiveCombineExpand() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        #expect(try a.perform(ExpandCombine([rect])) == nil)
        let (group, _) = try Self.combined(on: &a)
        let row = AppearanceEditing.stack(group, in: a.state).first { $0.list == .effects }!
        try a.perform(SetAppearanceHidden([(group, row)], hidden: true))
        #expect(!CombineReading.canExpand(group, in: a.state))
        #expect(try a.perform(ExpandCombine([group])) == nil)
        // A group on a hidden layer is not drawn, so there is nothing to expand.
        try a.perform(SetAppearanceHidden([(group, row)], hidden: false))
        let layer = try #require(LayerOrder(a.state).layer(of: group, in: a.state))
        try a.perform(SetLayerFlag([layer], .visible, false))
        #expect(try a.perform(ExpandCombine([group])) == nil)
        // An attachment to an element that is not carried over is dropped.
        var effect = Wiretuner_Doc_V1_Effect()
        effect.settings.kind = .bend
        effect.attachedTo = Ops.elementID(OpID(counter: 9, replica: 0))
        #expect(CombineReading.isLiveCombine(effect) == false)
    }

    @Test func intersectingDisjointMembersGivesAnEmptyPath() throws {
        var a = Replica(0xA)
        let one = try LayerFixture.object(LayerFixture.rect(on: nil, x: 0), on: &a)
        let two = try LayerFixture.object(LayerFixture.rect(on: nil, x: 50), on: &a)
        let group = try a.perform(GroupObjects([one, two]))!.createdObjects[0]
        try a.perform(AddAppearance.fill([group]))
        try a.perform(AddEffect([group], kind: .combine))
        let row = AppearanceEditing.stack(group, in: a.state).first { $0.list == .effects }!
        try a.perform(EditEffect([(group, row)], label: "Combine", fields: [EffectFields.field(.combine, 1)]) { $0.combine.op = .intersect })
        let path = try #require(try a.perform(ExpandCombine([group]))).createdObjects[0]
        #expect(a.state.props(path).path.contours.isEmpty)
    }
}

/// FX-049's merge test.
@Suite struct CombineExpandMergeTests {
    @Test func expandVersusAMemberEditLeavesThePathAndARestorableGroup() throws {
        var pair = Pair()
        let (group, members) = try CombineExpandTests.combined(on: &pair.a)
        pair.sync()
        let path = try #require(try pair.a.perform(ExpandCombine([group]))).createdObjects[0]
        try pair.b.perform(MoveObjects([members[1]], by: Vector(dx: 30, dy: 0)))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        // The path stands; the edit landed on the member under the deleted group.
        #expect(pair.a.state.isLive(path) && !pair.a.state.isLive(group))
        #expect(Objects.parent(of: members[1], in: pair.a.state) == group)
        #expect(Objects.transform(of: members[1], in: pair.a.state).tx == 40)
        // Restore (the review's action) brings the live group back beside the path.
        try pair.a.perform(OpsCommand("Restore", ops: [Ops.setDeleted(group, false)]))
        pair.sync()
        #expect(pair.b.state.isLive(group) && pair.b.state.isLive(path))
        #expect(Objects.parent(of: group, in: pair.b.state) == Objects.parent(of: path, in: pair.b.state))
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }
}
