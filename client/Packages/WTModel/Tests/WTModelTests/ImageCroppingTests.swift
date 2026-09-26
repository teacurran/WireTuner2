import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// IMG-025: the crop arithmetic, the crop and trim commands, and their merges; IMG-016's readings.
@Suite struct ImageCroppingTests {
    static func close(_ a: Rect, _ b: Rect, _ tolerance: Double = 1e-9) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    static let half = Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    @Test func eachHandleMovesItsEdgesAndStopsAtThePictureEdge() {
        let crop = Self.half
        #expect(Self.close(ImageCropping.resize(crop, handle: .left, by: Vector(dx: 0.1, dy: 0.3), proportional: false, symmetric: false),
                           Rect(x: 0.35, y: 0.25, width: 0.4, height: 0.5)))
        #expect(Self.close(ImageCropping.resize(crop, handle: .right, by: Vector(dx: 0.5, dy: 0), proportional: false, symmetric: false),
                           Rect(x: 0.25, y: 0.25, width: 0.75, height: 0.5)), "never beyond the picture's edge")
        #expect(Self.close(ImageCropping.resize(crop, handle: .top, by: Vector(dx: 0, dy: -1), proportional: false, symmetric: false),
                           Rect(x: 0.25, y: 0, width: 0.5, height: 0.75)))
        #expect(Self.close(ImageCropping.resize(crop, handle: .bottom, by: Vector(dx: 0, dy: -1), proportional: false, symmetric: false),
                           Rect(x: 0.25, y: 0.25, width: 0.5, height: ImageCropping.minimum)), "never through the opposite edge")
        #expect(Self.close(ImageCropping.resize(crop, handle: .topLeft, by: Vector(dx: -0.1, dy: 0.1), proportional: false, symmetric: false),
                           Rect(x: 0.15, y: 0.35, width: 0.6, height: 0.4)))
        #expect(Self.close(ImageCropping.resize(crop, handle: .bottomRight, by: Vector(dx: 0.1, dy: 0.2), proportional: false, symmetric: false),
                           Rect(x: 0.25, y: 0.25, width: 0.6, height: 0.7)))
        #expect(Self.close(ImageCropping.resize(crop, handle: .topRight, by: Vector(dx: 0.1, dy: -0.1), proportional: false, symmetric: false),
                           Rect(x: 0.25, y: 0.15, width: 0.6, height: 0.6)))
        #expect(Self.close(ImageCropping.resize(crop, handle: .bottomLeft, by: Vector(dx: 0.1, dy: 0.1), proportional: false, symmetric: false),
                           Rect(x: 0.35, y: 0.25, width: 0.4, height: 0.6)))
        #expect(ImageCropping.Handle.allCases.filter(\.isCorner).count == 4)
    }

    @Test func optionIsSymmetricAndShiftKeepsProportions() {
        let crop = Self.half
        // Option: the opposite edge moves the same amount the other way.
        #expect(Self.close(ImageCropping.resize(crop, handle: .left, by: Vector(dx: 0.1, dy: 0), proportional: false, symmetric: true),
                           Rect(x: 0.35, y: 0.25, width: 0.3, height: 0.5)))
        #expect(Self.close(ImageCropping.resize(crop, handle: .right, by: Vector(dx: 0.5, dy: 0), proportional: false, symmetric: true),
                           Rect(x: 0, y: 0.25, width: 1, height: 0.5)), "limited by the nearer picture edge")
        #expect(Self.close(ImageCropping.resize(crop, handle: .bottom, by: Vector(dx: 0, dy: -0.5), proportional: false, symmetric: true),
                           Rect(x: 0.25, y: 0.4995, width: 0.5, height: ImageCropping.minimum)))
        // Shift on a corner: the proportions stay (the larger factor wins).
        let proportional = ImageCropping.resize(crop, handle: .bottomRight, by: Vector(dx: 0.1, dy: 0.05), proportional: true, symmetric: false)
        #expect(Self.close(proportional, Rect(x: 0.25, y: 0.25, width: 0.6, height: 0.6)))
        #expect(Self.close(ImageCropping.resize(crop, handle: .topLeft, by: Vector(dx: -1, dy: -1), proportional: true, symmetric: false),
                           Rect(x: 0, y: 0, width: 0.75, height: 0.75)), "stops at the picture")
        #expect(Self.close(ImageCropping.resize(crop, handle: .topRight, by: Vector(dx: 0.05, dy: 0), proportional: true, symmetric: true),
                           Rect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)), "both: about the centre")
        #expect(Self.close(ImageCropping.resize(crop, handle: .bottomLeft, by: Vector(dx: 0.1, dy: -0.1), proportional: true, symmetric: false),
                           Rect(x: 0.35, y: 0.25, width: 0.4, height: 0.4)))
        // Shift on an edge handle is an ordinary drag.
        #expect(Self.close(ImageCropping.resize(crop, handle: .left, by: Vector(dx: 0.1, dy: 0), proportional: true, symmetric: false),
                           Rect(x: 0.35, y: 0.25, width: 0.4, height: 0.5)))
        let flat = Rect(x: 0.2, y: 0.2, width: 0.5, height: 0)
        #expect(ImageCropping.resize(flat, handle: .topLeft, by: Vector(dx: 0.1, dy: 0.1), proportional: true, symmetric: false) == flat)
    }

    @Test func slidingStaysInsideAndPixelsConvertBothWays() {
        #expect(Self.close(ImageCropping.slide(Self.half, by: Vector(dx: 0.1, dy: -0.1)), Rect(x: 0.35, y: 0.15, width: 0.5, height: 0.5)))
        #expect(Self.close(ImageCropping.slide(Self.half, by: Vector(dx: 2, dy: -2)), Rect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
        #expect(ImageCropping.pixels(Self.half, width: 400, height: 200) == Rect(x: 100, y: 50, width: 200, height: 100))
        #expect(ImageCropping.unit(fromPixels: Rect(x: 100, y: 50, width: 200, height: 100), width: 400, height: 200) == Self.half)
        #expect(ImageCropping.unit(fromPixels: Rect(x: -10, y: 0, width: 1000, height: 1000), width: 400, height: 200) == ImageCropping.full)
        #expect(ImageCropping.unit(fromPixels: Rect(x: 500, y: 0, width: 10, height: 10), width: 400, height: 200) == nil)
        #expect(ImageCropping.unit(fromPixels: Self.half, width: 0, height: 10) == nil)
        #expect(ImageCropping.stored(ImageCropping.full) == nil && ImageCropping.stored(Self.half) == Self.half)
        let trim = ImageCropping.trimRect(Rect(x: 0.101, y: 0.25, width: 0.5, height: 0.5), width: 300, height: 150)
        #expect(trim.x == 30 && trim.y == 37 && trim.width == 151 && trim.height == 76)
    }

    @Test func aPasteboardDragMapsThroughTheInverseTransform() {
        let natural = Rect(x: 0, y: 0, width: 200, height: 100)
        let scaled = WTGeometry.AffineTransform.scale(x: 2, y: 2).concatenating(.translation(x: 50, y: 50))
        let delta = ImageCropping.unitDelta(Vector(dx: 40, dy: 20), transform: scaled, natural: natural)
        #expect(abs(delta.dx - 0.1) < 1e-12 && abs(delta.dy - 0.1) < 1e-12)
        let rotated = WTGeometry.AffineTransform.rotation(radians: .pi / 2)
        let turned = ImageCropping.unitDelta(Vector(dx: 0, dy: 20), transform: rotated, natural: natural)
        #expect(abs(abs(turned.dx) - 0.1) < 1e-9 && abs(turned.dy) < 1e-9)
        #expect(ImageCropping.unitDelta(Vector(dx: 1, dy: 1), transform: .identity, natural: .zero) == Vector(dx: 0, dy: 0))
    }

    @Test func cropAndRemoveCropAreOneChangeEachWithTheImagesName() throws {
        var a = Replica(1)
        let image = try ImageCommandsTests.place(&a)
        #expect(ImageCropping.crop(of: image, in: a.state) == ImageCropping.full && !ImageCropping.isCropped(image, in: a.state))
        let change = try #require(try a.perform(CropImage([image], crop: Self.half, name: "photo.png")))
        #expect(change.label == "Crop photo.png" && change.ops.count == 1)
        #expect(ImageCropping.crop(of: image, in: a.state) == Self.half && ImageCropping.isCropped(image, in: a.state))
        // Bounds are the visible part.
        #expect(Objects.bounds(of: image, in: a.state) == Rect(x: 10 + 37.5, y: 20 + 18.75, width: 75, height: 37.5))
        // Sliding moves the picture behind a fixed window: the bounds stay.
        let slid = Rect(x: 0.35, y: 0.25, width: 0.5, height: 0.5)
        let slide = try #require(try a.perform(CropImage([image], crop: slid, slide: Vector(dx: -15, dy: 0), name: "photo.png")))
        #expect(slide.ops.count == 2)
        let bounds = try #require(Objects.bounds(of: image, in: a.state))
        #expect(Self.close(bounds, Rect(x: 47.5, y: 38.75, width: 75, height: 37.5), 1e-9))
        let remove = try #require(try a.perform(CropImage([image], crop: nil)))
        #expect(remove.label == "Remove Crop" && !ImageCropping.isCropped(image, in: a.state))
        #expect(CropImage([image], crop: ImageCropping.full).crop == nil, "the whole picture is no crop")
        #expect(CropImage([image, image], crop: Self.half).label == "Crop (2 images)")
        #expect(CropImage([image], crop: Self.half).label == "Crop")
        a.undo()
        #expect(ImageCropping.crop(of: image, in: a.state) == slid)
        #expect(ImageCropping.crop(of: OpID(counter: 999, replica: 1), in: a.state) == nil && !ImageCropping.isCropped(OpID(counter: 999, replica: 1), in: a.state))
        _ = try a.perform(CropImage([image], crop: slid, slide: Vector(dx: 0, dy: 0)))
    }

    @Test func trimToCropKeepsTheVisiblePixelsInPlace() throws {
        var a = Replica(1)
        let image = try ImageCommandsTests.place(&a)
        _ = try a.perform(CropImage([image], crop: Rect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)))
        let before = try #require(Objects.bounds(of: image, in: a.state))
        let kept = ImageCropping.trimRect(ImageCropping.crop(of: image, in: a.state)!, width: 300, height: 150)
        let change = try #require(try a.perform(TrimImageToCrop(image, pixels: ImageCommandsTests.pixels(width: Int32(kept.width), height: Int32(kept.height), fill: 1))))
        #expect(change.label == "Trim to Crop" && change.ops.count == 1)
        let after = try #require(Objects.bounds(of: image, in: a.state))
        #expect(Self.close(before, after, 0.5), "the visible pixels stay within half a point")
        #expect(!ImageCropping.isCropped(image, in: a.state) && a.state.props(image).image.pixels.pixelWidth == Int32(kept.width))
        #expect(throws: ImageEditError.self) { try a.perform(TrimImageToCrop(OpID(counter: 999, replica: 1), pixels: ImageCommandsTests.pixels())) }
    }

    @Test func aCropMergesWithAPixelReplacementAndTheLaterCropWins() throws {
        var pair = Pair()
        let image = try ImageCommandsTests.place(&pair.a)
        pair.sync()
        // A crops while B replaces the pixels with a larger picture: B's picture, A's proportion.
        try pair.a.perform(CropImage([image], crop: Self.half, name: "photo.png"))
        try pair.b.perform(ReplaceImagePixels(image, pixels: ImageCommandsTests.pixels(width: 600, height: 300, fill: 7)))
        pair.sync()
        for replica in [pair.a, pair.b] {
            #expect(replica.state.props(image).image.pixels.pixelWidth == 600 && ImageCropping.crop(of: image, in: replica.state) == Self.half)
            #expect(ImageDetails(image, in: replica.state)?.cropPixels == Rect(x: 150, y: 75, width: 300, height: 150))
        }
        // A crops while B crops: one crop on both.
        try pair.a.perform(CropImage([image], crop: Rect(x: 0, y: 0, width: 0.5, height: 1)))
        try pair.b.perform(CropImage([image], crop: Rect(x: 0.5, y: 0, width: 0.5, height: 1)))
        pair.sync()
        #expect(ImageCropping.crop(of: image, in: pair.a.state) == ImageCropping.crop(of: image, in: pair.b.state))
    }

    // MARK: IMG-016 readings

    @Test func theImageSectionReadsTheImage() throws {
        var a = Replica(1)
        let image = try ImageCommandsTests.place(&a, ImageCommandsTests.pixels(mode: .grayscale, alpha: true))
        let details = try #require(ImageDetails(image, in: a.state))
        #expect(details.kindLabel == "Image (Grayscale)" && details.pixelsText == "300 × 150, 8-bit" && details.modeText == "Grayscale, alpha")
        #expect(details.file == "photo.png" && details.isGray && details.hasPixels && !details.isCropped && details.displayAlpha)
        #expect(details.effectivePPI == 144 && !details.isBelow(144) && details.isBelow(150))
        #expect(details.placedSize == Size(width: 150, height: 75))
        #expect(ImageDetails(OpID(counter: 999, replica: 1), in: a.state) == nil)
        #expect(ImageDetails.name(.bilevel) == "Bilevel" && ImageDetails.name(.indexed) == "Indexed" && ImageDetails.name(.cmyk) == "CMYK")
        // Scale: to a percentage of natural size, and to a width.
        let factors = try #require(details.scaleFactors(toPercent: 50, horizontal: true, vertical: true))
        #expect(factors.x == 0.5 && factors.y == 0.5)
        #expect(details.scaleFactors(toPercent: 200, horizontal: true, vertical: false)! == (2, 1))
        #expect(details.scaleFactors(toPercent: 0, horizontal: true, vertical: true) == nil)
        #expect(details.scaleFactors(toSize: 300, width: true, locked: true)! == (2, 2))
        #expect(details.scaleFactors(toSize: 150, width: false, locked: false)! == (1, 2))
        #expect(details.scaleFactors(toSize: 150, width: true, locked: false)! == (1, 1))
        #expect(details.scaleFactors(toSize: -1, width: true, locked: false) == nil)
        _ = try a.perform(TransformObjects([image], matrix: .scale(x: 2, y: 2), about: .zero, kind: .scale))
        let scaled = try #require(ImageDetails(image, in: a.state))
        #expect(scaled.effectivePPI == 72 && scaled.scaleX == 2)
        #expect(ImageDetails.name(.rgb) == "RGB")
        let lines = ImageInfoLines.lines(details, format: "public.png", profile: nil, fileSize: 2048, placedBy: nil)
        #expect(lines.first { $0.0 == "Stored resolution" }?.1 == "144 ppi" && lines.last?.1 == "You" && lines.contains { $0.0 == "File size" })
        #expect(ImageInfoLines.lines(details, format: "", profile: "sRGB", fileSize: nil, placedBy: "Priya").contains { $0 == ("Format", "Unknown") })
        #expect(ImageInfoLines.ppi(72, 144) == "72 × 144 ppi")
    }

    @Test func aPastedImageWithoutAlphaReadsAsSuch() throws {
        var a = Replica(1)
        let image = try #require(try a.perform(PlaceImage(ImageCommandsTests.pixels(), dpiX: 72, dpiY: 72))?.createdObjects.first)
        let details = try #require(ImageDetails(image, in: a.state))
        #expect(details.file == "Pasted" && details.modeText == "RGB" && details.tint == nil)
        #expect(ImageInfoLines.lines(details, format: "public.png", profile: nil, fileSize: nil, placedBy: nil).contains { $0 == ("Alpha", "No") })
        _ = try a.perform(SetImageSetting([image], .tint(ColorResolver.inline(Color(white: 0.2)))))
        #expect(ImageDetails(image, in: a.state)?.tint != nil)
    }
}
