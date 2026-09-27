// IO-032: tagged PDF and PDF/UA-1.  The structure tree is read back through CGPDF -- element types,
// alt text, actual text, the order of each page's kids -- and held against the content streams: every
// marked-content id is unique in its stream and referenced by exactly one element.  The PDF/UA-1
// claim is checked for each eligibility rule, and veraPDF validates the claimed files when it is
// installed.

import CoreGraphics
import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

/// A structure tree read back from a file.
struct ReadTagTree {
    struct Element {
        var type: String
        var alt: String?
        var actualText: String?
        var hasBBox = false
        var children: [Element] = []
        /// Marked-content ids: (page index, form stream or nil, id).
        var marks: [(page: Int, stream: UnsafeRawPointer?, mcid: Int)] = []
        var annotations = 0

        var all: [Element] { [self] + children.flatMap(\.all) }
    }

    var root: Element
    /// The ids marked in each content stream: (page index, form stream or nil) → ids in order.
    var streamMarks: [String: [Int]] = [:]
    var parentTreeKeys = 0

    static func key(_ page: Int, _ stream: UnsafeRawPointer?) -> String {
        "\(page)|\(stream.map { "\($0)" } ?? "page")"
    }

    init?(_ data: Data) {
        root = Element(type: "StructTreeRoot")
        guard let document = CGPDFDocument(CGDataProvider(data: data as CFData)!), let catalog = document.catalog else { return nil }
        var marks: [String: [Int]] = [:]
        var tree: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &tree), let tree else { return nil }
        var pages: [UnsafeRawPointer] = []
        for index in 1...max(document.numberOfPages, 1) {
            if let page = document.page(at: index)?.dictionary {
                pages.append(Self.raw(page))
                // The page's content and its forms' content.
                var contents: CGPDFStreamRef?
                if CGPDFDictionaryGetStream(page, "Contents", &contents), let contents {
                    marks[Self.key(index - 1, nil)] = Self.mcids(contents)
                }
                var resources: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources, CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects {
                    CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
                        var stream: CGPDFStreamRef?
                        if CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) {
                            marks[Self.key(index - 1, Self.raw(dictionary))] = Self.mcids(stream)
                        }
                        return true
                    }, nil)
                }
            }
        }
        var parentTree: CGPDFDictionaryRef?, nums: CGPDFArrayRef?
        if CGPDFDictionaryGetDictionary(tree, "ParentTree", &parentTree), let parentTree, CGPDFDictionaryGetArray(parentTree, "Nums", &nums), let nums {
            parentTreeKeys = CGPDFArrayGetCount(nums) / 2
        }
        streamMarks = marks
        var kid: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(tree, "K", &kid), let kid {
            root.children = Self.kids(kid, pages: pages, page: nil, into: &root)
        }
    }

    static func raw(_ dictionary: CGPDFDictionaryRef) -> UnsafeRawPointer {
        unsafeBitCast(dictionary, to: UnsafeRawPointer.self)
    }

    static func mcids(_ stream: CGPDFStreamRef) -> [Int] {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let regex = try! NSRegularExpression(pattern: #"<</MCID (\d+)>> BDC"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { Int((text as NSString).substring(with: $0.range(at: 1)))! }
    }

    static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    /// The elements (and, into `parent`, the marks) of kid object `object`.
    static func kids(_ object: CGPDFObjectRef, pages: [UnsafeRawPointer], page: Int?, into parent: inout Element) -> [Element] {
        var integer: CGPDFInteger = 0
        var array: CGPDFArrayRef?
        var dictionary: CGPDFDictionaryRef?
        if CGPDFObjectGetValue(object, .integer, &integer) {
            parent.marks.append((page ?? -1, nil, integer))
            return []
        }
        if CGPDFObjectGetValue(object, .array, &array), let array {
            var result: [Element] = []
            for index in 0..<CGPDFArrayGetCount(array) {
                var item: CGPDFObjectRef?
                if CGPDFArrayGetObject(array, index, &item), let item { result += kids(item, pages: pages, page: page, into: &parent) }
            }
            return result
        }
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return [] }
        var type: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dictionary, "Type", &type)
        let typeName = type.map { String(cString: $0) }
        var pg: CGPDFDictionaryRef?
        let ownPage = CGPDFDictionaryGetDictionary(dictionary, "Pg", &pg) ? pg.flatMap { p in pages.firstIndex(of: Self.raw(p)) } : page
        if typeName == "MCR" {
            var mcid: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dictionary, "MCID", &mcid)
            var stream: CGPDFStreamRef?
            let form = CGPDFDictionaryGetStream(dictionary, "Stm", &stream) ? stream.flatMap(CGPDFStreamGetDictionary).map(Self.raw) : nil
            parent.marks.append((ownPage ?? -1, form, mcid))
            return []
        }
        if typeName == "OBJR" {
            parent.annotations += 1
            return []
        }
        var s: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dictionary, "S", &s)
        var element = Element(type: s.map { String(cString: $0) } ?? "?", alt: string(dictionary, "Alt"), actualText: string(dictionary, "ActualText"))
        var attributes: CGPDFDictionaryRef?, box: CGPDFArrayRef?
        element.hasBBox = CGPDFDictionaryGetDictionary(dictionary, "A", &attributes) && attributes.map { CGPDFDictionaryGetArray($0, "BBox", &box) } == true
        var kid: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dictionary, "K", &kid), let kid {
            element.children = kids(kid, pages: pages, page: ownPage, into: &element)
        }
        return [element]
    }

    /// Every id marked in a content stream is referenced by exactly one element, and no element
    /// references an id that is not marked.
    var marksResolve: Bool {
        var referenced: [String: [Int]] = [:]
        for element in root.all {
            for mark in element.marks { referenced[Self.key(mark.page, mark.stream), default: []].append(mark.mcid) }
        }
        let marked = streamMarks.filter { !$0.value.isEmpty }
        guard Set(marked.keys) == Set(referenced.keys) else { return false }
        return marked.allSatisfy { key, ids in Set(ids).count == ids.count && ids.sorted() == referenced[key]!.sorted() }
    }

    /// The elements of page `index`'s section, in order.
    func section(_ index: Int) -> [Element] {
        root.children.first?.children[index].children ?? []
    }
}

