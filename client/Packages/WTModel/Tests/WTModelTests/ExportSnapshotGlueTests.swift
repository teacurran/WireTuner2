import CoreGraphics
import Foundation
import ImageIO
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender
import WTText

/// The export snapshot's model halves for this build: the comment threads for *Comments as
/// annotations* (COLLAB-033), placed SVG animations for the HTML publisher (WEB-008), the Inspect
/// panel's snippet object (COLLAB-036) and text-range links on a path (TYPE-041).
@Suite struct ExportSnapshotGlueTests {
    static let page = [ExportSnapshot.Page(bounds: Rect(x: 0, y: 0, width: 400, height: 400))]

    @Test func commentThreadsCarryPinsNamesAndLiveComments() throws {
        var a = Replica(0xA)
        _ = try NavigationFixture.layer(&a)
        let opened = try a.perform(CreateThread(at: Point(x: 30, y: 40), author: "acct-1", body: CommentBody("First"), postedAt: Date(timeIntervalSince1970: 10),
                                                in: a.state))!
        let thread = try #require(opened.createdNodes.first)
        try a.perform(Reply(to: thread, author: "acct-2", body: CommentBody("Second"), postedAt: Date(timeIntervalSince1970: 20)))
        try a.perform(SetResolved(thread, resolved: true, in: a.state))
        // A thread on a deleted object has no pin and is left out.
        let rect = try ExportSnapshotTests.create(ShapeFixture.rect(), on: try NavigationFixture.layer(&a, "Other"), &a)
        try a.perform(CreateThread(at: Point(x: 1, y: 1), on: rect, author: "acct-1", body: CommentBody("Gone"), in: a.state))
        try a.perform(DeleteNodes([rect]))
        let threads = ExportSnapshot.comments(a.state) { $0 == "acct-1" ? "Priya" : "Tom" }
        #expect(threads.count == 1 && threads[0].pin == Point(x: 30, y: 40) && threads[0].resolved)
        #expect(threads[0].comments.map(\.author) == ["Priya", "Tom"] && threads[0].comments.map(\.text) == ["First", "Second"])
        #expect(threads[0].comments.map(\.wallTimeMs) == [10_000, 20_000])
    }

    @Test func placedSVGAnimationsReachTheSceneWithTheirSettings() throws {
        var a = Replica(0xA)
        _ = try NavigationFixture.layer(&a)
        func asset(_ name: String, sha: Data) throws -> OpID {
            let props = AssetFields.values {
                $0.common.name = name
                $0.mediaType = "image/svg+xml"
                $0.sha256 = sha
            }
            return try a.perform(OpsCommand("Asset", ops: [Ops.create(parent: OpID.wellKnown(9), position: [0x80], props: props)]))!.createdNodes[0]
        }
        let plain = try asset("spin.svg", sha: Data([1]))
        let zipped = try asset("spin.svgz", sha: Data([2]))
        let missing = try asset("gone.svg", sha: Data([3]))
        let web = SvgAnimationWeb(autoplay: false, loop: .once, playOnHover: true)
        let node = try a.perform(CreateSvgAnimation(SvgAnimationFile(asset: plain, naturalSize: Size(width: 200, height: 100), kinds: SvgAnimationKinds(script: true)),
                                                    transform: .translation(x: 10, y: 20), web: web))!.createdObjects[0]
        let loops = try a.perform(CreateSvgAnimation(SvgAnimationFile(asset: plain, naturalSize: Size(width: 20, height: 10)),
                                                     web: SvgAnimationWeb(loop: .loop)))!.createdObjects[0]
        let asFile = try a.perform(CreateSvgAnimation(SvgAnimationFile(asset: plain, naturalSize: Size(width: 20, height: 10))))!.createdObjects[0]
        let gz = try a.perform(CreateSvgAnimation(SvgAnimationFile(asset: zipped, naturalSize: Size(width: 20, height: 10))))!.createdObjects[0]
        let gone = try a.perform(CreateSvgAnimation(SvgAnimationFile(asset: missing, naturalSize: Size(width: 20, height: 10))))!.createdObjects[0]
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        let scene = ExportSnapshotTests.capture(a.state, ExportSnapshot.Request(name: "Anim", pages: Self.page, scope: .pages([0])),
                                                blobs: [Data([1]): svg, Data([2]): Data([0x1F, 0x8B, 8, 0])]).scene
        let animation = try #require(scene.svgAnimations[NodeID(node)])
        #expect(animation.data == svg && animation.width == 200 && animation.height == 100 && animation.transform == .translation(x: 10, y: 20))
        #expect(animation.script && !animation.autoplay && animation.loop == .once && animation.playOnHover)
        #expect(scene.svgAnimations[NodeID(loops)]?.loop == .loop && scene.svgAnimations[NodeID(asFile)]?.loop == .asFile)
        #expect(scene.svgAnimations[NodeID(gz)] == nil && scene.svgAnimations[NodeID(gone)] == nil)
    }

