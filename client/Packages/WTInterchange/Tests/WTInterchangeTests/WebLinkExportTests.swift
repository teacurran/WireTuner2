// WEB-005, WEB-023, WEB-010: links and page links in SVG and PDF output, scheme completion, and the
// output warnings; the fixtures are built here and read back with the SVG tree parser and PDFKit.

import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct WebLinkExportTests {
    @Test(arguments: [
        ("mailto:someone@example.com", "mailto:someone@example.com"),
        ("page-2.html", "page-2.html"),
        ("#top", "#top"),
        ("/about", "/about"),
        ("./a.svg", "./a.svg"),
        ("example.com", "https://example.com"),
        ("www.example.org/path?q=1", "https://www.example.org/path?q=1"),
        ("localhost:8080/x", "localhost:8080/x"),
        ("shop.example.co:443/cart", "https://shop.example.co:443/cart"),
        ("  https://example.com/a b  ", nil),
        ("https://", nil),
        ("http:///nohost", nil),
        ("tel:+15551234", "tel:+15551234"),
        ("", nil),
        ("line\nbreak.com", nil),
        ("3com.x9", "3com.x9"),
    ] as [(String, String?)])
    func schemeCompletion(url: String, expected: String?) {
        #expect(WebLinks.href(url) == expected)
    }

    @Test func thePageLinkWinsAndEachProblemIsWarnedOnce() {
        let (a, b, c, d, e) = (Corpus.node(1), Corpus.node(2), Corpus.node(3), Corpus.node(4), Corpus.node(5))
        var pages = [Corpus.page([]), Corpus.page([])]
        pages[1].number = 3
        var scene = Corpus.scene(pages, nodes: [
            a: ExportNodeInfo(url: "example.com", pageLink: 3),
            b: ExportNodeInfo(url: "https://bad url"),
            c: ExportNodeInfo(pageLink: 2),
            d: ExportNodeInfo(url: "https://ok.example"),
            e: ExportNodeInfo(name: "plain"),
        ])
        scene.textLinks = [e: [ExportTextLink(url: "not valid://", rects: [])]]
        #expect(WebLinks.pageNumbers(scene) == [1, 3])
        #expect(WebLinks.action(scene.nodes[a], pages: [1, 3]) == .page(3))
        #expect(WebLinks.action(scene.nodes[a], pages: [1]) == .uri("https://example.com"))
        #expect(WebLinks.action(scene.nodes[c], pages: [1, 3]) == nil)
        #expect(WebLinks.action(scene.nodes[b], pages: []) == nil)
        #expect(WebLinks.action(nil, pages: []) == nil)
        let warnings = WebLinks.warnings(scene, strokeOnlyNodes: [d])
        #expect(warnings.map(\.kind) == [.unusedLink, .invalidLink, .missingPage, .strokeOnlyLink, .invalidLink])
        #expect(warnings.map(\.node) == [a, b, c, d, e])
        // The sink keeps one of each and a stable order.
        var sink = ExportWarnings(warnings + warnings)
        sink.append(ExportWarning(.clampedPage, page: 2, "Page 2 is too large"))
        #expect(sink.all.count == 6)
        #expect(sink.sorted.first?.kind == .unusedLink && sink.sorted.last?.kind == .clampedPage)
        #expect(!sink.isEmpty && ExportWarnings().isEmpty)
    }

    /// Two pages: page 1 holds a linked rectangle (link alt, new tab), a rectangle linking to
    /// page 2 and a text-range link over two lines.
    static func scene() -> ExportScene {
        let (url, page, text) = (Corpus.node(10), Corpus.node(11), Corpus.node(12))
        let items = [
            Corpus.path(Corpus.rect(10, 10, 40, 20), [Corpus.fill(.solid(Corpus.red))]),
            Corpus.path(Corpus.rect(60, 10, 40, 20), [Corpus.fill(.solid(Corpus.blue))]),
        ]
        var scene = Corpus.scene([Corpus.page(items, nodes: [url, page]), Corpus.page([Corpus.path(Corpus.rect(0, 0, 5, 5), [Corpus.fill(.solid(.black))])])], nodes: [
            url: ExportNodeInfo(name: "Order", url: "shop.example.com", linkAlt: "Order form", linkTarget: .newTab),
            page: ExportNodeInfo(name: "Next", url: "https://unused.example", pageLink: 2),
        ])
        scene.pages[0].number = 1
        scene.pages[1].number = 2
        scene.textLinks = [text: [ExportTextLink(url: "https://words.example", alt: "Words", rects: [Rect(x: 10, y: 50, width: 80, height: 12), Rect(x: 10, y: 64, width: 30, height: 12)])]]
        return scene
    }

    @Test func svgAnchorsCarryTheTargetTitleAndPageFile() throws {
        let folder = Corpus.directory().appendingPathComponent("links-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let summary = try SVGExporter().export(scene: Self.scene(), options: SVGOptions(), to: ExportDestination(url: folder.appendingPathComponent("doc.svg"),
                                                                                                               namePattern: FileNamePattern("{name}-{page}")))
        let first = try String(contentsOf: summary.files[0], encoding: .utf8)
        let root = try #require(XMLTreeParser.parse(first))
        #expect(SVGValidator.problems(root).isEmpty)
        let anchors = root.all("a")
        #expect(anchors.count == 3)
        #expect(anchors[0].attributes["xlink:href"] == "https://shop.example.com" && anchors[0].attributes["target"] == "_blank")
        #expect(anchors[0].children.first?.name == "title" && anchors[0].children.first?.text == "Order form")
        // The page link wins over the URL and points at page 2's file.
        #expect(anchors[1].attributes["xlink:href"] == summary.files[1].lastPathComponent && anchors[1].attributes["target"] == nil)
        // The text-range link: one invisible rectangle per line.
        #expect(anchors[2].attributes["xlink:href"] == "https://words.example")
        #expect(anchors[2].all("rect").count == 2 && anchors[2].all("rect")[0].attributes["fill-opacity"] == "0")
        #expect(summary.notes.contains { $0.contains("is not used") })
        // Without a page file the page link falls back to the URL.
        let alone = SVGExporter().documents(scene: Self.scene(), options: SVGOptions())[0]
        #expect(alone.text.contains("xlink:href=\"https://unused.example\""))
    }

    @Test func pdfLinksCarryContentsGoToAndOneAnnotationPerLine() throws {
        let result = try PDFExporter().data(scene: Self.scene(), options: PDFOptions())
        let document = try #require(PDFDocument(data: result.data))
        let annotations = document.page(at: 0)!.annotations
        #expect(annotations.count == 4)
        #expect(annotations[0].url?.absoluteString == "https://shop.example.com")
        #expect(annotations[0].contents == "Order form")
        let goTo = try #require(annotations[1].action as? PDFActionGoTo)
        #expect(goTo.destination.page.map { document.index(for: $0) } == 1)
        #expect(annotations[2].url?.absoluteString == "https://words.example" && annotations[3].contents == "Words")
        let raw = String(decoding: result.data, as: UTF8.self)
        #expect(raw.contains("/Dests"))
        // Without links, no annotations and no destinations.
        let bare = try PDFExporter().data(scene: Self.scene(), options: PDFOptions(linksFromURLs: false))
        #expect(PDFDocument(data: bare.data)!.page(at: 0)!.annotations.isEmpty)
        #expect(!String(decoding: bare.data, as: UTF8.self).contains("/Dests"))
    }
}
