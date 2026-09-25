import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender
import WTText

/// WEB-015's objects attached to a path: releasing a text on a path gives each character a layer
/// and detaches the path (animation.adoc, "Releasing objects to layers").
@Suite @MainActor struct WebReleaseAttachedTests {
    @Test func releasingTextOnAPathDetachesThePathAndReleasesTheCharactersAlongIt() throws {
        var a = Replica(1)
        let (text, path) = try TextOnPathTests.pair(&a)
        try a.perform(MoveObjects([text], by: Vector(dx: 5, dy: 7)))
        try a.perform(AttachTextToPath(text: text, path: path))
        let pathBounds = try #require(Objects.bounds(of: path, in: a.state))
        let layer = try #require(Objects.parent(of: text, in: a.state))
        let fonts = DocumentFontIndex(state: a.state)
        let change = try #require(try a.perform(ReleaseToLayers([text], mode: .sequence, currentLayer: layer,
                                                                 textLayout: TextSceneLayout(engine: fonts.layoutEngine))))
        #expect(change.label == "Release to Layers")
        #expect(!a.state.isLive(text))
        // The path is detached: live, beside where the text was, in the same place on the page.
        #expect(a.state.isLive(path) && Objects.parent(of: path, in: a.state) == layer)
        let after = try #require(Objects.bounds(of: path, in: a.state))
        #expect(abs(after.minX - pathBounds.minX) < 1e-9 && abs(after.minY - pathBounds.minY) < 1e-9)
        // One frame per character with ink ("Around": six), each a path.
        let order = LayerOrder(a.state)
        let frames = order.layers.filter { $0.name.hasPrefix("Frame") }
        #expect(frames.count == 6)
        #expect(frames.allSatisfy { frame in order.objects(on: frame.id, in: a.state).allSatisfy { a.state.nodeKind($0) == .path } })
        // Undo restores the text on its path and removes the frames in one step.
        a.undo()
        #expect(a.state.isLive(text) && Objects.parent(of: path, in: a.state) == text)
        #expect(LayerOrder(a.state).layers.filter { $0.name.hasPrefix("Frame") }.isEmpty)
    }

    @Test func aTextNotOnAPathHasNothingToDetach() throws {
        var a = Replica(1)
        let text = try TextFixture.block(&a, "Hi", at: Point(x: 0, y: 0))
        var builder = ChangeBuilder(replica: 1, startCounter: 100)
        try ReleaseToLayers.detachPaths(of: text, state: a.state, builder: &builder)
        try ReleaseToLayers.detachPaths(of: OpID(counter: 999, replica: 9), state: a.state, builder: &builder)
        #expect(builder.ops.isEmpty)
    }
}