    @Test @MainActor func aSnippetObjectNamesItsKindAndWhatNoSnippetCanExpress() throws {
        var a = Replica(0xA)
        let layer = try NavigationFixture.layer(&a)
        var rounded = ShapeFixture.rect()
        rounded.rect.corners.uniform = true
        rounded.rect.corners.topLeft = 6
        rounded.rect.common.name = "Button"
        let button = try ExportSnapshotTests.create(rounded, on: layer, &a)
        var uneven = ShapeFixture.rect()
        uneven.rect.corners.topLeft = 4
        uneven.rect.corners.topRight = 2
        let corner = try ExportSnapshotTests.create(uneven, on: layer, at: 0x81, &a)
        let square = try ExportSnapshotTests.create(ShapeFixture.rect(), on: layer, at: 0x82, &a)
        var ellipse = Wiretuner_Doc_V1_NodeProps()
        ellipse.ellipse.size.width = 30
        ellipse.ellipse.size.height = 30
        ellipse.ellipse.appearance = Appearances.standard
        let circle = try ExportSnapshotTests.create(ellipse, on: layer, at: 0x83, &a)
        let path = try a.perform(CreatePath(contours: [NewContour(closed: true, points: [VectorPoint(anchor: .zero), VectorPoint(anchor: Point(x: 20, y: 0)),
                                                                                           VectorPoint(anchor: Point(x: 0, y: 20))])],
                                            appearance: Appearances.standard, layer: layer))!.createdObjects[0]
        let text = try a.perform(CreateTextBlock(.point(Point(x: 10, y: 200)), text: "Hi", layer: layer))!.createdObjects[0]
        let group = try a.perform(GroupObjects([square, circle]))!.createdObjects[0]
        try a.perform(AddSwatch(Color(red: 1, green: 0, blue: 0), name: "Brand red"))
        var builder = DocumentDisplayListBuilder(canvas: "inspect")
        builder.textLayout = TextSceneLayout(engine: DocumentFontIndex(state: a.state).layoutEngine)
        let scene = builder.rebuild(a.state)
        func object(_ node: OpID) throws -> SnippetObject { try #require(ExportSnapshot.snippetObject(node, scene: scene, state: a.state)) }
        #expect(try object(button).shape == .roundedRectangle(radius: 6) && object(button).name == "Button")
        #expect(try object(corner).shape == .rectangle && object(path).shape == .path && object(text).shape == .text && object(group).shape == .other)
        #expect(try object(button).swatchNames.values.contains("Brand red") && object(circle).shape == .ellipse)
        #expect(ExportSnapshot.snippetObject(OpID(counter: 999, replica: 9), scene: scene, state: a.state) == nil)
        for (kind, words) in [(NodeKind.blend, "a blend"), (.extrude, "an extrusion"), (.envelope, "an envelope"), (.perspective, "an object on a perspective grid")] {
            #expect(ExportSnapshot.unexpressed(kind) == [words])
        }
        #expect(ExportSnapshot.unexpressed(.rect).isEmpty && ExportSnapshot.unexpressed(nil).isEmpty)
    }

    @Test func aSnippetObjectCarriesThePlacedImagesItDraws() throws {
        var a = Replica(0xA)
        _ = try NavigationFixture.layer(&a)
        // A 4 × 4 PNG.
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let png = data as Data
        var pixels = ImageCommandsTests.pixels(width: 4, height: 4)
        pixels.blobSha256 = Data(repeating: 0xCD, count: 32)
        let node = try a.perform(PlaceImage(pixels, name: "red.png"))!.createdObjects[0]
        let group = try a.perform(GroupObjects([node]))!.createdObjects[0]
        var builder = DocumentDisplayListBuilder(canvas: "inspect")
        let scene = builder.rebuild(a.state)
        let object = try #require(ExportSnapshot.snippetObject(group, scene: scene, state: a.state) { $0 == pixels.blobSha256 ? png : nil })
        #expect(object.assets.count == 1 && object.shape == .other)
        #expect(try #require(ExportSnapshot.snippetObject(group, scene: scene, state: a.state)).assets.isEmpty, "not on this Mac")
    }

    @Test @MainActor func textLinksOnAPathFollowTheCurve() throws {
        var a = Replica(0xA)
        let layer = try NavigationFixture.layer(&a)
        let text = try a.perform(CreateTextBlock(.point(Point(x: 10, y: 10)), text: "Link along", layer: layer))!.createdObjects[0]
        let path = try a.perform(CreatePath(contours: [NewContour(closed: false, points: [VectorPoint(anchor: Point(x: 0, y: 300)), VectorPoint(anchor: Point(x: 300, y: 300))])],
                                            appearance: Appearances.standard, layer: layer))!.createdObjects[0]
        try a.perform(AttachTextToPath(text: text, path: path))
        let node = TextFixture.text(a, text)
        try a.perform(SetTextLink(node: text, from: node.anchor(at: 0), to: node.anchor(at: 4), url: "https://example.com"))
        let fonts = DocumentFontIndex(state: a.state)
        let rects = try #require(ExportSnapshot.textLinks(a.state, engine: fonts.layoutEngine)[NodeID(text)]?.first?.rects)
        #expect(!rects.isEmpty && rects.allSatisfy { $0.maxY > 250 }, "the link lies on the path, not the block")
    }
}
