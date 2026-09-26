// IO-031: SVG accessibility output.  One fixture holds every case the task names -- a described
// path, a two-line description, a decorative object, a described group with described members, a
// linked described object and outlined text -- and each is asserted element by element.  Every
// file still passes the IO-019 checks (`SVGTests.write`), and a document that describes nothing
// is written exactly as before.

import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct SVGAccessibilityTests {
    static let square = Corpus.path(Corpus.rect(10, 10, 20, 20), [Corpus.fill(.solid(Corpus.red))])

    /// Every `aria-labelledby` and `aria-describedby` names a `<title>` or `<desc>` child of the
    /// element that carries it.
    static func labelsResolve(_ root: XMLElementNode) -> Bool {
        root.descendants.allSatisfy { element in
            let own = Dictionary(element.children.compactMap { child in child.attributes["id"].map { ($0, child.name) } }, uniquingKeysWith: { a, _ in a })
            let title = element.attributes["aria-labelledby"].map { own[$0] == "title" } ?? true
            let desc = element.attributes["aria-describedby"].map { own[$0] == "desc" } ?? true
            return title && desc
        }
    }

    /// The accessibility attributes of `element`, sorted, and its `<title>` / `<desc>` texts.
    static func marks(_ element: XMLElementNode) -> (role: String?, hidden: Bool, title: String?, desc: String?) {
        let title = element.children.first { $0.name == "title" }
        let desc = element.children.first { $0.name == "desc" }
        if let title { #expect(element.children.first === title, "the title is the first child") }
        return (element.attributes["role"], element.attributes["aria-hidden"] == "true", title?.text, desc?.text)
    }

    @Test func everyCaseWritesExactlyItsElements() throws {
        let ids = (1...8).map { Corpus.node(UInt64($0)) }
        let group = DisplayItem.group(GroupItem(children: [
            Corpus.path(Corpus.rect(0, 60, 10, 10), [Corpus.fill(.solid(.black))]),
            Corpus.path(Corpus.rect(20, 60, 10, 10), [Corpus.fill(.solid(.black))]),
        ]))
        let items: [DisplayItem] = [
            Self.square,                                                                             // described path
            Corpus.path(Corpus.rect(40, 10, 20, 20), [Corpus.fill(.solid(Corpus.blue))]),            // two lines
            Corpus.path(Corpus.rect(70, 10, 20, 20), [Corpus.fill(.solid(Corpus.green))]),           // decorative
            group,                                                                                   // described group
            Corpus.path(Corpus.rect(100, 10, 20, 20), [Corpus.fill(.solid(Corpus.yellow))]),         // linked
            Corpus.text("Hello", origin: Point(x: 10, y: 120)),                                      // text
        ]
        var page = Corpus.page(items, nodes: [ids[0], ids[1], ids[2], ids[3], ids[4], ids[5]])
        page.nestedNodeIDs = [[3, 0]: ids[6], [3, 1]: ids[7]]
        let info: [NodeID: ExportNodeInfo] = [
            ids[0]: ExportNodeInfo(alt: "A red square"),
            ids[1]: ExportNodeInfo(alt: "Sales chart\nSales rose 20% in May.\n\n  Most of it online.  "),
            ids[2]: ExportNodeInfo(alt: "ignored while decorative", decorative: true),
            ids[3]: ExportNodeInfo(alt: "Two dots"),
            ids[6]: ExportNodeInfo(alt: "Left dot"), ids[7]: ExportNodeInfo(decorative: true),
            ids[4]: ExportNodeInfo(alt: "A yellow button", url: "https://example.com", linkAlt: "Opens example.com"),
        ]
        let scene = Corpus.scene([page], nodes: info, info: ExportDocumentInfo(title: "Poster", description: "A poster.\nFor the fair.", language: "en-GB"))
        for text in [SVGOptions.Text.asText, .outlines] {
            let document = SVGExporter().documents(scene: scene, options: SVGOptions(text: text, includeDocumentInfo: false))[0]
            let root = try #require(XMLTreeParser.parse(document.text))
            #expect(SVGValidator.problems(root).isEmpty, "\(SVGValidator.problems(root))")
            #expect(Self.labelsResolve(root), "\(document.text)")
            let body = root.children.filter { !["title", "desc"].contains($0.name) }
            // The described path: a title, no desc.
            let described = Self.marks(body[0])
            #expect(body[0].name == "path" && described.role == "img" && described.title == "A red square" && described.desc == nil)
            #expect(body[0].attributes["aria-describedby"] == nil)
            // Two lines: the first is the title, the rest (blank lines dropped) the desc.
            let twoLines = Self.marks(body[1])
            #expect(twoLines.title == "Sales chart" && twoLines.desc == "Sales rose 20% in May.\nMost of it online.", "\(String(describing: twoLines.desc))")
            // Decorative: hidden, no title even though it has alt text.
            let decorative = Self.marks(body[2])
            #expect(decorative.hidden && decorative.role == nil && decorative.title == nil && body[2].children.isEmpty)
            // The described group is one figure: its members carry nothing.
            let figure = Self.marks(body[3])
            #expect(body[3].name == "g" && figure.role == "img" && figure.title == "Two dots")
            let members = body[3].children.filter { $0.name == "path" }
            #expect(members.count == 2)
            #expect(members.allSatisfy { $0.children.isEmpty && $0.attributes["role"] == nil && $0.attributes["aria-hidden"] == nil })
            // The link keeps its own title; the object's title sits on the element inside.
            #expect(body[4].name == "a" && body[4].children[0].name == "title" && body[4].children[0].text == "Opens example.com")
            let linked = Self.marks(body[4].children[1])
            #expect(linked.role == "img" && linked.title == "A yellow button")
            // Text: live text is read as itself; outlined text is a figure titled with its characters.
            if text == .asText {
                #expect(body[5].name == "text" && body[5].attributes["role"] == nil && body[5].children.isEmpty)
            } else {
                let outlined = Self.marks(body[5])
                #expect(body[5].name == "path" && outlined.role == "img" && outlined.title == "Hello")
            }
            // The root: a group (it holds figures) titled from Document Info, with its language
            // even without *Include document info*.
            let rootMarks = Self.marks(root)
            #expect(rootMarks.role == "group" && rootMarks.title == "Poster" && rootMarks.desc == "A poster.\nFor the fair.")
            #expect(root.attributes["xml:lang"] == "en-GB")
            #expect(root.all("metadata").isEmpty)
        }
    }

    @Test func undescribedDocumentsAreUnchanged() {
        // No alt text and nothing decorative: no title, desc, role or ARIA attribute anywhere, and
        // the same bytes whatever names and links the objects have.
        let items = Corpus.basics + [Corpus.text("Hi", origin: Point(x: 10, y: 120))]
        let named = (1...UInt64(items.count)).map { Corpus.node($0) }
        let info = Dictionary(uniqueKeysWithValues: named.map { ($0, ExportNodeInfo(name: "n\($0.counter)")) })
        for options in [SVGOptions(), SVGOptions(text: .outlines), SVGOptions(minify: true)] {
            let plain = SVGTests.write(items, options: options).document.text
            let withNames = SVGTests.write(items, options: options, nodes: named, info: info).document.text
            for marker in ["role=", "aria-", "<title", "<desc"] {
                #expect(!plain.contains(marker) && !withNames.contains(marker))
            }
            #expect(plain == SVGTests.write(items, options: options).document.text)
        }
        // Blank alt text describes nothing either.
        let blank = SVGTests.write([Self.square], nodes: [Corpus.node(1)], info: [Corpus.node(1): ExportNodeInfo(alt: " \n ")])
        #expect(blank.document.text == SVGTests.write([Self.square]).document.text)
    }

    @Test func generatedIdsNeverCollideWithNames() {
        let ids = (1...3).map { Corpus.node(UInt64($0)) }
        let items = [Self.square, Corpus.path(Corpus.rect(40, 10, 20, 20), [Corpus.fill(.solid(.black))]), Corpus.path(Corpus.rect(70, 10, 20, 20), [Corpus.fill(.solid(.black))])]
        let info: [NodeID: ExportNodeInfo] = [
            ids[0]: ExportNodeInfo(name: "wt-title-1", alt: "One\nMore"), ids[1]: ExportNodeInfo(name: "wt-desc-1"), ids[2]: ExportNodeInfo(name: "wt-title-2", alt: "Two"),
        ]
        let result = SVGTests.write(items, nodes: ids, info: info)
        let written = result.root.descendants.compactMap { $0.attributes["id"] }
        #expect(Set(written).count == written.count)
        #expect(result.root.all("path").map { $0.attributes["id"] } == ["wt-title-1", "wt-desc-1", "wt-title-2"])
        #expect(result.root.all("path")[0].attributes["aria-labelledby"] == "wt-title-3")
        #expect(result.root.all("path")[0].attributes["aria-describedby"] == "wt-desc-2")
        #expect(Self.labelsResolve(result.root))
        // Generated object ids and generated label ids share the reservation too.
        let generated = SVGTests.write(items, options: SVGOptions(ids: .generated), nodes: ids, info: info)
        let all = generated.root.descendants.compactMap { $0.attributes["id"] }
        #expect(Set(all).count == all.count)
    }

    @Test func imagesAndRasterizedEffectsCarryTheirTitle() {
        let ids = (1...3).map { Corpus.node(UInt64($0)) }
        let items: [DisplayItem] = [
            .image(ImageItem(assetID: "photo", rect: Rect(x: 0, y: 0, width: 32, height: 24))),
            // A pattern fill renders to an image (export-vector.adoc): the image is the figure.
            Corpus.path(Corpus.rect(40, 10, 60, 40), [Corpus.fill(.pattern(PatternPaint(bitmap: .checker, color: Corpus.blue)))]),
            Corpus.path(Corpus.rect(110, 10, 50, 40), [Corpus.fill(.solid(Corpus.red))], effects: [EffectElement(.shadow(LiveEffect.Shadow(style: .innerShadow, color: .black, offset: 3, opacity: 70, softness: 3)))]),
        ]
        let info: [NodeID: ExportNodeInfo] = [ids[0]: ExportNodeInfo(alt: "A photo"), ids[1]: ExportNodeInfo(alt: "A checkerboard"), ids[2]: ExportNodeInfo(alt: "A shaded box", decorative: true)]
        let result = SVGTests.write(items, options: SVGOptions(rasterPPI: 72), nodes: ids, info: info, assets: ["photo": ExportAsset(image: Corpus.image())])
        let figures = result.root.descendants.filter { $0.attributes["role"] == "img" }
        #expect(figures.count == 2)
        #expect(figures.map { Self.marks($0).title } == ["A photo", "A checkerboard"])
        #expect(figures[0].name == "image")
        #expect(figures[1].name == "image" || figures[1].all("image").count > 0)
        let hidden = result.root.descendants.filter { $0.attributes["aria-hidden"] == "true" }
        #expect(hidden.count == 1 && hidden[0].all("image").count + (hidden[0].name == "image" ? 1 : 0) > 0)
        #expect(Self.labelsResolve(result.root))
    }

    @Test func textLabelsAndTheRoot() throws {
        let ids = (1...4).map { Corpus.node(UInt64($0)) }
        // Live text with alt text is wrapped in a figure group: a title inside `<text>` would be
        // read as preserved character data.
        let items: [DisplayItem] = [
            Corpus.text("Menu", origin: Point(x: 10, y: 40)),
            Corpus.text("Fine print", origin: Point(x: 10, y: 80)),
            // Glyphs that do not map onto the characters: outlined by the writer, read as text.
            .text(TextRunItem(text: "fi!", glyphRun: Corpus.run("fi"), origin: Point(x: 10, y: 120))),
            Self.square,
        ]
        let info: [NodeID: ExportNodeInfo] = [ids[0]: ExportNodeInfo(alt: "Today's menu"), ids[1]: ExportNodeInfo(decorative: true)]
        let result = SVGTests.write(items, options: SVGOptions(includeDocumentInfo: false), nodes: ids, info: info, scene: ExportDocumentInfo(metadata: DocumentMetadata(title: "From metadata", description: "Metadata text")))
        let wrapper = try #require(result.root.all("g").first)
        #expect(Self.marks(wrapper).role == "img" && Self.marks(wrapper).title == "Today's menu")
        #expect(wrapper.all("text").first?.text == "Menu")
        let texts = result.root.all("text")
        #expect(texts[1].attributes["aria-hidden"] == "true" && texts[1].text == "Fine print")
        let outlined = result.root.all("path").first { $0.attributes["role"] == "img" }
        #expect(outlined.map { Self.marks($0).title } == "fi!")
        // The undescribed square gets nothing.
        #expect(result.root.all("path").last?.attributes["role"] == nil)
        #expect(Self.marks(result.root).title == "From metadata" && Self.marks(result.root).desc == "Metadata text")
        #expect(Self.labelsResolve(result.root))
        // Only decorative objects: an `img` root titled with the file name, no desc, no language.
        let quiet = SVGTests.write([Self.square], nodes: [ids[3]], info: [ids[3]: ExportNodeInfo(decorative: true)])
        #expect(Self.marks(quiet.root).role == "img" && Self.marks(quiet.root).title == "Corpus" && Self.marks(quiet.root).desc == nil)
        #expect(quiet.root.attributes["xml:lang"] == nil)
        #expect(SVGBuild.label("Only") == ("Only", nil))
    }
}
