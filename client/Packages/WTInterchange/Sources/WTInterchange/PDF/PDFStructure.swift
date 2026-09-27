// Tagged PDF and PDF/UA-1 (export-pdf.adoc, "Client", *Tagged PDF*; IO-032).  With `PDFOptions.tagged`
// the writer marks every piece of page content as it writes it -- the same node walk that writes the
// content streams, so marked-content ids and content never diverge -- and builds the structure tree
// beside it: one `/Document` with a `/Sect` per page whose kids follow the page's reading order
// (`ExportPage.readingOrder`, OBJ-041).  An object with alt text is a `/Figure` carrying it (a group
// with alt text is one figure around all its content), a text object a `/P` with a `/Span` per run
// (`/ActualText` where the glyphs would not read back as the characters, or the run is outlined), a
// decorative object an `/Artifact` sequence, a group without alt text is read as its members in its
// place, and an object with neither alt text nor text a `/Figure` without `/Alt` that keeps the file
// from claiming PDF/UA-1.  Links become `/Link` elements and notes and comments `/Annot` elements
// holding their annotation (`/OBJR`), each right after the element of the object it belongs to.  A
// transparency group written as a form XObject gets its own marked-content ids (`/MCR` with `/Stm`)
// when its members are tagged one by one.  The parent tree maps every content stream's ids, and every
// annotation, back to its element.
//
// The file claims PDF/UA-1 (`pdfuaid:part` in XMP, `/DisplayDocTitle`) only when the document has a
// language, no text is outlined and every object read has a description; otherwise the tags stay and
// the summary says why.

import Foundation
import WTGeometry
import WTRender

/// A structure element being built.
final class PDFStructElement {
    enum Kid {
        /// A marked-content id in the element's page's own content stream.
        case mcid(Int)
        /// A marked-content id in form XObject `stream`.
        case mcr(Int, stream: Int)
        case element(PDFStructElement)
        /// An annotation (`/OBJR`).
        case annotation(Int)
    }

    /// The structure type (`/S`).
    let type: String
    let object: Int
    /// The page object the content is on.
    let page: Int?
    var alt: String?
    var actualText: String?
    /// The layout bounding box, in the page's default space.
    var bbox: Rect?
    var kids: [Kid] = []
    var parent = 0

    init(type: String, object: Int, page: Int?) {
        self.type = type
        self.object = object
        self.page = page
    }

    func append(_ child: PDFStructElement) {
        child.parent = object
        kids.append(.element(child))
    }

    /// Every element below this one, depth first.
    var descendants: [PDFStructElement] {
        kids.flatMap { kid -> [PDFStructElement] in
            if case .element(let child) = kid { return [child] + child.descendants }
            return []
        }
    }
}

/// The marked-content ids of one content stream: a page's, or a transparency group's form.
final class PDFStreamTags {
    /// The stream's `/StructParents` key.
    let key: Int
    /// The form XObject; nil for a page's own content stream.
    let stream: Int?
    /// The element owning each marked-content id, by id.
    private(set) var owners: [PDFStructElement] = []

    init(key: Int, stream: Int?) {
        self.key = key
        self.stream = stream
    }

    /// The next id, owned by `element`.
    func mark(_ element: PDFStructElement) -> Int {
        let mcid = owners.count
        owners.append(element)
        element.kids.append(stream.map { .mcr(mcid, stream: $0) } ?? .mcid(mcid))
        return mcid
    }
}

/// The elements of one page, before they are put in reading order.
final class PDFPageStructure {
    let pageObject: Int
    let readingOrder: [NodeID]
    /// Each element with the top-level object it belongs to, in the order written.
    var entries: [(top: NodeID?, element: PDFStructElement)] = []

    init(pageObject: Int, readingOrder: [NodeID]) {
        self.pageObject = pageObject
        self.readingOrder = readingOrder
    }

    /// The elements in reading order: the listed objects' first, in the listed order, then the
    /// others in stacking order; an object's own elements keep the order they were written in.
    func ordered() -> [PDFStructElement] {
        var rank: [NodeID: Int] = [:]
        for (index, node) in readingOrder.enumerated() where rank[node] == nil {
            rank[node] = index
        }
        // Objects not listed follow in the order first written (stacking order).
        for top in entries.compactMap(\.top) where rank[top] == nil {
            rank[top] = readingOrder.count + rank.count
        }
        return entries.enumerated().sorted { a, b in
            let ra = a.element.top.flatMap { rank[$0] } ?? Int.max, rb = b.element.top.flatMap { rank[$0] } ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element.element)
    }
}

/// The structure of one file being written.
final class PDFStructure {
    let objects: PDFObjects
    private(set) var pages: [PDFPageStructure] = []
    private var streams: [PDFStreamTags] = []
    private var annotations: [(key: Int, element: PDFStructElement)] = []
    private var nextKey = 0
    /// Names of the objects read without a description, in the order met.
    private(set) var undescribed: [String] = []
    /// Some text was written as outlines.
    var outlinedText = false

    init(objects: PDFObjects) {
        self.objects = objects
    }

