import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto

/// kbd:[Option]-drag resizing in printer-resolution steps (IMG-004's remainder, IMG-017's Done
/// when; bitmaps.adoc).
@Suite struct ImageResolutionTests {
    @Test func a300PpiImageOnA600DpiDocumentSnapsToWholeFractions() {
        #expect(ImageResolution.baseScale(ppi: 300, printer: 600) == 1)
        let snaps = [0.98, 0.52, 0.34, 0.26, 0.4].map { ImageResolution.snapped($0, ppi: 300, printer: 600) }
        #expect(snaps.map { ($0 * 1000).rounded() / 10 } == [100, 50, 33.3, 25, 33.3])
        #expect(ImageResolution.snapped(0.45, ppi: 300, printer: 600) == 0.5)
        #expect(ImageResolution.snapped(1.7, ppi: 300, printer: 600) == 2)
        #expect(ImageResolution.snapped(1.2, ppi: 300, printer: 600) == 1)
        #expect(ImageResolution.snapped(0, ppi: 300, printer: 600) == 1)
        #expect(ImageResolution.snapped(.nan, ppi: 300, printer: 600) == 1)
    }

    @Test func otherResolutionsStartFromTheLargestStepNotAbove100Percent() {
        // 250 ppi on 600 dpi: effective 300 (= 600 / 2) at 83.3%.
        #expect(abs(ImageResolution.baseScale(ppi: 250, printer: 600) - 250.0 / 300) < 1e-12)
        #expect(abs(ImageResolution.snapped(0.4, ppi: 250, printer: 600) - 250.0 / 600) < 1e-12)
        // Finer than the printer: 100% is the base.
        #expect(ImageResolution.baseScale(ppi: 1200, printer: 600) == 1)
        #expect(ImageResolution.baseScale(ppi: 0, printer: 600) == 1 && ImageResolution.baseScale(ppi: 300, printer: .infinity) == 1)
    }

    @Test func anImagesScaleAndEffectiveResolutionReadThroughItsTransformChain() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["Art"], on: &a)[0]
        var props = Wiretuner_Doc_V1_NodeProps()
        props.image.dpiX = 300
        props.image.dpiY = 300
        props.image.common.transform = PathEditing.proto(.scale(x: 0.5, y: 0.5))
        let image = try a.perform(OpsCommand("Image", ops: [Ops.create(parent: layer, position: [0x80], props: props)]))!.createdNodes[0]
        #expect(ImageResolution.naturalPPI(of: image, in: a.state) == 300)
        #expect(ImageResolution.scale(of: image, in: a.state) == 0.5)
        #expect(ImageResolution.effectivePPI(of: image, in: a.state) == 600)
        try a.perform(SetPrinterResolution(600))
        #expect(ImageResolution.snapped(0.3, for: image, in: a.state).map { ($0 * 1000).rounded() } == 333)
        // dpi 0 reads as 72; anything but an image answers nil.
        var bare = Wiretuner_Doc_V1_NodeProps()
        bare.image = .init()
        let plain = try a.perform(OpsCommand("Image", ops: [Ops.create(parent: layer, position: [0x90], props: bare)]))!.createdNodes[0]
        #expect(ImageResolution.naturalPPI(of: plain, in: a.state) == 72)
        #expect(ImageResolution.naturalPPI(of: layer, in: a.state) == nil && ImageResolution.scale(of: layer, in: a.state) == nil)
        #expect(ImageResolution.effectivePPI(of: layer, in: a.state) == nil && ImageResolution.snapped(1, for: layer, in: a.state) == nil)
    }
}
