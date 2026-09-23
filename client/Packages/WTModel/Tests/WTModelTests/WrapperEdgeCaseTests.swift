import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FX-017 and FX-024 edge cases: wrappers across parents and transforms, hidden layers,
/// unpainted key objects and malformed stored values.
@Suite struct WrapperEdgeCaseTests {
    static func transformed(_ node: OpID, _ kind: UInt32, tx: Double, on replica: inout Replica) throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        let value = PathEditing.proto(.translation(x: tx, y: 0))
        switch kind {
        case 100: props.blend.common.transform = value
        case 101: props.extrude.common.transform = value
        default: props.layer.common.transform = value
        }
        try replica.perform(OpsCommand("Transform", ops: [Ops.set(node, [RegisterPath([kind, 1, 4])], values: props)]))
    }

    @Test func blendsAcrossLayersAndTransforms() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Low", "High"], on: &a)
        try Self.transformed(layers[1], 150, tx: 40, on: &a)
        let one = try LayerFixture.object(PathFixture.closed([(0, 0), (10, 0), (10, 10)]), on: &a)
        let two = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(50, 0), (60, 0), (60, 10)]))],
                                                     layer: layers[0]), on: &a)
        try a.perform(OpsCommand("To High", ops: [Ops.move(one, parent: layers[1], position: [0x80])]))
        try a.perform(Blend([one, two], layer: layers[0]))
        let blend = try #require(BlendCommandTests.blend(of: one, a.state))
        #expect(Objects.parent(of: blend, in: a.state) == layers[0], "from several parents: on top of the active layer")
        #expect(Objects.transform(of: one, in: a.state).tx == 40, "the member moved from the shifted layer keeps its place")
        // Stacking order and a blend point naming a contour that does not exist.
        try a.perform(EditBlend([blend], label: "Order", fields: [BlendFields.order]) { $0.order = .stacking })
        try a.perform(SetBlendPoint(blend, object: one, choice: BlendPointChoice(contour: OpID(counter: 5, replica: 5), point: OpID(counter: 6, replica: 6))))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        guard case .group(let group)? = builder.rebuild(a.state).object(blend)?.item, case .blend(let spec)? = group.live else { Issue.record("no blend"); return }
        #expect(spec.order == .stacking && spec.blendPoints.isEmpty, "a dangling blend point reads as unset")

        // Adding refuses what is not an object or cannot blend.
        let missing = OpID(counter: 999, replica: 9)
        #expect(throws: ObjectEditError.notAnObject(missing)) { try a.perform(AddToBlend(blend, missing)) }
        let composite = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, 50), (5, 50), (5, 55)])),
                                                                      NewContour(closed: true, points: PathFixture.points([(10, 50), (15, 50), (15, 55)]))]), on: &a)
        let group2 = try a.perform(GroupObjects([composite]))!.createdObjects[0]
        #expect(throws: WrapperError.notBlendable(BlendEligibility.groupContents)) { try a.perform(AddToBlend(blend, group2)) }

        // The blend's own transform is baked into what leaves it.
        try Self.transformed(blend, 100, tx: 7, on: &a)
        let spine = try LayerFixture.object(PathFixture.open([(0, 100), (100, 100)]), on: &a)
        try a.perform(JoinBlendToPath(blend, path: spine))
        try a.perform(SplitBlend([blend]))
        // Drawn on the shifted layer: joining and splitting keep it where it is on the page.
        #expect(Objects.transform(of: spine, in: a.state).tx == 40)
        let before = Objects.transform(of: two, in: a.state).tx
        try a.perform(ReleaseBlend([blend, one]))
        #expect(Objects.transform(of: two, in: a.state).tx == before + 7)
        #expect(try a.perform(ReleaseBlend([])) == nil)
        #expect(try a.perform(ReleaseExtrusion([])) == nil)
    }

    @Test func releaseWithBlendPointsHiddenLayersAndUnpaintedKeys() throws {
        var a = Replica(0xA)
        let one = try BlendCommandTests.square(&a, x: 0)
        let two = try BlendCommandTests.square(&a, x: 100, red: 0)
        let points = [one, two].map { node -> BlendPointChoice in
            let contour = a.path(node).contours[0]
            return BlendPointChoice(contour: contour.id, point: contour.drawn[1].id)
        }
        try a.perform(Blend([one, two], points: [one: points[0], two: points[1]]))
        let blend = BlendCommandTests.blend(of: one, a.state)!
        try a.perform(EditBlend.steps([blend], 3))
        let parent = Objects.parent(of: blend, in: a.state)!
        try a.perform(ReleaseBlend([blend]))
        let groups = a.state.liveChildren(parent).filter { a.state.nodeKind($0) == .group }
        #expect(groups.count == 1 && a.state.liveChildren(groups[0]).count == 3)
        a.undo()

        // On a hidden layer nothing is drawn, so nothing is baked; the key objects still leave.
        try a.perform(SetLayerFlag([parent], .visible, false))
        try a.perform(ReleaseBlend([blend]))
        #expect(a.state.liveChildren(parent).filter { a.state.nodeKind($0) == .group }.isEmpty && BlendCommandTests.blend(of: one, a.state) == nil)

        // Key objects that paint nothing leave no steps.
        var b = Replica(0xB)
        let bare = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, 0), (5, 0), (5, 5)]))],
                                                      appearance: Wiretuner_Doc_V1_AppearanceProps()), on: &b)
        let bare2 = try LayerFixture.object(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(20, 0), (25, 0), (25, 5)]))],
                                                       appearance: Wiretuner_Doc_V1_AppearanceProps()), on: &b)
        try b.perform(Blend([bare, bare2]))
        let bareBlend = BlendCommandTests.blend(of: bare, b.state)!
        let bareParent = Objects.parent(of: bareBlend, in: b.state)!
        try b.perform(ReleaseBlend([bareBlend]))
        #expect(b.state.liveChildren(bareParent).filter { b.state.nodeKind($0) == .group }.isEmpty)
        #expect(BlendBaking.flat([]).isEmpty)
    }

    @Test func extrusionsWithTransformsAndHiddenLayers() throws {
        var a = Replica(0xA)
        let path = try ExtrudeCommandTests.square(&a)
        try a.perform(Extrude([path], vanishingPoint: .zero))
        let wrapper = ExtrudeCommandTests.wrapper(of: path, a.state)!
        try Self.transformed(wrapper, 101, tx: 12, on: &a)
        try a.perform(RemoveExtrusion([path]))
        #expect(Objects.transform(of: path, in: a.state).tx == 12)
        a.undo()
        let layer = Objects.parent(of: wrapper, in: a.state)!
        try a.perform(SetLayerFlag([layer], .visible, false))
        let release = try a.perform(ReleaseExtrusion([wrapper]))!
        let group = ColorFixture.created(release)[0]
        #expect(a.state.liveChildren(group).isEmpty && !a.state.isLive(wrapper))
    }

    @Test func storedValuesReadDefensively() {
        // Blend points: malformed elements are skipped; of two for one object the greater id wins.
        let object = OpID(counter: 1, replica: 1)
        func point(_ id: UInt64, _ p: UInt64) -> Wiretuner_Doc_V1_BlendPoint {
            var point = Wiretuner_Doc_V1_BlendPoint()
            point.id = OpID(counter: id, replica: 1).elementID
            point.object = object.proto
            point.contour = OpID(counter: 50, replica: 1).elementID
            point.point = OpID(counter: p, replica: 1).elementID
            return point
        }
        var props = Wiretuner_Doc_V1_BlendProps()
        var broken = point(9, 1)
        broken.clearPoint()
        props.blendPoints = [point(3, 30), point(2, 20), broken, point(4, 40)]
        let read = BlendReading.points(props)
        #expect(read.count == 1 && read[0].point.point == OpID(counter: 40, replica: 1))
        // Anchors: past a first contour, in a second; a missing contour reads nil.
        func points(_ base: UInt64, _ coordinates: [(Double, Double)]) -> [VectorPoint] {
            coordinates.enumerated().map { VectorPoint(id: OpID(counter: base + UInt64($0.offset), replica: 2), anchor: Point(x: $0.element.0, y: $0.element.1)) }
        }
        let first = VectorContour(id: OpID(counter: 10, replica: 2), closed: true, points: points(20, [(0, 0), (1, 0), (1, 1)]))
        let second = VectorContour(id: OpID(counter: 11, replica: 2), closed: true, points: points(30, [(5, 5), (6, 5), (6, 6)]))
        let path = VectorPath(contours: [first, second])
        #expect(BlendReading.anchor(path, contour: second.id, point: second.drawn[2].id) == CornerPoint(contour: 1, anchor: 2))
        #expect(BlendReading.anchor(path, contour: OpID(counter: 99, replica: 9), point: second.drawn[2].id) == nil)
        // A profile with a path but no kind reads None.
        var extrude = Wiretuner_Doc_V1_ExtrudeProps()
        extrude.profile.path = Subtrees.proto(VectorContour(closed: false, points: PathFixture.points([(0, 0), (3, 3)])))
        #expect(Wrappers.extrude(extrude).profile.kind == .none && Wrappers.extrude(extrude).profile.path != nil)
    }
}