@Suite struct PDFTaggedTests {
    static let square = Corpus.path(Corpus.rect(10, 10, 20, 20), [Corpus.fill(.solid(Corpus.red))])
    static let ids = (1...12).map { Corpus.node(UInt64($0)) }

    /// A page with a described path, a decorative path, a text object, a described group with
    /// members, a group without alt text holding a described member, and a linked described path.
    static func fixture() -> (page: ExportPage, info: [NodeID: ExportNodeInfo]) {
        let group = DisplayItem.group(GroupItem(children: [
            Corpus.path(Corpus.rect(0, 60, 10, 10), [Corpus.fill(.solid(.black))]),
            Corpus.path(Corpus.rect(20, 60, 10, 10), [Corpus.fill(.solid(.black))]),
        ]))
        let plain = DisplayItem.group(GroupItem(children: [
            Corpus.path(Corpus.rect(40, 60, 10, 10), [Corpus.fill(.solid(Corpus.blue))]),
            Corpus.path(Corpus.rect(60, 60, 10, 10), [Corpus.fill(.solid(Corpus.green))]),
        ]))
        let items: [DisplayItem] = [
            square,
            Corpus.path(Corpus.rect(70, 10, 20, 20), [Corpus.fill(.solid(Corpus.green))]),
            Corpus.text("Hello there", origin: Point(x: 10, y: 120)),
            group,
            plain,
            Corpus.path(Corpus.rect(100, 10, 20, 20), [Corpus.fill(.solid(Corpus.yellow))]),
        ]
        var page = Corpus.page(items, nodes: Array(ids[0..<6]))
        page.nestedNodeIDs = [[3, 0]: ids[6], [3, 1]: ids[7], [4, 0]: ids[8], [4, 1]: ids[9]]
        let info: [NodeID: ExportNodeInfo] = [
            ids[0]: ExportNodeInfo(alt: "A red square"),
            ids[1]: ExportNodeInfo(decorative: true),
            ids[3]: ExportNodeInfo(alt: "Two dots"),
            ids[6]: ExportNodeInfo(alt: "never read: inside a figure"),
            ids[8]: ExportNodeInfo(alt: "A blue dot"), ids[9]: ExportNodeInfo(decorative: true),
            ids[5]: ExportNodeInfo(alt: "A yellow button", url: "https://example.com", linkAlt: "Opens example.com"),
        ]
        return (page, info)
    }

