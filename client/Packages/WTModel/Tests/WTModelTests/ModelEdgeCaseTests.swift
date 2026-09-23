import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// The edges of the object, layer, stack and copy machinery: fallbacks, ties and degenerate input.
@Suite struct ModelEdgeCaseTests {
    struct Failure: Error {}

    @Test func fallbacks() throws {
        #expect(WTGeometry.AffineTransform.scale(0).inverse == .identity)
        #expect(WTGeometry.AffineTransform.scale(2).inverse == .scale(0.5))
        #expect(Wire.bytes { throw Failure() } == [])
        #expect(Objects.parentTransform(of: WellKnown.document, in: EngineState()) == .identity)
        #expect(TransformKind.allCases.map(\.title) == ["Move", "Rotate", "Scale", "Skew", "Reflect"])
        #expect(try Measure.parse("2p.5") == 24.5)
        // A tree without a kind has no transform to set.
        var bare = NodeTree(props: Wiretuner_Doc_V1_NodeProps())
        bare.transform = .scale(2)
        #expect(bare.transform == .identity && bare.kind == nil)
        var layer = NodeTree(props: Wiretuner_Doc_V1_NodeProps.with { $0.layer.visible = true })
        layer.transform = .translation(x: 1, y: 2)
        #expect(layer.transform == .translation(x: 1, y: 2) && layer.kind == .layer)
        layer.transform = .identity
        #expect(!layer.props.layer.common.hasTransform)
    }

    @Test func copiesScaleEveryKindsStrokes() throws {
        var a = Replica(0xA)
        let path = try LayerFixture.object(PathFixture.open([(0, 0), (10, 0)]), on: &a)
        let ellipse = try LayerFixture.object(CreateShape(.ellipse, size: Size(width: 5, height: 5)), on: &a)
        let polygon = try LayerFixture.object(CreatePolygon(PolygonShape(sides: 5, radius: 5), center: .zero), on: &a)
        let change = try a.perform(TransformObjects([path, ellipse, polygon], matrix: .scale(3), kind: .scale, options: TransformOptions(strokes: true), copies: 1))!
        for copy in change.createdRoots {
            #expect(NodeValues.appearance(a.state.props(copy))?.strokes.first?.settings.basic.width == 3)
        }
        #expect(TransformObjects.scaledStrokes(Wiretuner_Doc_V1_NodeProps(), by: 2) == Wiretuner_Doc_V1_NodeProps())
    }

    @Test func arrangeAtTheEndsOfTheStack() throws {
        var a = Replica(0xA)
        let n = try ArrangeTests.row(3, on: &a)
        let layer = Objects.parent(of: n[0], in: a.state)!
        try a.perform(Arrange([n[1]], .bringForward))
        #expect(a.state.liveChildren(layer) == [n[0], n[2], n[1]])
        try a.perform(Arrange([n[2]], .sendBackward))
        #expect(a.state.liveChildren(layer) == [n[2], n[0], n[1]])
        // A clip path that is not the bottom member sets no floor below it.
        let group = try a.perform(GroupObjects(n))!.createdObjects[0]
        var clip = Wiretuner_Doc_V1_NodeProps()
        clip.group.kind = .clip
        clip.group.clipPath.id = n[1].proto
        try a.perform(OpsCommand("clip", ops: [Ops.set(group, [RegisterPath([50, 2]), RegisterPath([50, 4])], values: clip)]))
        try a.perform(Arrange([n[0]], .sendToBack))
        #expect(a.state.liveChildren(group).first == n[0])
        // A deleted clip path clips nothing.
        try a.perform(OpsCommand("delete", ops: [Ops.setDeleted(n[1])]))
        #expect(Arranging.clipPath(of: group, in: a.state) == nil)
    }

    @Test func layerTiesAndDeadTargets() throws {
        var a = Replica(0xA)
        // Two layers at one position (ties break by id).
        let ops = ["One", "Two", "Three"].map { name -> Wiretuner_Doc_V1_Op in
            var props = Wiretuner_Doc_V1_NodeProps()
            props.layer.common.name = name
            props.layer.visible = true
            props.layer.printing = true
            return Ops.create(parent: WellKnown.layers, position: [0x80], props: props)
        }
        let ids = try a.perform(OpsCommand("layers", ops: ops))!.createdNodes
        try a.perform(ReorderLayer(ids[0], to: 1))
        #expect(LayerOrder(a.state).layers.count == 3)
        // New above a layer that is gone: at the top.
        try a.perform(DeleteLayerForTest(ids[2]))
        let fresh = try a.perform(CreateLayer(name: "Four", above: ids[2]))!.createdNodes[0]
        #expect(LayerOrder(a.state).layers.last?.id == fresh)
    }

    @Test func stackEdges() throws {
        var a = Replica(0xA)
        let rect = try LayerFixture.object(LayerFixture.rect(on: nil), on: &a)
        var brush = Wiretuner_Doc_V1_Stroke()
        brush.settings.kind = .brush
        try a.perform(AddAppearance.stroke([rect], brush))
        let ops = AppearanceEditing.scaleStrokeWidths(rect, kind: .rect, by: 2, state: a.state)
        #expect(ops.count == 1, "only the basic stroke's width")
        #expect(AppearanceEditing.scaleStrokeWidths(WellKnown.layers, kind: .rect, by: 2, state: a.state).isEmpty)
        #expect(AppearanceEditing.element(rect, AppearanceRow(.strokes, OpID(counter: 999, replica: 1)), in: a.state) == nil)
        #expect(AppearanceEditing.color(.rect, AppearanceRow(.effects, rect)) == nil)
    }

    @Test func stackingOrderOnADeletedLayer() throws {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["Base", "Sketch"], on: &a)
        let base = try LayerFixture.object(LayerFixture.rect(on: layers[0]), on: &a)
        let sketch = try LayerFixture.object(LayerFixture.rect(on: layers[1]), on: &a)
        try a.perform(DeleteLayerForTest(layers[1]))
        // Shown on the default layer, above its own objects.
        #expect(Objects.stackingOrder([sketch, base], in: a.state) == [base, sketch])
    }
}
