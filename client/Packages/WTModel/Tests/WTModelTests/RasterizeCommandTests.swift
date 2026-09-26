import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// IMG-020 and IMG-024: *Optimize Image* and *Rasterize* as one change each.
@Suite struct RasterizeCommandTests {
    static func pixels(width: Int = 300, height: Int = 150, mode: ImportedColorMode = .rgb, alpha: Bool = true, seed: UInt8 = 1) -> ImportedPixels {
        ImportedPixels(blob: ImportedBlob(data: Data([seed, 2, 3]), uti: "public.png"), width: width, height: height, mode: mode, bitsPerChannel: 8, hasAlpha: alpha)
    }

    @Test func pixelSourceCarriesTheFacts() {
        let source = Self.pixels(mode: .grayscale, alpha: false).pixelSource
        #expect(source.blobSha256.count == 32 && source.format == "public.png" && source.pixelWidth == 300 && source.pixelHeight == 150)
        #expect(source.mode == .grayscale && source.bitsPerChannel == 8 && !source.hasAlpha_p)
    }

    @Test func optimizingSeveralImagesIsOneChangeThatKeepsTheirPlacedSize() throws {
        var replica = Replica(3)
        let a = try ImageCommandsTests.place(&replica)
        let b = try ImageCommandsTests.place(&replica)
        try replica.perform(SetImageSetting([a], .tint(ColorResolver.inline(Color(red: 1, green: 0, blue: 0)))))
        let before = Objects.bounds(of: a, in: replica.state)
        let change = try #require(try replica.perform(OptimizeImages([(a, Self.pixels(width: 150, height: 75, mode: .grayscale)), (b, Self.pixels(width: 100, height: 50))])))
        #expect(change.label == "Optimize (2 images)" && change.ops.count == 2)
        #expect(replica.state.props(a).image.pixels.mode == .grayscale && replica.state.props(a).image.dpiX == 72)
        // The tint stays and now applies (grayscale enables tinting).
        #expect(replica.state.props(a).image.hasTint)
        #expect(Objects.bounds(of: a, in: replica.state) == before)
        replica.undo()
        #expect(replica.state.props(a).image.pixels == ImageCommandsTests.pixels() && replica.state.props(b).image.pixels == ImageCommandsTests.pixels())
        #expect(OptimizeImages([(a, Self.pixels())], names: ["photo.png"]).label == "Optimize photo.png")
        #expect(OptimizeImages([(a, Self.pixels())]).label == "Optimize Image")
    }

    /// Optimize on one replica and a concurrent tint on the other both survive.
    @Test func optimizeMergesWithAConcurrentTint() throws {
        var pair = Pair()
        let node = try ImageCommandsTests.place(&pair.a)
        pair.sync()
        try pair.a.perform(OptimizeImages([(node, Self.pixels(width: 150, height: 75, mode: .grayscale))]))
        try pair.b.perform(SetImageSetting([node], .tint(ColorResolver.inline(Color(red: 0, green: 0, blue: 1)))))
        pair.sync()
        #expect(pair.a.state.props(node) == pair.b.state.props(node))
        #expect(pair.a.state.props(node).image.pixels.mode == .grayscale && pair.a.state.props(node).image.hasTint)
    }

    static func image(bounds: Rect = Rect(x: 10, y: 20, width: 72, height: 36), ppi: Double = 300) -> RasterizedImage {
        RasterizedImage(pixels: pixels(width: Int(bounds.width / 72 * ppi), height: Int(bounds.height / 72 * ppi)), bounds: bounds, ppi: ppi)
    }

    @Test func rasterizeReplacesTheObjectsWithOneImageAndUndoRestoresThem() throws {
        var replica = Replica(3)
        let back = try #require(try replica.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 10)))).createdObjects[0]
        let front = try #require(try replica.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5)))).createdObjects[0]
        let above = try #require(try replica.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5)))).createdObjects[0]
        try replica.perform(SetNameOrNote([back], .name, "Logo"))
        let change = try #require(try replica.perform(RasterizeObjects([back, front], image: Self.image())))
        #expect(change.label == "Rasterize 2 objects")
        let image = change.createdObjects[0]
        let props = replica.state.props(image).image
        #expect(props.sourceName == "Rasterized Logo" && props.common.name == "Rasterized Logo" && props.dpiX == 300 && props.dpiY == 300)
        #expect(Objects.bounds(of: image, in: replica.state) == Rect(x: 10, y: 20, width: 72, height: 36))
        #expect(!replica.state.isLive(back) && !replica.state.isLive(front))
        // Directly above the topmost original, below the object that was above it.
        let order = Objects.stackingOrder([image, above], in: replica.state)
        #expect(order == [image, above])
        replica.undo()
        #expect(replica.state.isLive(back) && replica.state.isLive(front) && !replica.state.isLive(image))
        // *Keep originals* leaves them in place.
        let kept = try #require(try replica.perform(RasterizeObjects([front], image: Self.image(), keepOriginals: true)))
        #expect(kept.label == "Rasterize 1 object" && replica.state.isLive(front) && replica.state.isLive(kept.createdObjects[0]))
        #expect(replica.state.props(kept.createdObjects[0]).image.sourceName == "Rasterized Ellipse")
        #expect(throws: ObjectEditError.invalidValue("nodes")) { try replica.perform(RasterizeObjects([], image: Self.image())) }
        let layer = try #require(Objects.parent(of: front, in: replica.state))
        #expect(throws: ObjectEditError.notAnObject(layer)) { try replica.perform(RasterizeObjects([layer], image: Self.image())) }
    }

    /// A rasterizes while B edits one original: the edit lands on the deleted object on both,
    /// and restoring it brings it back beside the image everywhere.
    @Test func rasterizeVersusAConcurrentEdit() throws {
        var pair = Pair()
        let node = try #require(try pair.a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 10)))).createdObjects[0]
        pair.sync()
        let image = try #require(try pair.a.perform(RasterizeObjects([node], image: Self.image()))).createdObjects[0]
        try pair.b.perform(MoveObjects([node], by: Vector(dx: 5, dy: 5)))
        pair.sync()
        #expect(pair.a.state.props(node) == pair.b.state.props(node))
        #expect(!pair.a.state.isLive(node) && !pair.b.state.isLive(node) && pair.b.state.isLive(image))
        try pair.b.perform(OpsCommand("Restore", ops: [Ops.setDeleted(node, false)]))
        pair.sync()
        #expect(pair.a.state.isLive(node) && pair.a.state.isLive(image))
        #expect(Objects.bounds(of: node, in: pair.a.state) == Objects.bounds(of: node, in: pair.b.state))
    }
}
