// WEB-028: placed SVG animations in exports other than HTML.  The SVG exporter writes each placed
// animation as itself -- an `<image>` of the unchanged file over the object's bounds, embedded or
// linked -- in place of its poster; the animated-SVG exporter does so inside every frame; snippets
// and the HTML publisher (which places animations itself) keep the poster; PDF draws the poster
// image and nothing else.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct SVGAnimationExportTests {
    static let file = Data(HTMLPublishFilesTests.animationSVG.utf8)
    static let placed = ExportSVGAnimation(data: file, width: 10, height: 10, transform: AffineTransform(a: 4, b: 0, c: 0, d: 4, tx: 20, ty: 20), script: true)

    @Test func theSVGExporterNestsTheFileAtTheObjectsBounds() throws {
        let scene = HTMLPublishFilesTests.animationScene([Corpus.node(1): Self.placed])
        let document = SVGExporter().documents(scene: scene, options: SVGOptions())[0]
        let root = try #require(XMLTreeParser.parse(document.text))
        let images = root.descendants.filter { $0.name == "image" }
        #expect(images.count == 1)
        let image = try #require(images.first)
        #expect(image.attributes["xlink:href"] == ImageEncoding.dataURL(Self.file, mime: "image/svg+xml"))
        #expect(image.attributes["width"] == "10" && image.attributes["height"] == "10")
        #expect(image.attributes["transform"] == "matrix(4 0 0 4 20 20)")
        #expect(image.attributes["role"] == "img", "the object's alt text makes it a figure")
        // The poster (the red square) is not drawn; the other objects are.
        #expect(!document.text.contains(ColorMath.hex(Corpus.red)))
        #expect(document.text.contains(ColorMath.hex(Corpus.blue)))
        #expect(document.notes.contains("a placed SVG animation depends on script, which does not run inside an SVG image"))
        // Linked images: the file beside the SVG, written once for two uses.
        var twice = scene
        twice.svgAnimations[Corpus.node(3)] = Self.placed
        let linked = SVGExporter().documents(scene: twice, options: SVGOptions(images: .link))[0]
        #expect(linked.resources.filter { $0.path.hasSuffix(".svg") }.map(\.path) == ["images/animation-1.svg"])
        #expect(linked.resources.first { $0.path == "images/animation-1.svg" }?.data == Self.file)
        #expect(linked.text.components(separatedBy: "xlink:href=\"images/animation-1.svg\"").count == 3)
    }

    @Test func snippetsAndTheHTMLPublisherKeepThePoster() throws {
        let scene = HTMLPublishFilesTests.animationScene([Corpus.node(1): Self.placed])
        let flat = SVGExporter.flattener(options: SVGOptions(), scene: scene).flatten(scene.pages[0], scene: scene).page
        let poster = SVGWriter(options: SVGOptions()).write(flat, scene: scene)
        #expect(poster.text.contains(ColorMath.hex(Corpus.red)) && !poster.text.contains("image/svg+xml"))
        var settings = HTMLPublishSettings()
        settings.svgAnimationPosterOnly = true
        let bundle = try HTMLPublisher(settings: settings).publish(scene)
        let page = try #require(bundle.files.first { $0.0.hasSuffix(".svg") })
        #expect(!String(decoding: page.1, as: UTF8.self).contains("image/svg+xml"))
    }

    @Test func theAnimatedSVGExporterNestsItInEveryFrame() throws {
        var scene = AnimationExportTests.scene()
        // The second frame's layer draws a poster for node 30.
        let poster = Corpus.node(30)
        let list = AnimationExportTests.displayList
        scene.animation?.displayList = DisplayList(canvas: list.canvas, items: list.items, nodeIDs: [nil, nil, poster, nil], layers: list.layers)
        scene.svgAnimations = [poster: ExportSVGAnimation(data: Self.file, width: 10, height: 10, transform: .translation(x: 40, y: 0))]
        let document = try AnimatedSVGExporter().documents(scene: scene)[0]
        #expect(document.text.components(separatedBy: "data:image/svg+xml;base64,").count == 2)
        let off = try AnimatedSVGExporter().documents(scene: scene, options: {
            var options = AnimatedSVGOptions()
            options.nestsSVGAnimations = false
            return options
        }())[0]
        #expect(!off.text.contains("image/svg+xml"))
    }

    @Test func pdfDrawsThePosterImageAndNothingElse() throws {
        // The poster is an image item (as WEB-026 draws it); the animation's bytes never reach
        // the PDF.
        let posterImage = Corpus.image(width: 20, height: 20)
        var page = Corpus.page([.image(ImageItem(assetID: "poster", rect: Rect(x: 20, y: 20, width: 40, height: 40)))], nodes: [Corpus.node(1)])
        page.name = nil
        var scene = Corpus.scene([page], assets: ["poster": ExportAsset(image: posterImage)])
        scene.svgAnimations = [Corpus.node(1): Self.placed]
        let pdf = try PDFExporter().data(scene: scene, options: PDFOptions())
        let raw = PDFTests.text(of: pdf.data)
        #expect(raw.components(separatedBy: "/Subtype /Image").count == 2)
        #expect(!raw.contains("keyframes") && !raw.contains("svg"))
    }
}
