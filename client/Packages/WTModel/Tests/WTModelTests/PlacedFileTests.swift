import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Placed files in the scene and their merge test (IMG-011, import-formats.adoc): the preview
/// drawn over the bounding box with the gray box as its fallback, or the gray box alone.
@Suite struct PlacedFileTests {
    static func content(preview: [UInt8] = [], name: String = "art.eps", bounds: Rect = Rect(x: 0, y: 0, width: 200, height: 150)) -> Wiretuner_Doc_V1_PlacedFileContent {
        var content = Wiretuner_Doc_V1_PlacedFileContent()
        content.format = .eps
        content.blobSha256 = Data(repeating: 0xAB, count: 32)
        content.sourceName = name
        content.bounds.x = bounds.minX
        content.bounds.y = bounds.minY
        content.bounds.width = bounds.width
        content.bounds.height = bounds.height
        if !preview.isEmpty {
            content.previewSha256 = Data(preview)
            content.previewWidth = 400
            content.previewHeight = 300
        }
        return content
    }

    /// A placed file on a fresh layer of `replica`, moved to (10, 20).
    static func place(_ replica: inout Replica, content: Wiretuner_Doc_V1_PlacedFileContent) throws -> OpID {
        var layerProps = Fixture.layer(name: "L")
        layerProps.layer.visible = true
        layerProps.layer.printing = true
        let layer = try replica.perform(OpsCommand("Layer", ops: [Ops.create(parent: WellKnown.layers, position: [0x80], props: layerProps)]))!.createdNodes[0]
        var props = Wiretuner_Doc_V1_NodeProps()
        props.placedFile.content = content
        props.placedFile.common.transform = PathEditing.proto(AffineTransform.translation(x: 10, y: 20))
        return try replica.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0x80], props: props)]))!.createdNodes[0]
    }

    @Test func aPlacedFileWithAPreviewDrawsItOverItsBoundsWithTheGrayBoxBehind() throws {
        var replica = Replica(3)
        let preview = (0..<32).map { UInt8($0) }
        let node = try Self.place(&replica, content: Self.content(preview: preview))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(replica.state)
        let object = try #require(scene.object(node))
        #expect(object.kind == .placedFile && object.transform == .translation(x: 10, y: 20))
        guard case .image(let image) = object.item else { Issue.record("image"); return }
        #expect(image.assetID == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        #expect(image.rect == Rect(x: 0, y: 0, width: 200, height: 150))
        #expect(image.transform == .translation(x: 10, y: 20))
        #expect(image.name == "art.eps" && image.fallback != nil)
        #expect(object.bounds == Rect(x: 10, y: 20, width: 200, height: 150))
        let placed = PlacedFiles.placedFile(replica.state.props(node).placedFile, transform: .identity)
        #expect(placed.previewWidth == 400 && placed.previewHeight == 300)
        #expect(Objects.bounds(of: node, in: replica.state) == Rect(x: 10, y: 20, width: 200, height: 150))
    }

    @Test func withoutAPreviewItDrawsTheGrayBoxAndAZeroBoxReadsAsAnInch() throws {
        var replica = Replica(3)
        let node = try Self.place(&replica, content: Self.content(bounds: Rect(x: 5, y: 5, width: 0, height: 0)))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let object = try #require(builder.rebuild(replica.state).object(node))
        guard case .group(let group) = object.item else { Issue.record("gray box"); return }
        #expect(group.atomic)
        #expect(object.bounds == Rect(x: 15, y: 25, width: 72, height: 72))
        #expect(PlacedFiles.placedFile(replica.state.props(node).placedFile, transform: .identity).previewAssetID == nil)
    }

    @Test func updateFromSourceReplacesTheContentAndRedraws() throws {
        var replica = Replica(3)
        let node = try Self.place(&replica, content: Self.content())
        var builder = DocumentDisplayListBuilder(canvas: "c")
        builder.rebuild(replica.state)
        let change = try replica.perform(UpdatePlacedFile(node, content: Self.content(preview: [UInt8](repeating: 1, count: 32), name: "v2.eps")))!
        #expect(change.label == "Update from Source")
        #expect(change.ops[0].set.paths.map { RegisterPath($0) } == [PlacedFileFields.content])
        let (scene, summary) = builder.apply(change, state: replica.state, origin: .local)
        #expect(summary.touchedNodes.contains(NodeID(node)))
        guard case .image(let image)? = scene.object(node)?.item else { Issue.record("image"); return }
        #expect(image.name == "v2.eps")
        let layer = replica.state.liveChildren(WellKnown.layers)[0]
        #expect(throws: ObjectEditError.notAnObject(layer)) {
            try replica.perform(UpdatePlacedFile(layer, content: Self.content()))
        }
    }

    @Test func concurrentTransformAndUpdateFromSourceKeepBoth() throws {
        var pair = Pair()
        let node = try Self.place(&pair.a, content: Self.content())
        pair.sync()
        try pair.a.perform(MoveObjects([node], by: Vector(dx: 30, dy: 0)))
        try pair.b.perform(UpdatePlacedFile(node, content: Self.content(preview: [UInt8](repeating: 7, count: 32), name: "v2.eps",
                                                                          bounds: Rect(x: 0, y: 0, width: 100, height: 50))))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let props = pair.a.state.props(node).placedFile
        #expect(PathEditing.transform(props.common.transform) == .translation(x: 40, y: 20))
        #expect(props.content.sourceName == "v2.eps" && props.content.bounds.width == 100)
        var builder = DocumentDisplayListBuilder(canvas: "c")
        #expect(builder.rebuild(pair.b.state).object(node)?.bounds == Rect(x: 40, y: 20, width: 100, height: 50))
    }

    @Test func concurrentUpdatesFromSourceKeepOneWholeContent() throws {
        var pair = Pair()
        let node = try Self.place(&pair.a, content: Self.content())
        pair.sync()
        let a = try pair.a.perform(UpdatePlacedFile(node, content: Self.content(name: "a.eps", bounds: Rect(x: 0, y: 0, width: 10, height: 10))))!
        let b = try pair.b.perform(UpdatePlacedFile(node, content: Self.content(preview: [UInt8](repeating: 2, count: 32), name: "b.eps")))!
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let content = pair.a.state.props(node).placedFile.content
        let aWins = OpID(counter: a.startCounter, replica: a.replica) > OpID(counter: b.startCounter, replica: b.replica)
        #expect(content == (aWins ? Self.content(name: "a.eps", bounds: Rect(x: 0, y: 0, width: 10, height: 10))
                                  : Self.content(preview: [UInt8](repeating: 2, count: 32), name: "b.eps")))
    }
}
