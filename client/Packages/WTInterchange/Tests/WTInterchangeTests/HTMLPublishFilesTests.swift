// WEB-008, the rest of the HTML publisher: placed bitmaps in `images/` in the setting's format and
// quality, embedded fonts as WOFF2 subsets in `fonts/` with the `fsType` check and outline
// fallback, and placed SVG animations played in place of their posters.

import CoreGraphics
import CoreText
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite(.serialized) struct HTMLPublishFilesTests {
    static let photo = Corpus.jpeg(Corpus.image())
    static let assets = ["alpha": ExportAsset(image: Corpus.image(alpha: true)), "photo": ExportAsset(image: Corpus.image(), jpegData: photo),
                         "plain": ExportAsset(image: Corpus.image(width: 20, height: 10))]

    static func scene(_ pages: [[DisplayItem]], nodes: [[NodeID?]] = []) -> ExportScene {
        let built = pages.enumerated().map { index, items in Corpus.page(items, nodes: index < nodes.count ? nodes[index] : []) }
        return Corpus.scene(built, assets: assets)
    }

    static func image(_ asset: String, x: Double = 0) -> DisplayItem {
        .image(ImageItem(assetID: asset, rect: Rect(x: x, y: 0, width: 32, height: 24)))
    }

    // MARK: Images

    @Test func placedBitmapsGoToTheImagesFolderByContentHash() throws {
        // The same photo on two pages is one file; the placed JPEG keeps its own bytes.
        let scene = Self.scene([[Self.image("photo"), Self.image("alpha", x: 40), Self.image("plain", x: 80)], [Self.image("photo")]])
        let bundle = try HTMLPublisher().publish(scene)
        let images = bundle.files.filter { $0.path.hasPrefix("images/") }
        #expect(images.count == 3)
        let jpegs = images.filter { $0.path.hasSuffix(".jpg") }
        #expect(jpegs.count == 2 && jpegs.contains { $0.data == Self.photo })
        // A bitmap with transparency is PNG under JPEG.
        #expect(images.filter { $0.path.hasSuffix(".png") }.count == 1)
        for image in images {
            #expect(image.path == "images/\(SVGLinkedFiles.name(image.data)).\(image.path.split(separator: ".").last!)")
        }
        let page = try #require(bundle.text("pages/page-1.svg"))
        for image in images { #expect(page.contains("xlink:href=\"../\(image.path)\"")) }
        #expect(!page.contains("data:image"))
        // Pages that link files are objects, so the browser loads them.
        let index = try #require(bundle.text("index.html"))
        #expect(index.contains("<object data=\"pages/page-1.svg\"") && index.contains("<object data=\"pages/page-2.svg\""))
        // Republishing over the folder rewrites nothing.
        let folder = Corpus.directory()
        #expect(try bundle.write(to: folder).count == bundle.files.count)
        #expect(try HTMLPublisher().publish(scene).write(to: folder).isEmpty)
    }

    @Test func imageFormatAndQuality() throws {
        let scene = Self.scene([[Self.image("photo"), Self.image("alpha", x: 40)]])
        let png = try HTMLPublisher(settings: HTMLPublishSettings(imageFormat: .png)).publish(scene)
        #expect(png.files.filter { $0.path.hasPrefix("images/") }.allSatisfy { $0.path.hasSuffix(".png") })
        let webp = try HTMLPublisher(settings: HTMLPublishSettings(imageFormat: .webp)).publish(scene)
        let ext = BitmapExporter.canEncode(.webp) ? ".webp" : ".png"
        #expect(webp.files.filter { $0.path.hasPrefix("images/") }.allSatisfy { $0.path.hasSuffix(ext) })
        // Quality changes a re-encoded JPEG.
        let plain = Self.scene([[Self.image("plain")]])
        let low = try HTMLPublisher(settings: HTMLPublishSettings(imageQuality: 5)).publish(plain).files.first { $0.path.hasPrefix("images/") }
        let high = try HTMLPublisher(settings: HTMLPublishSettings(imageQuality: 100)).publish(plain).files.first { $0.path.hasPrefix("images/") }
        #expect(low?.path.hasSuffix(".jpg") == true && low?.data != high?.data)
        // Without a WebP encoder the file is PNG.
        let files = SVGLinkedFiles(imageFormat: .webp)
        #expect(files.encode(Corpus.image(), original: nil, webPAvailable: false).ext == "png")
    }

    @Test func pngPagesAndPositionedObjectsLinkTheirFiles() throws {
        let scene = Self.scene([[Self.image("photo"), Corpus.text("Hello")]], nodes: [[Corpus.node(1), Corpus.node(2)]])
        let objects = try HTMLPublisher(settings: HTMLPublishSettings(layout: .positionedObjects)).publish(scene)
        #expect(objects.files.contains { $0.path.hasPrefix("images/") } && objects.files.contains { $0.path.hasPrefix("fonts/") })
        #expect(objects.text("objects/page-1-1.svg")!.contains("../images/"))
        #expect(objects.text("index.html")!.contains("<object data=\"objects/page-1-1.svg\""))
        let png = try HTMLPublisher(settings: HTMLPublishSettings(vectorFormat: .png)).publish(scene)
        #expect(!png.files.contains { $0.path.hasPrefix("images/") || $0.path.hasPrefix("fonts/") })
    }

    // MARK: Fonts

    @Test func embeddedFontsAreWOFF2SubsetsOfTheGlyphsUsed() throws {
        let scene = Self.scene([[Corpus.text("HELLO"), Corpus.text("OLE", origin: Point(x: 10, y: 90))], [Corpus.text("HOLE")]])
        let bundle = try HTMLPublisher().publish(scene)
        let fonts = bundle.files.filter { $0.path.hasPrefix("fonts/") }
        // One subset per page (the pages' glyphs differ only in order here, so they are equal).
        #expect(fonts.count == 1)
        let font = try #require(fonts.first)
        #expect(font.path.hasSuffix(".woff2") && font.data.prefix(4) == Data("wOF2".utf8))
        let page = try #require(bundle.text("pages/page-1.svg"))
        #expect(page.contains("src:url(../\(font.path)) format('woff2')"))
        #expect(!page.contains("font/ttf"))
        let sfnt = try WOFF2Reader.sfnt(font.data)
        let ct = try #require(FontFixture.coreText(sfnt))
        func hasOutline(_ character: Character) -> Bool {
            let glyph = FontFixture.glyph(ct, character)
            return glyph != 0 && CTFontCreatePathForGlyph(ct, glyph, nil).map { !$0.boundingBoxOfPath.isEmpty } == true
        }
        #expect(hasOutline("H") && hasOutline("E") && hasOutline("O"))
        #expect(!hasOutline("Z") && !hasOutline("a"))
        #expect(bundle.warnings.all.allSatisfy { $0.kind != .outlinedFont })
    }

    @Test func fontsThatForbidEmbeddingAreOutlinedAndReported() throws {
        var source = FontFixture.source(style: "Locked")
        source.os2.fsType = 2
        let url = Corpus.directory().appendingPathComponent("Marlowe-Locked.ttf")
        try FontCompiler.compile(source, options: FontCompiler.Options(format: .ttf)).data.write(to: url)
        #expect(CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil))
        defer { CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil) }
        let node = Corpus.node(7)
        let scene = Self.scene([[Corpus.text("AVO", font: "Marlowe-Locked")]], nodes: [[node]])
        let bundle = try HTMLPublisher().publish(scene)
        #expect(!bundle.files.contains { $0.path.hasPrefix("fonts/") })
        let page = try #require(bundle.text("pages/page-1.svg"))
        #expect(!page.contains("<text") && page.contains("<path"))
        let warning = try #require(bundle.warnings.all.first { $0.kind == .outlinedFont })
        #expect(warning.node == node && warning.page == 1 && warning.message.contains("Marlowe-Locked") && warning.message.contains("license"))
        // A font without TrueType outlines is outlined too, for its own reason.
        let cff = try HTMLPublisher().publish(Self.scene([[Corpus.text("Kohinoor", font: "KohinoorDevanagari-Regular")]]))
        #expect(cff.warnings.all.contains { $0.kind == .outlinedFont && $0.message.contains("cannot be embedded as a subset") })
    }

    // MARK: Placed SVG animations

    static let animationSVG = """
    <?xml version="1.0"?>
    <!DOCTYPE svg>
    <!-- spinner -->
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" onload="start()"><style>@keyframes s{to{transform:rotate(1turn)}}</style>
    <circle r="4" cx="5" cy="5" onclick='go()' style="animation:s 1s infinite"/><script>alert(1)</script><script src="x.js"/></svg>
    """

    static func animationScene(_ animations: [NodeID: ExportSVGAnimation]) -> ExportScene {
        // The posters: a red square (top-level) and a blue one inside a group.
        let poster = Corpus.path(Corpus.rect(20, 20, 40, 40), [Corpus.fill(.solid(Corpus.red))])
        let nested = Corpus.path(Corpus.rect(100, 20, 40, 40), [Corpus.fill(.solid(Corpus.blue))])
        var page = Corpus.page([poster, .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(Corpus.green))]), nested]))],
                               nodes: [Corpus.node(1), Corpus.node(2)])
        page.nestedNodeIDs = [[1, 1]: Corpus.node(3), [5, 0]: Corpus.node(4)]
        var scene = Corpus.scene([page])
        scene.nodes = [Corpus.node(1): ExportNodeInfo(alt: "Spinner")]
        scene.svgAnimations = animations
        return scene
    }

    @Test func animationsPlayInPlaceOfTheirPosters() throws {
        let top = ExportSVGAnimation(data: Data(Self.animationSVG.utf8), width: 10, height: 10, transform: AffineTransform(a: 4, b: 0, c: 0, d: 4, tx: 20, ty: 20),
                                     script: true, loop: .loop)
        let inner = ExportSVGAnimation(data: Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8), width: 40, height: 40,
                                       transform: .translation(x: 100, y: 20), autoplay: false, loop: .once, playOnHover: true)
        // A node with an animation but no item on this page is ignored.
        let scene = Self.animationScene([Corpus.node(1): top, Corpus.node(3): inner, Corpus.node(9): inner])
        let bundle = try HTMLPublisher().publish(scene)
        let index = try #require(bundle.text("index.html"))
        #expect(index.contains("<div id=\"anim-1-1\" class=\"anim\" style=\"width:10px;height:10px;transform:matrix(4,0,0,4,20,20)\" role=\"img\" aria-label=\"Spinner\"><svg"))
        #expect(index.contains("<div id=\"anim-1-2\" class=\"anim\" style=\"width:40px;height:40px;transform:matrix(1,0,0,1,100,20)\""))
        // Scripts, event attributes, the prolog and comments are gone; the animation is kept.
        #expect(!index.contains("<script") && !index.contains("onload") && !index.contains("onclick") && !index.contains("<?xml") && !index.contains("spinner"))
        #expect(index.contains("@keyframes s"))
        #expect(bundle.warnings.all.contains { $0.kind == .scriptAnimation && $0.node == Corpus.node(1) && $0.page == 1 })
        // The posters are no longer drawn in the page; the rest of the page is.
        let page = try #require(bundle.text("pages/page-1.svg"))
        #expect(!page.contains("#e61a1a") && !page.contains("#1a4de6") && page.contains("#1ab34d"))
        let style = try #require(bundle.text("style.css"))
        #expect(style.contains(".anim{position:absolute;left:0;top:0;display:block;transform-origin:0 0}"))
        #expect(style.contains("#anim-1-1 *{animation-iteration-count:infinite}"))
        #expect(style.contains("#anim-1-2 *{animation-play-state:paused}") && style.contains("#anim-1-2:hover *{animation-play-state:running}"))
        #expect(style.contains("#anim-1-2 *{animation-iteration-count:1}"))
        #expect(!bundle.files.contains { $0.path.hasPrefix("animations/") })
    }

    @Test func scriptedAnimationsAreIsolatedWhenScriptsAreAllowed() throws {
        let data = Data(Self.animationSVG.utf8)
        let scene = Self.animationScene([Corpus.node(1): ExportSVGAnimation(data: data, width: 10, height: 10, script: true)])
        let bundle = try HTMLPublisher(settings: HTMLPublishSettings(allowScripts: true)).publish(scene)
        let path = "animations/\(SVGLinkedFiles.name(data)).svg"
        #expect(bundle.file(path) == data)
        #expect(bundle.text("index.html")!.contains("<object id=\"anim-1-1\" class=\"anim\" data=\"\(path)\" type=\"image/svg+xml\""))
        #expect(!bundle.warnings.all.contains { $0.kind == .scriptAnimation })
        // An animation without script is inlined even when scripts are allowed; no rules for the file's own timing.
        let plain = Self.animationScene([Corpus.node(1): ExportSVGAnimation(data: Data("<svg/>".utf8), width: 10, height: 10)])
        let inlined = try HTMLPublisher(settings: HTMLPublishSettings(allowScripts: true)).publish(plain)
        #expect(inlined.text("index.html")!.contains("<div id=\"anim-1-1\""))
        #expect(!inlined.text("style.css")!.contains("#anim-1-1"))
    }

    @Test func posterOnlyAndDocumentsWithoutAnimationsAreUnchanged() throws {
        let animated = Self.animationScene([Corpus.node(1): ExportSVGAnimation(data: Data("<svg/>".utf8), width: 10, height: 10)])
        let poster = try HTMLPublisher(settings: HTMLPublishSettings(svgAnimationPosterOnly: true)).publish(animated)
        let still = try HTMLPublisher().publish(Self.animationScene([:]))
        #expect(poster.files.map(\.path) == still.files.map(\.path))
        #expect(poster.files.map(\.data) == still.files.map(\.data))
        #expect(!poster.text("style.css")!.contains(".anim"))
        #expect(poster.text("pages/page-1.svg")!.contains("#e61a1a"))
        // Emptying a path past the items leaves them as they are.
        let items = [Corpus.path(Corpus.rect(0, 0, 1, 1), [])]
        #expect(HTMLAnimations.emptying(items, at: [3]) == items && HTMLAnimations.emptying(items, at: [0, 1]) == items)
    }
}
