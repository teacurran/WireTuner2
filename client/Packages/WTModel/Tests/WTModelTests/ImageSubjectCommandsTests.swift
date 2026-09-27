import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// IMG-028: *Remove Background…* (*Transparent image*, *Clipping path*) and the refusals of both
/// subject commands.
@Suite struct ImageSubjectCommandsTests {
    typealias I = ImageCommandsTests

    @Test func theCommandsTakeOneRGBCMYKOrGrayscaleImageWhosePixelsAreHere() throws {
        var a = Replica(3)
        let rgb = try I.place(&a)
        let gray = try I.place(&a, I.pixels(mode: .grayscale, fill: 1))
        let bilevel = try I.place(&a, I.pixels(mode: .bilevel, fill: 2))
        let indexed = try I.place(&a, I.pixels(mode: .indexed, fill: 3))
        let unset = try I.place(&a, I.pixels(fill: 4))
        let rect = try #require(try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 5, height: 5)))).createdObjects[0]
        let state = a.state
        let here: (String) -> Bool = { $0 != ImageNodes.assetID(I.pixels(fill: 4)) }
        #expect(SubjectImages.refusal([rgb], in: state, isCached: here) == nil)
        #expect(SubjectImages.refusal([gray], in: state, isCached: here) == nil)
        #expect(SubjectImages.refusal([], in: state, isCached: here) == "Select an image")
        #expect(SubjectImages.refusal([rect], in: state, isCached: here) == "Select an image")
        #expect(SubjectImages.refusal([rgb, gray], in: state, isCached: here) == "Select one image")
        #expect(SubjectImages.refusal([rgb, rect], in: state, isCached: here) == "Select one image")
        #expect(SubjectImages.refusal([bilevel], in: state, isCached: here)?.hasPrefix("Bilevel") == true)
        #expect(SubjectImages.refusal([indexed], in: state, isCached: here)?.hasPrefix("Indexed") == true)
        #expect(SubjectImages.refusal([unset], in: state, isCached: here) == "The image has not finished downloading")
        try a.perform(SetLocked([rgb], locked: true))
        #expect(SubjectImages.refusal([rgb], in: a.state, isCached: here) == "The image is locked")
        #expect(SubjectImages.name(of: gray, in: a.state) == "photo.png")
    }

    @Test func aTransparentImageReplacesThePixelsInOneUndoableChange() throws {
        var a = Replica(3)
        let node = try I.place(&a)
        let before = RestoreContent.hash(a.state)
        let transparent = I.pixels(fill: 0xCD)
        let command = RemoveImageBackground(node, pixels: transparent, name: "photo.png")
        #expect(command.label == "Remove background from photo.png")
        try a.perform(command)
        let image = a.state.props(node).image
        #expect(image.pixels.blobSha256 == transparent.blobSha256 && image.pixels.hasAlpha_p)
        #expect(image.pixels.pixelWidth == 300 && image.pixels.pixelHeight == 150 && image.dpiX == 144)
        #expect(image.displayAlpha && image.sourceName == "photo.png (background removed)")
        // Again: the name keeps one suffix.
        try a.perform(RemoveImageBackground(node, pixels: I.pixels(fill: 0xCE), name: "photo.png (background removed)"))
        #expect(a.state.props(node).image.sourceName == "photo.png (background removed)")
        a.undo()
        a.undo()
        #expect(RestoreContent.hash(a.state) == before)
        #expect(throws: ImageEditError.self) { try a.perform(RemoveImageBackground(OpID(counter: 999, replica: 3), pixels: transparent, name: "x")) }
    }

    /// A closed square contour in the image's local space.
    static func square(_ x: Double, _ y: Double, _ size: Double) -> Contour {
        Contour(polygon: [Point(x: x, y: y), Point(x: x + size, y: y), Point(x: x + size, y: y + size), Point(x: x, y: y + size)])
    }

    @Test func aClippingPathPastesTheUntouchedImageInsideAPathAroundTheSubject() throws {
        var a = Replica(3)
        let node = try I.place(&a)
        let pixels = a.state.props(node).image.pixels
        let command = ClipImageToSubject(node, contours: [Self.square(10, 10, 50), Contour(segments: [], closed: true)], name: "photo.png")
        #expect(command.label == "Clip photo.png to subject")
        try a.perform(command)
        let group = try #require(Objects.parent(of: node, in: a.state))
        #expect(ClipGroups.isClipGroup(group, in: a.state))
        let path = try #require(ClipGroups.clipPath(of: group, in: a.state))
        #expect(ClipGroups.contents(of: group, in: a.state) == [node])
        #expect(a.state.props(node).image.pixels == pixels, "the image is untouched")
        // The path follows the image's transform: (10, 10) in the image is (20, 30) on the page.
        let bounds = try #require(Objects.bounds(of: path, in: a.state))
        #expect(abs(bounds.minX - 20) < 1e-6 && abs(bounds.minY - 30) < 1e-6 && abs(bounds.width - 50) < 1e-6)
        #expect(a.state.props(path).path.common.name == "Subject of photo.png")
        #expect(a.sent.count == 2)
        #expect(throws: ImageEditError.invalidValue("contours")) { try a.perform(ClipImageToSubject(node, contours: [], name: "photo.png")) }
    }

    /// Merge test: A removes the background as a transparent image while B crops the same image;
    /// both converge on B's crop over A's new pixels.
    @Test func aBackgroundRemovalAndAConcurrentCropBothApply() throws {
        var pair = Pair()
        let node = try I.place(&pair.a)
        pair.sync()
        let transparent = I.pixels(fill: 0xCD)
        try pair.a.perform(RemoveImageBackground(node, pixels: transparent, name: "photo.png"))
        let crop = Rect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        try pair.b.perform(CropImage([node], crop: crop))
        pair.sync()
        #expect(pair.a.state.stateHash == pair.b.state.stateHash)
        let image = pair.b.state.props(node).image
        #expect(image.pixels.blobSha256 == transparent.blobSha256 && image.hasCrop)
        #expect(abs(image.crop.width - 0.5) < 1e-9 && abs(image.crop.x - 0.1) < 1e-9)
    }
}
