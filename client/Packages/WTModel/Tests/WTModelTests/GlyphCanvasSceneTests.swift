import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// FONT-003's hook in `DocumentDisplayListBuilder`: a builder draws the top-level objects of its
/// `canvasNode` (`CanvasMembership`), so a glyph canvas shows its glyph's artwork and the main
/// pasteboard everything else (typeface-documents.adoc, "Read-time normalizations").
@Suite struct GlyphCanvasSceneTests {
    private func builder(_ canvas: OpID?, _ state: EngineState) -> DocumentDisplayListBuilder {
        var builder = DocumentDisplayListBuilder(canvas: CanvasID(canvas.map { "\($0)" } ?? "main"))
        builder.canvasNode = canvas
        builder.rebuild(state)
        return builder
    }

    @Test func eachCanvasDrawsItsOwnObjects() throws {
        var a = Replica(0xA)
        let index = try TypefaceFixture.typeface(&a)
        let glyphA = try #require(index.glyph(named: "A")).id
        let glyphB = try #require(index.glyph(named: "B")).id
        let onA = try TypefaceFixture.box(10, -600, 100, 600, on: glyphA, in: &a)
        let onB = try TypefaceFixture.box(20, -500, 50, 500, on: glyphB, in: &a)
        let sketch = try TypefaceFixture.box(1_000, 1_000, 40, 40, on: nil, in: &a)
        let main = builder(nil, a.state)
        #expect(main.scene.topLevel == [NodeID(sketch)])
        #expect(builder(glyphA, a.state).scene.topLevel == [NodeID(onA)])
        #expect(builder(glyphB, a.state).scene.topLevel == [NodeID(onB)])
        // The glyph canvas's output (export, printing) is its own artwork too.
        var glyphBuilder = builder(glyphA, a.state)
        #expect(glyphBuilder.outputDisplayList(a.state).nodeIDs.compactMap { $0 } == [NodeID(onA)])
    }

    @Test func aChangeMovesObjectsBetweenCanvases() throws {
        var a = Replica(0xA)
        let index = try TypefaceFixture.typeface(&a)
        let glyph = try #require(index.glyph(named: "A")).id
        let object = try TypefaceFixture.box(10, -600, 100, 600, on: nil, in: &a)
        var main = builder(nil, a.state)
        var canvas = builder(glyph, a.state)
        #expect(main.scene.topLevel == [NodeID(object)] && canvas.scene.topLevel.isEmpty)
        // Placing it on the glyph: it leaves the pasteboard and appears on the glyph canvas.
        try TypefaceFixture.place(object, on: glyph, in: &a)
        let place = try #require(a.sent.last)
        _ = main.apply(place, state: a.state, origin: .local)
        _ = canvas.apply(place, state: a.state, origin: .local)
        #expect(main.scene.topLevel.isEmpty && canvas.scene.topLevel == [NodeID(object)])
        // Removing the glyph alone (objects drawn concurrently keep their canvas): they read on
        // the Sketches pasteboard, and restoring the glyph re-attaches them.
        try a.perform(OpsCommand("Remove glyph", ops: [Ops.setDeleted(glyph, true)]))
        let removal = try #require(a.sent.last)
        _ = main.apply(removal, state: a.state, origin: .remote)
        _ = canvas.apply(removal, state: a.state, origin: .remote)
        #expect(main.scene.topLevel == [NodeID(object)] && canvas.scene.topLevel.isEmpty)
        try a.perform(RestoreGlyph(glyph))
        let restore = try #require(a.sent.last)
        _ = main.apply(restore, state: a.state, origin: .remote)
        _ = canvas.apply(restore, state: a.state, origin: .remote)
        #expect(main.scene.topLevel.isEmpty && canvas.scene.topLevel == [NodeID(object)])
    }

    @Test func glyphArtworkIsHiddenInAnIllustrationDocument() throws {
        var a = Replica(0xA)
        let index = try TypefaceFixture.typeface(&a)
        let glyph = try #require(index.glyph(named: "A")).id
        let object = try TypefaceFixture.box(10, -600, 100, 600, on: glyph, in: &a)
        try a.perform(ConvertDocumentKind(to: .multiPage))
        #expect(builder(nil, a.state).scene.topLevel.isEmpty)
        #expect(builder(glyph, a.state).scene.topLevel.isEmpty)
        #expect(builder(glyph, a.state).scene.objects[NodeID(object)] == nil)
    }

    @Test func groupMembersFollowTheirTopLevelObject() throws {
        var a = Replica(0xA)
        let index = try TypefaceFixture.typeface(&a)
        let glyph = try #require(index.glyph(named: "A")).id
        let first = try TypefaceFixture.box(0, -100, 10, 10, on: nil, in: &a)
        let second = try TypefaceFixture.box(20, -100, 10, 10, on: nil, in: &a)
        let group = try #require(try a.perform(GroupObjects([first, second]))?.createdObjects.first)
        try TypefaceFixture.place(group, on: glyph, in: &a)
        let canvas = builder(glyph, a.state)
        #expect(canvas.scene.topLevel == [NodeID(group)])
        #expect(canvas.scene.objects[NodeID(first)] != nil && canvas.scene.objects[NodeID(second)] != nil)
        #expect(builder(nil, a.state).scene.objects[NodeID(first)] == nil)
    }

    @Test func aMemberNamingAnotherCanvasIsLeftOut() throws {
        var a = Replica(0xA)
        let index = try TypefaceFixture.typeface(&a)
        let glyphA = try #require(index.glyph(named: "A")).id
        let glyphB = try #require(index.glyph(named: "B")).id
        let first = try TypefaceFixture.box(0, -100, 10, 10, on: nil, in: &a)
        let second = try TypefaceFixture.box(20, -100, 10, 10, on: nil, in: &a)
        let group = try #require(try a.perform(GroupObjects([first, second]))?.createdObjects.first)
        try TypefaceFixture.place(group, on: glyphA, in: &a)
        // A member carrying another glyph's canvas (an older client) is not drawn in this group.
        try TypefaceFixture.place(second, on: glyphB, in: &a)
        let canvas = builder(glyphA, a.state)
        #expect(canvas.scene.objects[NodeID(first)] != nil && canvas.scene.objects[NodeID(second)] == nil)
    }
}