    func element(_ type: String, page: Int?) -> PDFStructElement {
        PDFStructElement(type: type, object: objects.reserve(), page: page)
    }

    func page(_ pageObject: Int, readingOrder: [NodeID]) -> PDFPageStructure {
        let page = PDFPageStructure(pageObject: pageObject, readingOrder: readingOrder)
        pages.append(page)
        return page
    }

    /// The ids of a new content stream (`stream` a form XObject, nil for a page).
    func streamTags(stream: Int?) -> PDFStreamTags {
        let tags = PDFStreamTags(key: nextKey, stream: stream)
        nextKey += 1
        streams.append(tags)
        return tags
    }

    /// Records annotation `object` as a kid of `element`; returns its `/StructParent` key.
    func annotation(_ object: Int, element: PDFStructElement) -> Int {
        element.kids.append(.annotation(object))
        annotations.append((nextKey, element))
        nextKey += 1
        return nextKey - 1
    }

    /// An object read without a description.
    func undescribed(_ name: String?) {
        undescribed.append(name.flatMap { $0.isEmpty ? nil : $0 } ?? "an unnamed object")
    }

    /// Why the file cannot claim PDF/UA-1; empty when it can.
    func reasons(language: String?, options: PDFOptions, outlinedFonts: Set<String>) -> [String] {
        var reasons: [String] = []
        if language == nil {
            reasons.append("no document language is set in Document Info")
        }
        if options.fonts == .outlines {
            reasons.append("text is converted to outlines")
        } else if !outlinedFonts.isEmpty || outlinedText {
            reasons.append("some text is written as outlines because its font cannot be embedded")
        }
        if !undescribed.isEmpty {
            let names = undescribed.prefix(5).joined(separator: ", ")
            let more = undescribed.count > 5 ? " and \(undescribed.count - 5) more" : ""
            reasons.append("\(undescribed.count) object\(undescribed.count == 1 ? " has" : "s have") no alt text (\(names)\(more))")
        }
        return reasons
    }

    /// Writes the tree and returns the `/StructTreeRoot` object.
    func finish() -> Int {
        let root = objects.reserve()
        let document = element("Document", page: nil)
        document.parent = root
        for page in pages {
            let sect = element("Sect", page: page.pageObject)
            document.append(sect)
            for child in page.ordered() {
                sect.append(child)
            }
        }
        for element in [document] + document.descendants {
            objects.set(element.object, value(of: element))
        }
        var nums: [(Int, PDFValue)] = streams.map { ($0.key, .array($0.owners.map { .reference($0.object) })) }
        nums += annotations.map { ($0.key, .reference($0.element.object)) }
        nums.sort { $0.0 < $1.0 }
        objects.set(root, .dictionary([
            ("Type", .name("StructTreeRoot")),
            ("K", .reference(document.object)),
            ("ParentTree", .dictionary([("Nums", .array(nums.flatMap { [PDFValue.int($0.0), $0.1] }))])),
            ("ParentTreeNextKey", .int(nextKey)),
        ]))
        return root
    }

    func value(of element: PDFStructElement) -> PDFValue {
        var entries: [(String, PDFValue)] = [("Type", .name("StructElem")), ("S", .name(element.type)), ("P", .reference(element.parent))]
        if let page = element.page {
            entries.append(("Pg", .reference(page)))
        }
        let kids = element.kids.map { kid -> PDFValue in
            switch kid {
            case .mcid(let mcid):
                return .int(mcid)
            case .mcr(let mcid, let stream):
                var mcr: [(String, PDFValue)] = [("Type", .name("MCR"))]
                if let page = element.page { mcr.append(("Pg", .reference(page))) }
                return .dictionary(mcr + [("MCID", .int(mcid)), ("Stm", .reference(stream))])
            case .element(let child):
                return .reference(child.object)
            case .annotation(let object):
                var objr: [(String, PDFValue)] = [("Type", .name("OBJR"))]
                if let page = element.page { objr.append(("Pg", .reference(page))) }
                return .dictionary(objr + [("Obj", .reference(object))])
            }
        }
        if !kids.isEmpty {
            entries.append(("K", kids.count == 1 ? kids[0] : .array(kids)))
        }
        if let alt = element.alt {
            entries.append(("Alt", .string(alt)))
        }
        if let actualText = element.actualText {
            entries.append(("ActualText", .string(actualText)))
        }
        if let box = element.bbox {
            entries.append(("A", .dictionary([("O", .name("Layout")), ("BBox", .rect(box.minX, box.minY, box.maxX, box.maxY))])))
        }
        return .dictionary(entries)
    }
}

/// How a node is tagged when met outside any tagged sequence.
enum PDFTagRole: Equatable {
    /// Not tagged itself: its members are (a layer, a group without alt text, an anonymous group).
    case container
    case artifact
    /// A figure with its description (nil: undescribed).
    case figure(String?)
    /// A text object: a paragraph of spans.
    case text
}

