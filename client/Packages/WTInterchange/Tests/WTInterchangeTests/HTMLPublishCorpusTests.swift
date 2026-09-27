// WEB-008, the corpus half: twenty documents published under every layout × page mode × vector
// format, each file validated -- the HTML pages by the in-process HTML5 checker
// (`Support/HTML5Checker.swift`), the SVG pages and objects as XML against the SVG 1.1 element and
// attribute tables of `SVGValidator` -- and every file a page references present in the bundle.
// When HTML Tidy is installed (`/opt/homebrew/bin/tidy` or `/usr/local/bin/tidy`) the HTML pages
// are also run through it, offline, and any error it reports fails; without it that check skips.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// One corpus document: a scene and whether its render is compared (the empty page draws nothing).
struct HTMLCorpusDocument: Sendable, CustomStringConvertible {
    let name: String
    let scene: ExportScene
    var description: String { name }
}

enum HTMLCorpus {
    static let combinations: [(HTMLLayout, HTMLPageMode, HTMLVectorFormat)] =
        HTMLLayout.allCases.flatMap { layout in HTMLPageMode.allCases.flatMap { mode in HTMLVectorFormat.allCases.map { (layout, mode, $0) } } }

    static func numbered(_ pages: [ExportPage]) -> [ExportPage] {
        pages.enumerated().map { index, page in
            var page = page
            page.number = index + 1
            return page
        }
    }

    static func scene(_ name: String, _ pages: [ExportPage], nodes: [NodeID: ExportNodeInfo] = [:], assets: [String: ExportAsset] = [:]) -> ExportScene {
        var scene = Corpus.scene(numbered(pages), nodes: nodes, assets: assets)
        scene.name = name
        return scene
    }

    /// A page whose objects sit in one layer group (the Positioned objects layout's members).
    static func layered(_ items: [DisplayItem], layer: NodeID, width: Double = 200, height: Double = 150) -> ExportPage {
        Corpus.page([.group(GroupItem(children: items))], width: width, height: height, nodes: [layer])
    }