    static let english = ExportDocumentInfo(title: "Poster", language: "en-GB")

    static func export(_ pages: [ExportPage], options: PDFOptions = PDFOptions(), nodes: [NodeID: ExportNodeInfo], info: ExportDocumentInfo = english) throws -> (data: Data, notes: [String], tree: ReadTagTree) {
        let result = try PDFExporter().data(scene: Corpus.scene(pages, nodes: nodes, info: info), options: options)
        #expect(PDFDocument(data: result.data) != nil, "PDFKit cannot open the file")
        return (result.data, result.notes, try #require(ReadTagTree(result.data), "no structure tree"))
    }

    @Test func everyCaseIsTaggedAsItsRoleSays() throws {
        let (page, info) = Self.fixture()
        let result = try Self.export([page], nodes: info)
        let tree = result.tree
        #expect(tree.root.children.map(\.type) == ["Document"])
        let section = tree.section(0)
        #expect(section.map(\.type) == ["Figure", "P", "Figure", "Figure", "Figure", "Link"], "\(section.map(\.type))")
        #expect(section[0].alt == "A red square" && section[0].hasBBox)
        #expect(section[1].children.map(\.type) == ["Span"] && section[1].children[0].actualText == nil)
        #expect(section[2].alt == "Two dots" && section[2].children.isEmpty)
        #expect(section[3].alt == "A blue dot")
        #expect(section[4].alt == "A yellow button")
        #expect(section[5].alt == "Opens example.com" && section[5].annotations == 1)
        #expect(tree.marksResolve, "\(tree.streamMarks)")
        let raw = PDFTests.text(of: result.data)
        #expect(raw.contains("/Artifact BMC"))
        #expect(raw.contains("/MarkInfo <</Marked true>>") && raw.contains("/StructParents 0") && raw.contains("/StructParent 1"))
        #expect(raw.contains("/Tabs /S"))
        #expect(raw.contains("<pdfuaid:part>1</pdfuaid:part>") && raw.contains("/DisplayDocTitle true"))
        #expect(result.notes.contains("tagged PDF conforming to PDF/UA-1"))
        #expect(tree.parentTreeKeys == 2)
    }

    @Test func readingOrderOrdersEachSection() throws {
        let (page, info) = Self.fixture()
        var arranged = page
        arranged.readingOrder = [Self.ids[5], Self.ids[2]]
        let tree = try Self.export([arranged, page], nodes: info).tree
        let types = tree.section(0).map { $0.alt ?? $0.type }
        #expect(types == ["A yellow button", "Opens example.com", "P", "A red square", "Two dots", "A blue dot"], "\(types)")
        #expect(tree.section(1).first?.alt == "A red square")
        #expect(tree.marksResolve)
    }

    @Test func eachEligibilityRuleDropsTheClaimAndSaysWhy() throws {
        let (page, info) = Self.fixture()
        var undescribed = info
        undescribed[Self.ids[0]] = ExportNodeInfo(name: "Red square")
        let cases: [(PDFOptions, [NodeID: ExportNodeInfo], ExportDocumentInfo, String)] = [
            (PDFOptions(), undescribed, Self.english, "1 object has no alt text (Red square)"),
            (PDFOptions(), info, ExportDocumentInfo(title: "Poster"), "no document language is set in Document Info"),
            (PDFOptions(fonts: .outlines), info, Self.english, "text is converted to outlines"),
        ]
        for (options, nodes, documentInfo, reason) in cases {
            let result = try Self.export([page], options: options, nodes: nodes, info: documentInfo)
            let raw = PDFTests.text(of: result.data)
            #expect(!raw.contains("pdfuaid:part>1") && !raw.contains("/DisplayDocTitle"))
            #expect(result.notes.contains { $0.hasPrefix("tagged PDF without the PDF/UA-1 claim") && $0.contains(reason) }, "\(result.notes)")
            #expect(result.tree.marksResolve)
        }
        // Outlined text reads as its characters.
        let outlined = try Self.export([page], options: PDFOptions(fonts: .outlines), nodes: info)
        let paragraph = try #require(outlined.tree.section(0).first { $0.type == "P" })
        #expect(paragraph.children.first?.actualText == "Hello there")
        // Many undescribed objects are counted, the first five named.
        let squares = (0..<7).map { Corpus.path(Corpus.rect(Double($0) * 20, 10, 10, 10), [Corpus.fill(.solid(.black))]) }
        let many = Corpus.page(squares, nodes: Array(Self.ids.prefix(7)))
        let named = Dictionary(uniqueKeysWithValues: Self.ids.prefix(6).map { ($0, ExportNodeInfo(name: "N\($0.counter)")) })
        let result = try Self.export([many], nodes: named)
        #expect(result.notes.contains { $0.contains("7 objects have no alt text (N1, N2, N3, N4, N5 and 2 more)") }, "\(result.notes)")
    }

    @Test func untaggedFilesAreUnchangedAndTaggingIsSmall() throws {
        let (page, info) = Self.fixture()
        let untagged = try PDFExporter().data(scene: Corpus.scene([page], nodes: info, info: Self.english), options: {
            var options = PDFOptions()
            options.tagged = false
            return options
        }())
        #expect(ReadTagTree(untagged.data) == nil)
        let raw = PDFTests.text(of: untagged.data)
        #expect(!raw.contains("BDC") && !raw.contains("StructParent") && !raw.contains("pdfuaid:part"))
        // A document with no alt text anywhere still tags its text and artifacts, and grows by
        // under 3% over the corpus.
        var taggedTotal = 0, plainTotal = 0
        var plain = PDFOptions()
        plain.tagged = false
        for name in Corpus.fixtures {
            let scene = Corpus.scene([Corpus.fixture(name)], info: Self.english)
            taggedTotal += try PDFExporter().data(scene: scene, options: PDFOptions()).data.count
            plainTotal += try PDFExporter().data(scene: scene, options: plain).data.count
        }
        #expect(Double(taggedTotal) < Double(plainTotal) * 1.03, "\(taggedTotal) vs \(plainTotal)")
        let bare = try Self.export([Corpus.page([Corpus.text("Only text")], nodes: [Corpus.node(70)]), Corpus.page([Self.square], nodes: [Corpus.node(71)])], nodes: [:])
        #expect(bare.tree.section(0).map(\.type) == ["P"])
        #expect(bare.tree.section(1).map(\.type) == ["Figure"] && bare.tree.section(1)[0].alt == nil)
        #expect(bare.tree.marksResolve)
    }

    @Test func transparencyGroupsAndNotesAndCommentsAreTagged() throws {
        // A layer at half opacity holding two objects: each is tagged inside the layer's form.
        let layer = Corpus.node(40), a = Corpus.node(41), b = Corpus.node(42)
        var page = Corpus.page([.group(GroupItem(children: [Self.square, Corpus.text("Faded")], opacity: 0.5))], nodes: [layer])
        page.nestedNodeIDs = [[0, 0]: a, [0, 1]: b]
        var options = PDFOptions(notesAsComments: true)
        options.commentsAsAnnotations = true
        var scene = Corpus.scene([page], nodes: [layer: ExportNodeInfo(isLayer: true), a: ExportNodeInfo(alt: "Square", note: "Check this")], info: Self.english)
        scene.comments = [ExportCommentThread(pin: Point(x: 50, y: 50), resolved: false, comments: [ExportComment(author: "Ann", text: "Hi", wallTimeMs: 0), ExportComment(author: "Bo", text: "Yes", wallTimeMs: 1)])]
        let result = try PDFExporter().data(scene: scene, options: options)
        let tree = try #require(ReadTagTree(result.data))
        #expect(tree.section(0).map(\.type) == ["Figure", "Annot", "P", "Annot", "Annot"], "\(tree.section(0).map(\.type))")
        #expect(tree.section(0)[0].marks.first?.stream != nil, "tagged inside the form")
        #expect(tree.marksResolve, "\(tree.streamMarks)")
        // A described object at half opacity is one figure around its form; a faded text object
        // one paragraph reading its characters.
        let c = Corpus.node(43), d = Corpus.node(44)
        let faded = Corpus.page([.group(GroupItem(children: [Self.square], opacity: 0.5)), .group(GroupItem(children: [Corpus.text("Soft", origin: Point(x: 10, y: 90))], opacity: 0.5))], nodes: [c, d])
        let second = try Self.export([faded], nodes: [c: ExportNodeInfo(alt: "Faded square")])
        #expect(second.tree.section(0).map(\.type) == ["Figure", "P"])
        #expect(second.tree.section(0)[1].actualText == "Soft")
        #expect(second.tree.marksResolve)
    }

    @Test func pageLinksAndTextLinksAreLinkElements() throws {
        let a = Corpus.node(50), t = Corpus.node(51)
        let first = Corpus.page([Self.square, Corpus.text("Visit us", origin: Point(x: 10, y: 80))], nodes: [a, t])
        var scene = Corpus.scene([first, Corpus.page([])], nodes: [a: ExportNodeInfo(alt: "Next", pageLink: 2)], info: Self.english)
        scene.textLinks = [t: [ExportTextLink(url: "https://example.com", rects: [Rect(x: 10, y: 66, width: 60, height: 18)])]]
        let result = try PDFExporter().data(scene: scene, options: PDFOptions())
        let tree = try #require(ReadTagTree(result.data))
        #expect(tree.section(0).map(\.type) == ["Figure", "Link", "P", "Link"], "\(tree.section(0).map(\.type))")
        let raw = PDFTests.text(of: result.data)
        #expect(raw.contains("/Contents (Go to page)") && raw.contains("/Contents (https://example.com)"))
    }

    @Test func formsLigaturesAndBlankNames() throws {
        // A soft-masked group is a form too.
        guard case .gradient(let gradient) = Corpus.gradient(.linear), let flat = FlatGradient(gradient, bounds: Rect(x: 0, y: 0, width: 10, height: 10)) else {
            Issue.record("no gradient")
            return
        }
        let masked = FlatNode.group(FlatGroup(children: [], softMask: FlatSoftMask(gradient: flat, frame: .identity, bounds: Rect(x: 0, y: 0, width: 10, height: 10))))
        #expect(PDFStreamWriter.isForm(masked) && !PDFStreamWriter.isForm(.group(FlatGroup(children: []))))
        #expect(!PDFStreamWriter.isForm(.image(FlatImage(image: Corpus.image(), rect: Rect(x: 0, y: 0, width: 1, height: 1)))))
        #expect(PDFStreamWriter.characters(of: .image(FlatImage(image: Corpus.image(), rect: Rect(x: 0, y: 0, width: 1, height: 1)))) == nil)
        // A run whose glyphs do not map one to one onto its characters (a ligature) reads as them.
        let run = Corpus.run("office", font: "Times-Roman", size: 20, origin: Point(x: 10, y: 40))
        var text = FlatText(text: "office", run: run, color: .black, node: Corpus.node(80))
        if run.glyphs.count == 6 { text.text = "officé" + "\u{301}" }
        let page = FlatPage(bounds: Rect(x: 0, y: 0, width: 200, height: 100), nodes: [.text(text)])
        let scene = Corpus.scene([Corpus.page([])], info: Self.english)
        let written = PDFWriter().write([page], scene: scene)
        let tree = try #require(ReadTagTree(written.data))
        #expect(tree.section(0).first?.children.first?.actualText == text.text)
        // An undescribed object with a blank name is "an unnamed object".
        let blank = try Self.export([Corpus.page([Self.square], nodes: [Corpus.node(81)])], nodes: [Corpus.node(81): ExportNodeInfo(name: "")])
        #expect(blank.notes.contains { $0.contains("1 object has no alt text (an unnamed object)") })
    }

    @Test(.enabled(if: VeraPDF.isAvailable))
    func veraPDFValidatesTheClaimedFiles() throws {
        let (page, info) = Self.fixture()
        var second = Corpus.page([Corpus.text("Second page", origin: Point(x: 10, y: 60)), Self.square], nodes: [Corpus.node(60), Corpus.node(61)])
        second.readingOrder = [Corpus.node(61)]
        var nodes = info
        nodes[Corpus.node(61)] = ExportNodeInfo(alt: "Another square")
        let result = try Self.export([page, second], nodes: nodes)
        #expect(result.notes.contains("tagged PDF conforming to PDF/UA-1"))
        let validation = try VeraPDF.validate(result.data)
        #expect(validation.passed, "\(validation.output)")
    }
}
