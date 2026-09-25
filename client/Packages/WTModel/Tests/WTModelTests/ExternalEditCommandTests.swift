import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// IMG-019: an externally edited image keeps its placed width; Cancel restores the original.
@Suite struct ExternalEditCommandTests {
    @Test func aSaveKeepsTheWidthAndRecomputesTheHeight() throws {
        var a = Replica(0xA)
        let image = try ImageCommandsTests.place(&a)
        let before = ImageNodes.naturalRect(a.state.props(image).image)
        #expect(before.width == 150 && before.height == 75)
        let blob = ImportedBlob(data: Data([1, 2, 3]), uti: "public.png")
        let edited = EditedImagePixels.source(ImportedPixels(blob: blob, width: 200, height: 200, mode: .rgb, bitsPerChannel: 8, hasAlpha: true))
        #expect(edited.blobSha256 == blob.sha256 && edited.format == "public.png" && edited.mode == .rgb && edited.hasAlpha_p)
        let change = try #require(try a.perform(ReplaceEditedImage(image, pixels: edited)))
        #expect(change.label == "Edit Image")
        let after = ImageNodes.naturalRect(a.state.props(image).image)
        #expect(abs(after.width - 150) < 1e-9 && abs(after.height - 150) < 1e-9 && a.state.props(image).image.dpiX == 96)
        // Cancel: the original pixels and resolution.
        let original = ImageCommandsTests.pixels()
        try a.perform(ReplaceEditedImage(image, pixels: original, dpi: (144, 144)))
        #expect(a.state.props(image).image.pixels == original && ImageNodes.naturalRect(a.state.props(image).image) == before)
        #expect(throws: ImageEditError.invalidValue("dpi")) { try a.perform(ReplaceEditedImage(image, pixels: original, dpi: (0, 1))) }
        #expect(throws: ImageEditError.invalidValue("pixels.blob_sha256")) { try a.perform(ReplaceEditedImage(image, pixels: Wiretuner_Doc_V1_PixelSource())) }
    }

    @Test func anExternalEditAndACropBothApply() throws {
        var pair = Pair()
        let image = try ImageCommandsTests.place(&pair.a)
        pair.sync()
        let edited = ImageCommandsTests.pixels(width: 600, height: 300, fill: 0xCD)
        try pair.a.perform(ReplaceEditedImage(image, pixels: edited))
        try pair.b.perform(SetImageSetting([image], .crop(Rect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))))
        pair.sync()
        for replica in [pair.a, pair.b] {
            let props = replica.state.props(image).image
            #expect(props.pixels == edited && props.hasCrop)
        }
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
    }
}