    /// The twenty documents.
    static let documents: [HTMLCorpusDocument] = {
        var result: [HTMLCorpusDocument] = []
        // 1-8: the export corpus's fixtures, one page each.
        for name in Corpus.fixtures {
            result.append(HTMLCorpusDocument(name: name, scene: scene("Fixture \(name)", [Corpus.fixture(name)])))
        }
        // 9: links on a layered page and a page link (WEB-005), two pages.
        result.append(HTMLCorpusDocument(name: "links", scene: HTMLPublisherTests.scene()))
        // 10: placed bitmaps, JPEG and with transparency.
        let images: [DisplayItem] = [HTMLPublishFilesTests.image("photo"), HTMLPublishFilesTests.image("alpha", x: 40),
                                     .image(ImageItem(assetID: "plain", rect: Rect(x: 80, y: 40, width: 60, height: 30), transform: .rotation(radians: 0.2)))]
        result.append(HTMLCorpusDocument(name: "images", scene: scene("Images", [Corpus.page(images)], assets: HTMLPublishFilesTests.assets)))
        // 11: three pages of different content.
        result.append(HTMLCorpusDocument(name: "three pages", scene: scene("Three pages", [Corpus.fixture("basics"), Corpus.fixture("gradients"), Corpus.fixture("text")])))
        // 12: two layers of several objects each.
        let (back, front) = (Corpus.node(30), Corpus.node(31))
        var twoLayers = Corpus.page([
            .group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 200, 60), [Corpus.fill(.solid(Corpus.yellow))]),
                                        Corpus.path(Corpus.ellipse(20, 70, 60, 60), [Corpus.fill(.solid(Corpus.blue))])])),
            .group(GroupItem(children: [Corpus.path(Corpus.rect(50, 30, 80, 80), [Corpus.fill(.solid(Corpus.red.withAlpha(multipliedBy: 0.6)))]),
                                        Corpus.path(Corpus.wave(100, 90, 90, 40), [Corpus.stroke(.solid(.black), width: 3)])])),
        ], nodes: [back, front])
        twoLayers.nestedNodeIDs = [:]
        result.append(HTMLCorpusDocument(name: "two layers", scene: scene("Two layers", [twoLayers], nodes: [
            back: ExportNodeInfo(name: "Back", isLayer: true), front: ExportNodeInfo(name: "Front", isLayer: true)])))
        // 13: text in two faces with a text-range link.
        var words = scene("Words", [Corpus.page([Corpus.text("Hello links", size: 20), Corpus.text("Times face", font: "Times New Roman", size: 16, origin: Point(x: 10, y: 90))])])
        words.textLinks = [Corpus.node(40): [ExportTextLink(url: "https://words.example", rects: [Rect(x: 10, y: 22, width: 60, height: 22)])]]
        result.append(HTMLCorpusDocument(name: "words", scene: words))
        // 14: wide-gamut fills: Display P3 and OKLab.
        result.append(HTMLCorpusDocument(name: "wide gamut", scene: scene("Wide gamut", [Corpus.page([
            Corpus.path(Corpus.rect(10, 10, 80, 60), [Corpus.fill(.solid(Color(displayP3Red: 0, green: 0.9, blue: 0.2)))]),
            Corpus.path(Corpus.rect(110, 10, 80, 60), [Corpus.fill(.solid(Color(oklabL: 0.7, a: -0.1, b: -0.05)))]),
            Corpus.path(Corpus.ellipse(60, 80, 80, 60), [Corpus.fill(.solid(Color(displayP3Red: 1, green: 0.3, blue: 0, alpha: 0.7)))]),
        ])])))
        // 15: a page of fractional size.
        result.append(HTMLCorpusDocument(name: "fractional", scene: scene("Fractional", [Corpus.page(Corpus.basics, width: 200.5, height: 150.25)])))
        // 16: a larger page of twenty ellipses.
        result.append(HTMLCorpusDocument(name: "ellipses", scene: WebPresetTests.page(side: 400)))
        // 17: a coloured page background under translucent objects.
        result.append(HTMLCorpusDocument(name: "background", scene: scene("Background", [Corpus.page(Corpus.transparency, background: Color(red: 0.85, green: 0.95, blue: 1))])))
        // 18: two pages of different sizes.
        result.append(HTMLCorpusDocument(name: "sizes", scene: scene("Sizes", [Corpus.page(Corpus.basics), Corpus.page([Corpus.path(Corpus.ellipse(10, 10, 280, 80), [Corpus.fill(.solid(Corpus.green))])], width: 300, height: 100)])))
        // 19: an empty page.
        result.append(HTMLCorpusDocument(name: "empty", scene: scene("Empty", [Corpus.page([])])))
        // 20: a title and names that need escaping.
        let (named, quoted) = (Corpus.node(50), Corpus.node(51))
        result.append(HTMLCorpusDocument(name: "escaping", scene: scene("Tom & \"Jerry\" <1>", [Corpus.page([
            Corpus.path(Corpus.rect(10, 10, 50, 50), [Corpus.fill(.solid(Corpus.red))]),
            Corpus.path(Corpus.rect(80, 10, 50, 50), [Corpus.fill(.solid(Corpus.blue))]),
        ], nodes: [named, quoted])], nodes: [
            named: ExportNodeInfo(name: "Été & <co>", alt: "Q&A \"box\"", url: "https://example.com/?a=1&b=2"),
            quoted: ExportNodeInfo(name: "Été & <co>", url: "https://example.com/two"),
        ])))
        return result
    }()

    static let tidy: String? = ["/opt/homebrew/bin/tidy", "/usr/local/bin/tidy"].first { FileManager.default.isExecutableFile(atPath: $0) }
}

@Suite struct HTMLPublishCorpusTests {
    @Test func theCorpusHasTwentyDocuments() {
        #expect(HTMLCorpus.documents.count == 20)
        #expect(Set(HTMLCorpus.documents.map(\.name)).count == 20)
        #expect(HTMLCorpus.combinations.count == 8)
    }

    /// Every document under one combination: the HTML pages validate as HTML5, the SVG files as
    /// SVG 1.1, every reference resolves inside the bundle, and republishing is byte-identical.
    @Test(arguments: HTMLCorpus.combinations)
    func everyDocumentValidates(layout: HTMLLayout, mode: HTMLPageMode, vector: HTMLVectorFormat) throws {
        let settings = HTMLPublishSettings(layout: layout, pageMode: mode, vectorFormat: vector, scale: 1)
        for document in HTMLCorpus.documents {
            let bundle = try HTMLPublisher(settings: settings).publish(document.scene)
            let paths = Set(bundle.files.map(\.path))
            let label = "\(document.name) \(layout) \(mode) \(vector)"
            for file in bundle.files {
                let text = String(decoding: file.data, as: UTF8.self)
                if file.path.hasSuffix(".html") {
                    let problems = HTML5Checker.problems(text) { paths.contains(HTML5Checker.resolve($0, from: file.path)) }
                    #expect(problems.isEmpty, "\(label) \(file.path): \(problems)")
                } else if file.path.hasSuffix(".svg") {
                    let root = try #require(XMLTreeParser.parse(text), "\(label) \(file.path) is not well-formed XML")
                    #expect(root.name == "svg" && root.attributes["xmlns"] == "http://www.w3.org/2000/svg", "\(label) \(file.path)")
                    #expect(SVGValidator.problems(root).isEmpty, "\(label) \(file.path): \(SVGValidator.problems(root))")
                    let missing = HTML5Checker.svgReferences(text).filter { !paths.contains(HTML5Checker.resolve($0, from: file.path)) }
                    #expect(missing.isEmpty, "\(label) \(file.path) references \(missing)")
                } else if file.path == "style.css" {
                    #expect(text.filter { $0 == "{" }.count == text.filter { $0 == "}" }.count, "\(label) style.css braces")
                }
            }
            let again = try HTMLPublisher(settings: settings).publish(document.scene)
            #expect(again.files.map(\.path) == bundle.files.map(\.path) && zip(again.files, bundle.files).allSatisfy { $0.data == $1.data }, "\(label) is not deterministic")
        }
    }

