// IO-019: the SVG writer.  Every file is parsed back with XMLParser, checked against the SVG 1.1
// element and attribute vocabulary plus the SVG 2 features the writer uses, and its path
// geometry compared with the display list's within the chosen precision.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender
import struct WTRender.StrokeStyle

/// A parsed XML element.
final class XMLElementNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLElementNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func all(_ name: String) -> [XMLElementNode] {
        (self.name == name ? [self] : []) + children.flatMap { $0.all(name) }
    }

    var descendants: [XMLElementNode] {
        [self] + children.flatMap(\.descendants)
    }
}

final class XMLTreeParser: NSObject, XMLParserDelegate {
    var stack: [XMLElementNode] = []
    var root: XMLElementNode?

    static func parse(_ text: String) -> XMLElementNode? {
        let delegate = XMLTreeParser()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate
        guard parser.parse() else {
            return nil
        }
        return delegate.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let node = XMLElementNode(name: elementName, attributes: attributes)
        stack.last?.children.append(node)
        stack.append(node)
        if root == nil {
            root = node
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}

enum SVGValidator {
    static let core: Set<String> = ["id", "class", "style", "transform", "xml:space"]
    static let presentation: Set<String> = [
        "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
        "stroke-dasharray", "stroke-dashoffset", "stroke-opacity", "opacity", "clip-path", "clip-rule", "mask", "filter",
        "font-family", "font-size", "font-weight", "font-style", "vector-effect", "stop-color", "stop-opacity",
        "color-interpolation-filters", "flood-color", "flood-opacity",
    ]
    /// Element → its own attributes (beyond core and presentation).  `feDropShadow` and
    /// `vector-effect` are the SVG 2 features used.
    static let elements: [String: Set<String>] = [
        "svg": ["xmlns", "xmlns:xlink", "version", "width", "height", "viewBox"],
        "g": [], "defs": [], "style": ["type"], "metadata": [],
        "rdf:RDF": ["xmlns:rdf", "xmlns:dc"], "rdf:Description": ["rdf:about"],
        "dc:title": [], "dc:creator": [], "dc:description": [], "dc:subject": [], "dc:language": [],
        "path": ["d"], "rect": ["x", "y", "width", "height"], "text": ["x", "y"],
        "image": ["x", "y", "width", "height", "preserveAspectRatio", "xlink:href"],
        "a": ["xlink:href"],
        "linearGradient": ["gradientUnits", "x1", "y1", "x2", "y2", "gradientTransform"],
        "radialGradient": ["gradientUnits", "cx", "cy", "r", "gradientTransform"],
        "stop": ["offset"], "clipPath": ["clipPathUnits"], "mask": ["maskUnits", "x", "y", "width", "height"],
        "filter": ["filterUnits", "x", "y", "width", "height"],
        "feGaussianBlur": ["in", "stdDeviation", "result"], "feDropShadow": ["dx", "dy", "stdDeviation"],
        "feMorphology": ["in", "operator", "radius", "result"], "feFlood": [], "feComposite": ["in2", "operator", "result"],
        "feMerge": [], "feMergeNode": ["in"],
    ]

    /// Problems with `root`: unknown elements or attributes, dangling references, duplicate ids.
    static func problems(_ root: XMLElementNode) -> [String] {
        var result: [String] = []
        var ids = Set<String>()
        for node in root.descendants {
            guard let own = elements[node.name] else {
                result.append("element \(node.name)")
                continue
            }
            for key in node.attributes.keys where !own.contains(key) && !core.contains(key) && !presentation.contains(key) {
                result.append("\(node.name)@\(key)")
            }
            if let id = node.attributes["id"] {
                if !ids.insert(id).inserted { result.append("duplicate id \(id)") }
                if id.range(of: "^[A-Za-z_][A-Za-z0-9_-]*$", options: .regularExpression) == nil { result.append("bad id \(id)") }
            }
        }
        for node in root.descendants {
            for value in node.attributes.values {
                if let range = value.range(of: #"url\(#([^)]+)\)"#, options: .regularExpression) {
                    let id = String(value[range].dropFirst(5).dropLast())
                    if !ids.contains(id) { result.append("dangling \(id)") }
                }
            }
        }
        return result
    }
}

/// Parses path data written by the SVG writer (absolute M, L, Q, C, Z).
enum PathDataParser {
    static func points(_ data: String) -> [Point] {
        var numbers: [Double] = []
        var result: [Point] = []
        var token = ""
        func flush() {
            if let value = Double(token) { numbers.append(value) }
            token = ""
        }
        for character in data {
            if character.isLetter {
                flush()
            } else if character == " " {
                flush()
            } else {
                token.append(character)
            }
        }
        flush()
        for index in stride(from: 0, to: numbers.count - 1, by: 2) {
            result.append(Point(x: numbers[index], y: numbers[index + 1]))
        }
        return result
    }
}

@Suite struct SVGTests {
    static func write(_ items: [DisplayItem], options: SVGOptions = SVGOptions(), nodes: [NodeID?] = [], info: [NodeID: ExportNodeInfo] = [:], scene sceneInfo: ExportDocumentInfo = ExportDocumentInfo(), assets: [String: ExportAsset] = [:], background: Color? = nil) -> (document: SVGDocument, root: XMLElementNode) {
        let page = Corpus.page(items, nodes: nodes, background: background)
        let scene = Corpus.scene([page], nodes: info, assets: assets, info: sceneInfo)
        let document = SVGExporter().documents(scene: scene, options: options)[0]
        let root = XMLTreeParser.parse(document.text)
        #expect(root != nil, "not well-formed:\n\(document.text)")
        let problems = root.map(SVGValidator.problems) ?? []
        #expect(problems.isEmpty, "\(problems)")
        return (document, root ?? XMLElementNode(name: "none", attributes: [:]))
    }

    @Test(arguments: Corpus.fixtures)
    func corpusValidates(_ name: String) {
        for styling in [SVGOptions.Styling.presentationAttributes, .cssClasses, .inlineStyle] {
            let result = Self.write(Corpus.fixture(name).displayList.items, options: SVGOptions(styling: styling))
            #expect(result.root.name == "svg")
        }
    }

    @Test func geometryRoundTripsWithinPrecision() {
        let path = Corpus.wave(10.123456, 20.654321, 80.5, 30.25)
        let transform = AffineTransform.rotation(radians: 0.25).concatenating(.translation(x: 30, y: 10))
        for precision in [1, 3, 6] {
            let result = Self.write([Corpus.path(path, [Corpus.stroke(.solid(.black), width: 2)], transform: transform)], options: SVGOptions(precision: precision))
            let d = result.root.all("path")[0].attributes["d"]!
            let written = PathDataParser.points(d)
            let expected = path.elements.flatMap { element -> [Point] in
                switch element {
                case .move(let p), .line(let p): return [p]
                case .cubicCurve(let a, let b, let c): return [a, b, c]
                default: return []
                }
            }.map(transform.apply)
            #expect(written.count == expected.count)
            let tolerance = 0.5 * pow(10, -Double(precision)) + 1e-9
            for (a, b) in zip(written, expected) {
                #expect(abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance)
            }
            #expect(result.root.all("path")[0].attributes["stroke-width"] == "2")
        }
        // A skewed element keeps local coordinates and a transform attribute.
        let skewed = Self.write([Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.black))], transform: AffineTransform(a: 1, b: 0, c: 0.5, d: 1, tx: 0, ty: 0))])
        #expect(skewed.root.all("path")[0].attributes["transform"] == "matrix(1 0 0.5 1 0 0)")
        #expect(skewed.root.all("path")[0].attributes["d"] == "M0 0 L10 0 L10 10 L0 10 Z")
    }

    @Test func idsComeFromNames() {
        let ids = (1...5).map { Corpus.node(UInt64($0)) }
        let items = (0..<5).map { index in Corpus.path(Corpus.rect(Double(index) * 20, 0, 10, 10), [Corpus.fill(.solid(.black))]) }
        let info: [NodeID: ExportNodeInfo] = [
            ids[0]: ExportNodeInfo(name: "Logo"), ids[1]: ExportNodeInfo(name: "Logo"),
            ids[2]: ExportNodeInfo(name: "3 Eyes & Ears"), ids[3]: ExportNodeInfo(name: "___"), ids[4]: ExportNodeInfo(name: "wt-g1"),
        ]
        let gradient = Corpus.path(Corpus.rect(0, 20, 10, 10), [Corpus.fill(Corpus.gradient(.linear))])
        let named = Self.write(items + [gradient], nodes: ids, info: info)
        let written = named.root.all("path").compactMap { $0.attributes["id"] }
        #expect(written == ["Logo", "Logo-2", "_3_Eyes___Ears", "wt-g1"])
        #expect(named.root.all("linearGradient")[0].attributes["id"] == "wt-g2")
        let generated = Self.write(items, options: SVGOptions(ids: .generated), nodes: ids, info: info)
        #expect(generated.root.all("path").compactMap { $0.attributes["id"] } == ["o1", "o2", "o3", "o4", "o5"])
        let none = Self.write(items, options: SVGOptions(ids: .none), nodes: ids, info: info)
        #expect(none.root.all("path").compactMap { $0.attributes["id"] }.isEmpty)
        #expect(SVGIdentifiers.sanitize("-x") == "_-x")
        #expect(SVGIdentifiers.sanitize("é") == nil)
        var identifiers = SVGIdentifiers()
        identifiers.reserve("st1")
        #expect(identifiers.generate("st") == "st2")
    }

    @Test func layersAndLinks() {
        let layer = Corpus.node(1), linked = Corpus.node(2)
        let group = DisplayItem.group(GroupItem(children: [Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(.black))]), Corpus.path(Corpus.rect(20, 0, 10, 10), [Corpus.fill(.solid(.black))])]))
        var page = Corpus.page([group], nodes: [layer])
        page.nestedNodeIDs = [[0, 1]: linked]
        let scene = Corpus.scene([page], nodes: [layer: ExportNodeInfo(name: "Layer 1", isLayer: true), linked: ExportNodeInfo(name: "Button", url: "https://example.com/?a=1&b=2")])
        let document = SVGExporter().documents(scene: scene, options: SVGOptions())[0]
        let root = XMLTreeParser.parse(document.text)!
        #expect(SVGValidator.problems(root).isEmpty)
        #expect(root.all("g")[0].attributes["id"] == "Layer_1")
        let link = root.all("a")[0]
        #expect(link.attributes["xlink:href"] == "https://example.com/?a=1&b=2")
        #expect(link.children[0].attributes["id"] == "Button")
    }

    @Test func stylingModes() {
        let items = [
            Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(Corpus.red)), Corpus.stroke(.solid(Color.black.withAlpha(multipliedBy: 0.5)), width: 1, cap: .round, join: .bevel, dash: [2, 1])]),
            Corpus.path(Corpus.rect(20, 0, 10, 10), [Corpus.fill(.solid(Corpus.red))]),
        ]
        let presentation = Self.write(items)
        let first = presentation.root.all("path")[0]
        #expect(first.attributes["fill"] == "#e61a1a")
        #expect(presentation.root.all("path")[1].attributes["stroke-opacity"] == "0.5")
        #expect(presentation.root.all("path")[1].attributes["stroke-linecap"] == "round")
        #expect(presentation.root.all("path")[1].attributes["stroke-linejoin"] == "bevel")
        #expect(presentation.root.all("path")[1].attributes["stroke-dasharray"] == "2 1")
        let classes = Self.write(items, options: SVGOptions(styling: .cssClasses))
        let style = classes.root.all("style")[0].text
        #expect(style.contains(".st1{fill:#e61a1a}"))
        #expect(classes.root.all("path")[0].attributes["class"] == "st1")
        #expect(classes.root.all("path")[2].attributes["class"] == "st1")
        let inline = Self.write(items, options: SVGOptions(styling: .inlineStyle))
        #expect(inline.root.all("path")[0].attributes["style"] == "fill:#e61a1a")
        #expect(inline.root.all("path")[0].attributes["fill"] == nil)
    }

    @Test func strokeDetails() {
        let items = [
            Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.stroke(.solid(.black), width: 0)]),
            .path(PathItem(path: Corpus.rect(20, 0, 10, 10), appearance: Appearance([.stroke(StrokePaint(paint: .solid(.black), style: StrokeStyle(width: 2, miterLimit: 4, dash: [3, 1], dashPhase: 1)))]), transform: .scale(2))),
        ]
        let result = Self.write(items)
        let hairline = result.root.all("path")[0]
        #expect(hairline.attributes["vector-effect"] == "non-scaling-stroke")
        let scaled = result.root.all("path")[1]
        #expect(scaled.attributes["stroke-width"] == "4")
        #expect(scaled.attributes["stroke-miterlimit"] == nil)
        #expect(scaled.attributes["stroke-dasharray"] == "6 2")
        #expect(scaled.attributes["stroke-dashoffset"] == "2")
    }

    @Test func sizeMetadataBackgroundAndMinify() {
        let info = ExportDocumentInfo(title: "Poster", author: "Tea", subject: "Art", description: "A poster", keywords: ["one", "two"], language: "en-US")
        let fixed = Self.write(Corpus.basics, options: SVGOptions(responsive: false, sizeUnit: "mm", pageBackground: true), scene: info, background: Color(white: 0.9))
        #expect(fixed.root.attributes["width"] == "70.556mm")
        #expect(fixed.root.attributes["viewBox"] == "0 0 200 150")
        #expect(fixed.root.all("dc:title")[0].text == "Poster")
        #expect(fixed.root.all("dc:subject").count == 3)
        #expect(fixed.root.all("rect")[0].attributes["fill"] == "#e6e6e6")
        #expect(fixed.document.text.contains("<!-- Generator: WireTuner -->"))
        let responsive = Self.write(Corpus.basics, options: SVGOptions(minify: true, includeDocumentInfo: false), scene: info)
        #expect(responsive.root.attributes["width"] == nil)
        #expect(responsive.root.all("metadata").isEmpty)
        #expect(!responsive.document.text.contains("\n"))
        #expect(!responsive.document.text.contains("<!--"))
    }

    @Test func gradientsAreSharedAndSampled() {
        let paint = Corpus.gradient(.linear, axis: Gradient.Axis(start: Point(x: 0, y: 0), end: Point(x: 10, y: 0)))
        let items = [
            Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(paint)]),
            Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(paint)]),
            Corpus.path(Corpus.ellipse(20, 0, 20, 10), [Corpus.fill(Corpus.gradient(.radial))], transform: AffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)),
            Corpus.path(Corpus.rect(0, 20, 10, 10), [Corpus.fill(Corpus.gradient(.linear, stops: [Gradient.Stop(offset: 0, color: Color.black.withAlpha(multipliedBy: 0.5)), Gradient.Stop(offset: 1, color: .white)]))]),
            Corpus.path(Corpus.rect(0, 40, 10, 10), [Corpus.fill(Corpus.gradient(.linear, stops: [Gradient.Stop(offset: 0, color: .black), Gradient.Stop(offset: 0.5, color: .black), Gradient.Stop(offset: 1, color: .black)]))]),
        ]
        let result = Self.write(items)
        #expect(result.root.all("linearGradient").count == 3)
        #expect(result.root.all("path")[0].attributes["fill"] == result.root.all("path")[1].attributes["fill"])
        #expect(result.root.all("radialGradient")[0].attributes["gradientTransform"] != nil)
        #expect(result.root.all("stop").contains { $0.attributes["stop-opacity"] != nil })
        #expect(result.root.all("linearGradient")[2].children.count < 10)
    }

    @Test func masksFiltersAndClips() {
        let result = Self.write(Corpus.effects + Corpus.transparency)
        #expect(result.root.all("mask").count == 1)
        #expect(result.root.all("feGaussianBlur").count == 2)
        #expect(result.root.all("feDropShadow").count == 1)
        #expect(result.root.all("feMorphology").count == 1)
        #expect(result.root.all("clipPath").count == 1)
        #expect(result.root.all("image").count == 3)
        #expect(result.root.all("g").contains { $0.attributes["opacity"] == "0.6" })
        // The mask paints white with the factor as opacity.
        let maskStops = result.root.all("stop").filter { $0.attributes["stop-color"] == "#ffffff" }
        #expect(maskStops.count >= 65)
    }

    @Test func wideColorsGetDisplayP3() {
        let wide = Color(red: 1.1, green: -0.05, blue: 0.2)
        let result = Self.write([Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(wide))])])
        let path = result.root.all("path")[0]
        #expect(path.attributes["fill"] == "#ff0033")
        #expect(path.attributes["style"]!.hasPrefix("fill:color(display-p3 "))
        #expect(result.document.notes.contains("1 wide-gamut color written as Display P3 with an sRGB fallback"))
        let classes = Self.write([Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(wide))]), Corpus.path(Corpus.rect(0, 0, 10, 10), [Corpus.fill(.solid(wide))])], options: SVGOptions(styling: .cssClasses))
        #expect(classes.root.all("style")[0].text.contains("fill:#ff0033;fill:color(display-p3"))
        #expect(classes.document.notes.contains("2 wide-gamut colors written as Display P3 with an sRGB fallback"))
    }

    @Test func textModes() {
        let items = [Corpus.text("Hello"), Corpus.text("Bold", font: "Helvetica-BoldOblique", origin: Point(x: 10, y: 80), transform: .rotation(radians: 0.1))]
        let text = Self.write(items)
        let elements = text.root.all("text")
        #expect(elements.count == 2)
        #expect(elements[0].text == "Hello")
        #expect(elements[0].attributes["font-family"] == "'Helvetica'")
        #expect(elements[0].attributes["y"] == "40")
        #expect(elements[0].attributes["x"]!.split(separator: " ").count == 5)
        #expect(elements[1].attributes["font-weight"] == "700")
        #expect(elements[1].attributes["font-style"] == "italic")
        #expect(elements[1].attributes["transform"] != nil)
        let outlined = Self.write(items, options: SVGOptions(text: .outlines))
        #expect(outlined.root.all("text").isEmpty)
        #expect(outlined.root.all("path").count == 2)
        let embedded = Self.write(items + [Corpus.text("Hi", origin: Point(x: 10, y: 120))], options: SVGOptions(text: .asTextEmbedFonts))
        let style = embedded.root.all("style")[0].text
        #expect(style.contains("@font-face{font-family:'wt-font-1';src:url(data:font/ttf;base64,"))
        #expect(embedded.root.all("text")[0].attributes["font-family"] == "'wt-font-1', 'Helvetica'")
        #expect(embedded.root.all("text")[2].attributes["font-family"] == "'wt-font-1', 'Helvetica'")
        // A font without TrueType outlines, and a run whose glyphs do not map to characters,
        // are outlined with a note.
        let cff = Self.write([Corpus.text("Kohinoor", font: "KohinoorDevanagari-Regular")], options: SVGOptions(text: .asTextEmbedFonts))
        #expect(cff.root.all("text").isEmpty)
        #expect(cff.document.notes.contains { $0.contains("cannot be embedded") })
        let ligature = TextRunItem(text: "fi!", glyphRun: Corpus.run("fi"), origin: Point(x: 0, y: 20))
        let mismatched = Self.write([.text(ligature)])
        #expect(mismatched.root.all("text").isEmpty)
        #expect(mismatched.document.notes.contains { $0.contains("do not map one to one") })
        let spaced = TextRunItem(text: "  ", glyphRun: Corpus.run("  "), origin: Point(x: 0, y: 20))
        #expect(Self.write([.text(spaced)]).root.all("text")[0].text == "  ")
    }

    @Test func imageModes() throws {
        let picture = Corpus.image(alpha: true)
        let jpeg = Corpus.jpeg(Corpus.image())
        let assets = ["alpha": ExportAsset(image: picture), "photo": ExportAsset(image: Corpus.image(), jpegData: jpeg)]
        let items: [DisplayItem] = [
            .image(ImageItem(assetID: "alpha", rect: Rect(x: 0, y: 0, width: 32, height: 24))),
            .image(ImageItem(assetID: "photo", rect: Rect(x: 40, y: 0, width: 32, height: 24), transform: .rotation(radians: 0.2))),
        ]
        let embedded = Self.write(items, assets: assets)
        let images = embedded.root.all("image")
        #expect(images[0].attributes["xlink:href"]!.hasPrefix("data:image/png;base64,"))
        #expect(images[1].attributes["xlink:href"]!.hasPrefix("data:image/jpeg;base64,"))
        #expect(images[1].attributes["transform"] != nil)
        let linked = Self.write(items, options: SVGOptions(images: .link), assets: assets)
        #expect(linked.document.resources.map(\.path) == ["images/image-1.png", "images/image-2.png"])
        let originals = Self.write(items, options: SVGOptions(images: .linkOriginals), assets: assets)
        #expect(originals.document.resources.map(\.path) == ["images/image-1.png", "images/image-2.jpg"])
        #expect(originals.document.resources[1].data == jpeg)
    }

    @Test func exporterWritesFilesAndResources() throws {
        let directory = Corpus.directory()
        let picture = ExportAsset(image: Corpus.image())
        let pages = [Corpus.page([.image(ImageItem(assetID: "a", rect: Rect(x: 0, y: 0, width: 20, height: 20)))], name: "Front"), Corpus.page(Corpus.basics, name: "Back")]
        let scene = Corpus.scene(pages, assets: ["a": picture])
        let summary = try SVGExporter().export(scene: scene, options: SVGOptions(images: .link, rasterPPI: 72), to: ExportDestination(url: directory.appendingPathComponent("Art.svg"), namePattern: "{name}-{pagename}"))
        #expect(summary.files.map(\.lastPathComponent) == ["image-1.png", "Art-Front.svg", "Art-Back.svg"])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Art-Front/image-1.png").path))
        let exporter = SVGExporter()
        #expect(exporter.optionsType is SVGOptions.Type)
        #expect(throws: ExportError.self) { try exporter.export(scene: scene, options: SVGOptions(precision: 7), to: ExportDestination(url: directory.appendingPathComponent("x.svg"))) }
        #expect(throws: ExportError.self) { try exporter.export(scene: scene, options: SVGOptions(sizeUnit: "cm"), to: ExportDestination(url: directory.appendingPathComponent("x.svg"))) }
        #expect(throws: ExportError.self) { try exporter.export(scene: scene, options: SVGOptions(rasterPPI: -1), to: ExportDestination(url: directory.appendingPathComponent("x.svg"))) }
        #expect(throws: ExportError.wrongOptions(format: .svg)) { try exporter.export(scene: scene, options: PDFOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.svg"))) }
        #expect(throws: ExportError.nothingToExport) { try exporter.export(scene: Corpus.scene([]), options: SVGOptions(), to: ExportDestination(url: directory.appendingPathComponent("x.svg"))) }
        #expect(throws: ExportError.self) {
            try exporter.export(scene: Corpus.scene([pages[1]]), options: SVGOptions(), to: ExportDestination(url: URL(fileURLWithPath: "/nonexistent-folder/x.svg")))
        }
        #expect(SVGOptions.defaults == SVGOptions())
    }

    @Test func xmlStreamEscapes() {
        #expect(XMLStream.escape("a<b>&\"c\"\n\u{1}") == "a&lt;b&gt;&amp;&quot;c&quot;&#10;")
        #expect(XMLStream.escape("t\tn\n\u{FFFE}", attribute: false) == "t\tn\n")
        var stream = XMLStream(minify: false)
        stream.start("a")
        stream.characters("x")
        stream.end()
        #expect(stream.text == "<a>x</a>")
    }
}