extension PDFStreamWriter {
    /// The role of `node` at the untagged level.
    func tagRole(_ node: FlatNode, info: ExportNodeInfo?) -> PDFTagRole {
        guard node.node != nil else {
            if case .group = node { return .container }
            return .artifact
        }
        if info?.isLayer == true { return .container }
        if info?.decorative == true { return .artifact }
        if let alt = SVGBuild.description(info?.alt) { return .figure(alt) }
        if case .group(let group) = node, group.children.contains(where: { $0.node != nil }) { return .container }
        return Self.characters(of: node) == nil ? .figure(nil) : .text
    }

    /// The characters of the text runs (and outlined runs) below `node`, nil when it holds none.
    static func characters(of node: FlatNode) -> String? {
        switch node {
        case .text(let text):
            return text.text
        case .path(let path):
            return path.readAs
        case .image:
            return nil
        case .group(let group):
            let runs = group.children.compactMap(characters)
            return runs.isEmpty ? nil : runs.joined(separator: " ")
        }
    }

    /// Whether a group is written as a form XObject (a transparency group).
    static func isForm(_ node: FlatNode) -> Bool {
        if case .group(let group) = node { return group.opacity < 1 || group.softMask != nil }
        return false
    }

    /// Writes `node`, tagging it as the current level asks.
    func writeTagged(_ node: FlatNode, info: ExportNodeInfo?, tags: PDFStreamTags, page: PDFPageStructure) {
        switch tagLevel {
        case .inside:
            writeContent(node)
        case .paragraph(let paragraph):
            writeSpan(node, in: paragraph, tags: tags)
        case .none:
            let structure = build.structure!
            switch tagRole(node, info: info) {
            case .container:
                writeContent(node)
            case .artifact:
                artifact { writeContent(node) }
            case .figure(let alt):
                let figure = structure.element("Figure", page: page.pageObject)
                figure.alt = alt
                figure.bbox = node.bounds?.applying(patternBase)
                if alt == nil { structure.undescribed(info?.name) }
                page.entries.append((currentTop, figure))
                sequence("Figure", figure, tags: tags) { writeContent(node) }
            case .text:
                let paragraph = structure.element("P", page: page.pageObject)
                page.entries.append((currentTop, paragraph))
                if Self.isForm(node) {
                    paragraph.actualText = Self.characters(of: node)
                    sequence("P", paragraph, tags: tags) { writeContent(node) }
                } else {
                    tagLevel = .paragraph(paragraph)
                    writeSpan(node, in: paragraph, tags: tags)
                    tagLevel = .none
                }
            }
        }
    }

    /// A node inside a text object: a run is a span; a transparency group one span for all its
    /// runs; anything else an artifact.
    func writeSpan(_ node: FlatNode, in paragraph: PDFStructElement, tags: PDFStreamTags) {
        let structure = build.structure!
        func span(actualText: String?) {
            let span = structure.element("Span", page: paragraph.page)
            span.actualText = actualText
            paragraph.append(span)
            sequence("Span", span, tags: tags) { writeContent(node) }
        }
        switch node {
        case .text(let text):
            // Glyphs that do not map one to one onto characters (ligatures), or text the writer
            // outlines, read as the characters.
            let lossy = text.run.glyphs.count != text.text.unicodeScalars.count || options.fonts == .outlines || build.fonts.font(for: text.run.font) == nil
            if lossy && build.fonts.font(for: text.run.font) == nil { structure.outlinedText = true }
            span(actualText: lossy ? text.text : nil)
        case .path(let path) where path.readAs != nil:
            structure.outlinedText = true
            span(actualText: path.readAs)
        case .group where Self.isForm(node):
            span(actualText: Self.characters(of: node))
        case .group:
            writeContent(node)
        default:
            artifact { writeContent(node) }
        }
    }

    /// `body` inside a marked-content sequence owned by `element`.
    func sequence(_ tag: String, _ element: PDFStructElement, tags: PDFStreamTags, _ body: () -> Void) {
        let mcid = tags.mark(element)
        content.op("/\(tag) <</MCID \(mcid)>> BDC")
        let level = tagLevel
        tagLevel = .inside
        body()
        tagLevel = level
        content.op("EMC")
    }

    /// `body` as an artifact sequence.
    func artifact(_ body: () -> Void) {
        content.op("/Artifact BMC")
        let level = tagLevel
        tagLevel = .inside
        body()
        tagLevel = level
        content.op("EMC")
    }
}

/// Where a stream writer is in the tagging.
enum PDFTagLevel {
    /// Outside any tagged sequence: the next object met is tagged.
    case none
    /// Inside a text object's paragraph: each run is a span.
    case paragraph(PDFStructElement)
    /// Inside a tagged or artifact sequence: nothing more is marked.
    case inside
}

extension PDFDocumentBuild {
    /// Tags annotation `object` (`entries` its dictionary) with a `type` element (`Link`,
    /// `Annot`) after the elements of `top` on the current page, adding its `/StructParent`.
    func tagAnnotation(_ object: Int, type: String, alt: String?, top: NodeID?, entries: inout [(String, PDFValue)]) {
        guard let structure, let page = currentPage else { return }
        let element = structure.element(type, page: page.pageObject)
        element.alt = alt
        page.entries.append((top, element))
        entries.append(("StructParent", .int(structure.annotation(object, element: element))))
    }
}
