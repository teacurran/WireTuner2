import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// OBJ-015's model half: a Copy's selection as the interchange formats' scene, beside the native
/// payload; a foreign paste placed through the import path.
@Suite struct ClipboardFormatsTests {
    @Test func aCopyOffersTheSelectionInEveryEnabledFormat() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Art"], on: &a)[0]
        let left = try LayerFixture.object(LayerFixture.rect(on: layer, x: 0, size: 20), on: &a)
        _ = try LayerFixture.object(LayerFixture.rect(on: layer, x: 100, size: 20), on: &a)
        let builder = DocumentDisplayListBuilder(canvas: "clipboard")
        let writer = ClipboardExport.writer(copying: [left], in: a.state, document: "doc-1", builder: builder, blob: { _ in nil })
        // One page cropped to the selected rectangle alone (the other is left out).
        #expect(writer.scene.pages.count == 1)
        let bounds = try #require(writer.scene.pages.first?.bounds)
        #expect(bounds.width < 30 && bounds.maxX < 30)
        #expect(writer.types == ["com.villagecompute.wiretuner.objects", "com.adobe.pdf", "public.svg-image", "public.tiff", "public.png"])
        let native = try #require(try writer.data(for: ClipboardFormat.nativeType))
        let payload = try #require(ClipboardPayload(decoding: Array(native)))
        #expect(payload.nodes.count == 1 && payload.sourceDocument == "doc-1")
        // The PDF copy pastes back as an editable path through the import path.
        let pdf = try #require(try writer.data(for: ClipboardFormat.pdfType))
        let scene = try ClipboardReader.read(.pdf, types: writer.types) { $0 == ClipboardFormat.pdfType ? pdf : nil }
        let change = try #require(try a.perform(PlaceImportedScene(scene, placement: .at(Point(x: 300, y: 300)), layer: layer)))
        #expect(change.createdObjects.contains { a.state.nodeKind($0) == .path })
    }

    @Test func textIsOfferedAsRichAndPlainTextAndNothingSelectedOffersNothing() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Art"], on: &a)
        let text = try TextFixture.block(&a, "Hello", at: Point(x: 10, y: 10))
        // With a rectangle, so the page exists without the window's text layout.
        let box = try LayerFixture.object(LayerFixture.rect(on: nil, x: 0, size: 20), on: &a)
        let writer = ClipboardExport.writer(copying: [text, box], in: a.state, builder: DocumentDisplayListBuilder(canvas: "clipboard"),
                                            settings: ClipboardSettings().setting(.image, enabled: false), blob: { _ in nil })
        #expect(writer.formats.contains(.rtf) && writer.formats.contains(.plainText) && !writer.formats.contains(.image))
        #expect(try writer.data(for: ClipboardFormat.plainTextType).map { String(decoding: $0, as: UTF8.self) } == "Hello")
        // A node that is not an object carries nothing.
        let none = ClipboardExport.writer(copying: [WellKnown.settings], in: a.state, builder: DocumentDisplayListBuilder(canvas: "clipboard"), blob: { _ in nil })
        #expect(none.native == nil && none.formats.isEmpty)
    }
}