    /// HTML Tidy, when installed, reports no error on any page of the corpus (offline).
    @Test(.enabled(if: HTMLCorpus.tidy != nil, "HTML Tidy is not installed"), arguments: HTMLCorpus.combinations)
    func tidyReportsNoErrors(layout: HTMLLayout, mode: HTMLPageMode, vector: HTMLVectorFormat) throws {
        let settings = HTMLPublishSettings(layout: layout, pageMode: mode, vectorFormat: vector, scale: 1)
        let folder = Corpus.directory().appendingPathComponent("tidy-\(UUID().uuidString.prefix(8))")
        for document in HTMLCorpus.documents {
            let bundle = try HTMLPublisher(settings: settings).publish(document.scene)
            for file in bundle.files where file.path.hasSuffix(".html") {
                let url = folder.appendingPathComponent("\(document.name.replacingOccurrences(of: " ", with: "-"))-\(file.path)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try file.data.write(to: url)
                let errors = try Self.tidyErrors(url)
                #expect(errors.isEmpty, "\(document.name) \(layout) \(mode) \(vector) \(file.path): \(errors)")
            }
        }
    }

    static func tidyErrors(_ url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: HTMLCorpus.tidy!)
        process.arguments = ["-q", "-e", "--show-warnings", "no", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").map(String.init).filter { $0.contains("Error:") }
    }

    // MARK: The checker itself

    @Test func theCheckerAcceptsAMinimalPageAndNamesEachFault() {
        let good = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8"><title>T &amp; U</title><link rel="stylesheet" href="style.css"></head>
        <body><section id="a"><img src="p.png" width="10" height="10" alt="" usemap="#m"><map name="m"><area shape="poly" coords="0,0,1,0,1,1" href="https://x.example/?a=1&amp;b=2" alt="x"></map>
        <div class="anim"><svg viewBox="0 0 1 1"><style><![CDATA[a>b{}]]></style><path d="M0 0"/></svg></div><!-- note --></section></body></html>
        """
        #expect(HTML5Checker.problems(good).isEmpty, "\(HTML5Checker.problems(good))")
        func faults(_ body: String, head: String = "<meta charset=\"utf-8\"><title>T</title>") -> [String] {
            HTML5Checker.problems("<!DOCTYPE html><html lang=\"en\"><head>\(head)</head><body>\(body)</body></html>") { $0 != "gone.png" }
        }
        #expect(HTML5Checker.problems("<html></html>") == ["no <!DOCTYPE html>"])
        #expect(faults("<img src=\"a.png\">").contains("img without alt"))
        #expect(faults("<img alt=\"\">").contains("img without src"))
        #expect(faults("<img src=\"a.png\" alt=\"\" width=\"1.5\">").contains { $0.contains("not a non-negative integer") })
        #expect(faults("<img src=\"gone.png\" alt=\"\">").contains { $0.contains("not in the bundle") })
        #expect(faults("<img src=\"a b.png\" alt=\"\">").contains { $0.contains("not a valid URL") })
        #expect(faults("<img src=\"a.png\" alt=\"\" usemap=\"#none\">").contains("usemap #none has no map"))
        #expect(faults("<img src=\"a.png\" alt=\"\" usemap=\"none\">").contains { $0.contains("not a hash name") })
        #expect(faults("<area shape=\"rect\" coords=\"0,0,1\" href=\"x\">").contains("area outside a map"))
        #expect(faults("<map name=\"m\"><area shape=\"rect\" coords=\"0,0,1\" href=\"x\"></map>").contains("rect area with 3 coords"))
        #expect(faults("<map name=\"m\"><area shape=\"poly\" coords=\"0,0,1,1\" href=\"x\" alt=\"\"></map>").contains("poly area with 4 coords"))
        #expect(faults("<map name=\"m\"><area shape=\"circle\" coords=\"0,0\" href=\"x\" alt=\"\"></map>").contains("circle area with 2 coords"))
        #expect(faults("<map name=\"m\"><area shape=\"star\" coords=\"a\" href=\"x\" alt=\"\"></map>").contains("area shape star"))
        #expect(faults("<map name=\"m\"><area shape=\"rect\" coords=\"a,0,1,1\" href=\"x\" alt=\"\"></map>").contains("area coords not numbers"))
        #expect(faults("<map name=\"m\"></map><map name=\"m\"></map>").contains("duplicate map name m"))
        #expect(faults("<map name=\"\"></map>").contains("map name ''"))
        #expect(faults("<map name=\"m\" id=\"n\"></map>").contains("map id and name differ"))
        #expect(faults("<div id=\"a\"></div><div id=\"a\"></div>").contains("duplicate id a"))
        #expect(faults("<div id=\"a b\"></div>").contains("bad id 'a b'"))
        #expect(faults("<center></center>").contains("obsolete element center"))
        #expect(faults("<div align=\"x\"></div>").contains("obsolete attribute div@align"))
        #expect(faults("<div onclick=\"x\"></div>").contains("attribute div@onclick not allowed"))
        #expect(faults("<div style=\"\"></div>").contains("empty style on div"))
        #expect(faults("<table></table>").contains("element table not expected"))
        #expect(faults("<div>a & b</div>").contains { $0.hasPrefix("bare") })
        #expect(faults("<div>&bogus;</div>").contains { $0.hasPrefix("bare") })
        #expect(faults("<div>&#169; &#xA9;</div>").isEmpty)
        #expect(faults("<div></span>").contains("end tag span closes div"))
        #expect(faults("</div>").contains("end tag div closes body"))
        #expect(HTML5Checker.problems("<!DOCTYPE html></div>").contains("stray end tag div"))
        #expect(faults("<div>").contains { $0.hasPrefix("unclosed") })
        #expect(faults("<img src=\"a.png\" alt=\"\"></img>").contains("end tag for void element img"))
        #expect(faults("<div/>").contains("self-closing non-void <div/>"))
        #expect(faults("<div class=x></div>").contains { $0.hasPrefix("malformed") })
        #expect(faults("<div id=\"a\" id=\"b\"></div>").contains("duplicate attribute on <div>"))
        #expect(faults("<object></object>").contains("object without data or type"))
        #expect(faults("<a href=\"x\" target=\"_new\">x</a>").contains("bad target _new"))
        #expect(faults("<![CDATA[x]]>").contains("CDATA outside foreign content"))
        #expect(faults("<!-- open").contains("unclosed comment"))
        #expect(faults("<div").contains { $0.hasPrefix("malformed") })
        #expect(HTML5Checker.problems("<!DOCTYPE html><div").contains("unclosed tag"))
        #expect(faults("", head: "<title>T</title>").contains("meta charset=utf-8 is not the head's first element"))
        #expect(faults("", head: "<meta charset=\"utf-8\">").contains("head needs exactly one title"))
        #expect(faults("", head: "<meta charset=\"utf-8\"><title> </title>").contains("empty title"))
        #expect(faults("", head: "<meta charset=\"utf-8\"><meta charset=\"utf-8\"><title>T</title>").contains("charset declared other than once"))
        #expect(faults("", head: "<meta charset=\"utf-8\"><title>T</title><meta name=\"x\">").contains("meta without charset or name/content"))
        #expect(faults("", head: "<meta charset=\"utf-8\"><title>T</title><link href=\"style.css\">").contains("link without rel"))
        #expect(faults("", head: "<meta charset=\"utf-8\"><title>T</title><link rel=\"x\">").contains("link without href"))
        #expect(faults("", head: "<meta charset=\"utf-8\"><title>T</title><div></div>").contains("<div> in head"))
        #expect(HTML5Checker.problems("<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>T</title></head><body></body></html>x").contains("text after </html>"))
        #expect(HTML5Checker.problems("<!DOCTYPE html><html lang=\"en\"><body></body></html>").contains("html children [\"body\"]"))
        #expect(HTML5Checker.problems("<!DOCTYPE html><div></div>").contains { $0.hasPrefix("document element") })
        #expect(HTML5Checker.resolve("../images/a.png", from: "pages/page-1.svg") == "images/a.png")
        #expect(HTML5Checker.resolve("./style.css", from: "index.html") == "style.css")
        #expect(HTML5Checker.svgReferences("<image xlink:href=\"../images/a.png\"/><a xlink:href=\"#page-2\"/><a xlink:href=\"../index.html#page-3\"/><style>@font-face{src:url('../fonts/f.woff2')}</style><a href=\"https://x\"/>")
            == ["../images/a.png", "../index.html", "../fonts/f.woff2"])
        #expect(HTML5Checker.unescape("a&amp;b&quot;&lt;&gt;") == "a&b\"<>")
    }
}
