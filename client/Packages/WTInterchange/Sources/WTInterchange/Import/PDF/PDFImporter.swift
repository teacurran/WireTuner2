// The PDF importer (import-formats.adoc, "PDF" and "Client"; IMG-009): each selected page's
// content becomes native paths, text, images and clipping groups; optional content becomes layer
// groups; notes and links go to the *Notes* and *URLs* layers; several pages are grouped per page
// and set in a row with the *Keep both offset* between them.  A PDF Illustrator wrote (its piece
// info, or Illustrator's layer marks) opens and imports as an Illustrator file does (D-085).

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

public struct PDFImporter: Importer {
    /// The grey level shadings the importer cannot represent are filled with: 10% black for
    /// PDF, 50% for Illustrator's gradient meshes.
    public var meshBlack: Double
    /// Illustrator's own layer marks and hidden-layer artwork are read as layers, and a PDF
    /// Illustrator wrote gets an Illustrator file's layer checks and artboard names (D-085).  Off
    /// only for an Illustrator file whose layers cannot be matched to its drawing.
    public var illustratorLayers: Bool

    public init(meshBlack: Double = 0.1, illustratorLayers: Bool = true) {
        self.meshBlack = meshBlack
        self.illustratorLayers = illustratorLayers
    }

    /// A session for converting `document`.
    func session(_ document: CGPDFDocument, name: String, options: PDFImportOptions) -> PDFImportSession {
        PDFImportSession(name: name, text: options.text, meshBlack: meshBlack, illustratorLayers: illustratorLayers, hiddenGroups: PDFImporter.hiddenGroups(document))
    }

    /// The optional content groups the default configuration turns off: its `/OFF` groups, or
    /// with `/BaseState /OFF` every group not in its `/ON`.
    static func hiddenGroups(_ document: CGPDFDocument) -> Set<UnsafeRawPointer> {
        guard let catalog = document.catalog, let properties = PDFImportDict(ref: catalog).dict("OCProperties"), let configuration = properties.dict("D") else {
            return []
        }
        func ids(_ array: PDFImportArray?) -> Set<UnsafeRawPointer> { Set(array?.values.compactMap(\.dict).map(\.id) ?? []) }
        if configuration.name("BaseState") == "OFF" {
            return ids(properties.array("OCGs")).subtracting(ids(configuration.array("ON")))
        }
        return ids(configuration.array("OFF"))
    }

    public var formats: [ImportFormat] { [.pdf] }

    public func optionsSchema(for format: ImportFormat) -> ImportOptionsSchema { PDFImportOptions.schema }

    /// The document of `data`, unlocked, or a refusal naming `name`.
    static func document(_ data: Data, name: String) throws -> CGPDFDocument {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), document.numberOfPages > 0 else {
            throw ImportError.unreadable(name: name, reason: "it is damaged or is not a PDF.")
        }
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") {
            throw ImportError.unreadable(name: name, reason: "it is protected by a password.")
        }
        return document
    }

    /// The page's crop box and the transform from its default user space to y-down page
    /// space (the displayed page, `/Rotate` applied, top-left at the origin).
    static func pageSpace(_ page: CGPDFPage) -> (size: Rect, transform: AffineTransform) {
        let box = page.getBoxRect(.cropBox).standardized
        let x0 = Double(box.minX), y0 = Double(box.minY), x1 = Double(box.maxX), y1 = Double(box.maxY)
        let w = x1 - x0
        let h = y1 - y0
        switch ((Int(page.rotationAngle) % 360) + 360) % 360 {
        case 90:
            return (Rect(x: 0, y: 0, width: h, height: w), AffineTransform(a: 0, b: 1, c: 1, d: 0, tx: -y0, ty: -x0))
        case 180:
            return (Rect(x: 0, y: 0, width: w, height: h), AffineTransform(a: -1, b: 0, c: 0, d: 1, tx: x1, ty: -y0))
        case 270:
            return (Rect(x: 0, y: 0, width: h, height: w), AffineTransform(a: 0, b: -1, c: -1, d: 0, tx: y1, ty: x1))
        default:
            return (Rect(x: 0, y: 0, width: w, height: h), AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -x0, ty: y1))
        }
    }

    public func probe(_ data: Data, name: String, format: ImportFormat) throws -> ImportDescriptor {
        let document = try PDFImporter.document(data, name: name)
        let page = document.page(at: 1)!
        let size = PDFImporter.pageSpace(page).size
        return ImportDescriptor(format: format, naturalSize: size, pageCount: document.numberOfPages, preview: PDFImporter.preview(page, size: size))
    }

    /// Page `page` drawn at most 256 points on its long side.
    static func preview(_ page: CGPDFPage, size: Rect) -> CGImage? {
        let scale = 256 / max(size.width, size.height, 1)
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    public func convert(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedScene {
        let typed = try PDFImportOptions(options, name: name)
        let document = try PDFImporter.document(data, name: name)
        if illustratorLayers, IllustratorPrivateData.isIllustrator(document) {
            return try IllustratorImporter.scene(document, name: name, options: typed, context: context, importer: self)
        }
        return try convert(document, name: name, options: typed, context: context)
    }

    /// `document` converted with `options`.
    func convert(_ document: CGPDFDocument, name: String, options: PDFImportOptions, context: ImportContext) throws -> ImportedScene {
        let pages = try options.pages.resolve(pageCount: document.numberOfPages, name: name)
        guard !pages.isEmpty else {
            throw ImportError.empty(name: name)
        }
        let session = session(document, name: name, options: options)
        var nodes: [ImportedNode] = []
        var notes: [ImportedNode] = []
        var links: [ImportedNode] = []
        var x = 0.0
        var height = 0.0
        for number in pages {
            let offset = AffineTransform.translation(x: x, y: 0)
            let page = convertPage(document.page(at: number)!, session: session, options: options, placement: offset)
            let content = PDFImporter.placeable(page.content, session: session)
            if pages.count > 1 {
                nodes.append(.group(ImportedGroup(children: content, transform: offset, name: "Page \(number)")))
            } else {
                nodes += content
            }
            notes += page.notes
            links += page.links
            x += page.size.width + context.keepBothOffset
            height = max(height, page.size.height)
        }
        let bounds = Rect(x: 0, y: 0, width: x - context.keepBothOffset, height: height)
        return ImportedScene(kind: .vector, name: name, bounds: bounds, nodes: nodes, layers: PDFImporter.layers(notes: notes, links: links), notes: session.notes)
    }

    /// `document` opened as a document (IO-040): one page per selected page at its crop box's
    /// size, its content in page space with optional content as layer groups, its notes and links
    /// on the *Notes* and *URLs* layers; a PDF with Illustrator's piece info or layer marks as an
    /// Illustrator file opens (D-085).
    func document(_ document: CGPDFDocument, name: String, format: ImportFormat, options: PDFImportOptions) throws -> ImportedDocument {
        if illustratorLayers {
            return try IllustratorImporter.document(document, name: name, format: format, options: options, importer: self)
        }
        return try pages(document, name: name, format: format, options: options).document
    }

    /// `document` opened as a document, with each page's layer runs and loose objects and the
    /// kinds of layer found, for the Illustrator importer's certainty checks (D-085).
    func pages(_ document: CGPDFDocument, name: String, format: ImportFormat, options: PDFImportOptions)
        throws -> (document: ImportedDocument, pages: [PDFConvertedPage], sources: Set<PDFImportLayer.Source>) {
        let numbers = try options.pages.resolve(pageCount: document.numberOfPages, name: name)
        guard !numbers.isEmpty else {
            throw ImportError.empty(name: name)
        }
        let session = session(document, name: name, options: options)
        let converted = numbers.map { number in
            var page = convertPage(document.page(at: number)!, session: session, options: options, placement: .identity)
            page.number = number
            return page
        }
        let pages = converted.map { page in
            ImportedPage(size: Size(width: page.size.width, height: page.size.height), nodes: page.content,
                         layers: PDFImporter.layers(notes: page.notes, links: page.links))
        }
        return (ImportedDocument(format: format, name: name, pages: pages, notes: session.notes), converted, session.layerSources)
    }

    /// Page content for an import (a scene placed on the current layer): layers with nothing on
    /// them left out, and hidden layers left out with a note, as Illustrator's own import does.
    static func placeable(_ nodes: [ImportedNode], session: PDFImportSession) -> [ImportedNode] {
        nodes.compactMap { node in
            guard case .group(let group) = node, group.role == .layer else {
                return node
            }
            if !group.layerState.visible {
                if !group.children.isEmpty { session.note("The hidden layer “\(group.name ?? "")” was left out; open the file to keep it.") }
                return nil
            }
            return group.children.isEmpty ? nil : node
        }
    }

    public func document(_ data: Data, name: String, format: ImportFormat, options: ImportOptionValues, context: ImportContext) throws -> ImportedDocument {
        try document(try PDFImporter.document(data, name: name), name: name, format: format, options: try PDFImportOptions(options, name: name))
    }

    /// One page's content in its y-down page space, and its annotations with `placement` (the
    /// page's offset in a scene of several pages) applied.
    func convertPage(_ page: CGPDFPage, session: PDFImportSession, options: PDFImportOptions, placement: AffineTransform) -> PDFConvertedPage {
        let (size, base) = PDFImporter.pageSpace(page)
        let tree = PDFImportTree()
        let dict = PDFImportDict(ref: page.dictionary!)
        let interpreter = PDFImportInterpreter(session: session, tree: tree, resources: dict.dict("Resources"), ctm: base, pageBox: size)
        interpreter.run(PDFImporter.contents(dict))
        var content = tree.finish()
        if options.keepPageClip {
            content = PDFImporter.clipped(content, to: size)
        }
        let annotations = PDFImporter.annotations(dict, base: base.concatenating(placement), options: options)
        return PDFConvertedPage(size: size, content: content, notes: annotations.notes, links: annotations.links, layerRuns: tree.layerRuns, looseCount: tree.looseCount)
    }

    /// *Keep page clip*: the page's content in clipping groups the size of its crop box -- inside
    /// each top-level layer, so the layers stay layers, and around each run of other objects.
    static func clipped(_ nodes: [ImportedNode], to box: Rect) -> [ImportedNode] {
        var builder = ImportPathBuilder()
        builder.rect(box)
        let clip = ImportedPath(contours: builder.build())
        var result: [ImportedNode] = []
        var run: [ImportedNode] = []
        func flush() {
            if !run.isEmpty { result.append(.group(ImportedGroup(children: run, clip: clip))) }
            run = []
        }
        for node in nodes {
            if case .group(var layer) = node, layer.role == .layer {
                flush()
                if !layer.children.isEmpty { layer.children = [.group(ImportedGroup(children: layer.children, clip: clip))] }
                result.append(.group(layer))
            } else {
                run.append(node)
            }
        }
        flush()
        return result
    }

    /// One converted page: its crop box, content, notes and links, the layers of its top-level
    /// layer groups in order, how many top-level objects are outside every layer, and its page
    /// number.
    struct PDFConvertedPage {
        var size: Rect
        var content: [ImportedNode]
        var notes: [ImportedNode]
        var links: [ImportedNode]
        var layerRuns: [PDFImportLayer]
        var looseCount: Int
        var number = 1
    }

    /// The *Notes* and *URLs* layers, each when it has something.
    static func layers(notes: [ImportedNode], links: [ImportedNode]) -> [ImportedLayer] {
        var layers: [ImportedLayer] = []
        if !notes.isEmpty {
            layers.append(ImportedLayer(name: "Notes", nodes: notes))
        }
        if !links.isEmpty {
            layers.append(ImportedLayer(name: "URLs", nodes: links))
        }
        return layers
    }

    /// The page's content streams, concatenated.
    static func contents(_ page: PDFImportDict) -> Data {
        switch page["Contents"] {
        case .stream(let stream)?:
            return stream.data
        case .array(let array)?:
            var data = Data()
            for stream in array.values.compactMap(\.stream) {
                data.append(stream.data)
                data.append(10)
            }
            return data
        default:
            return Data()
        }
    }

    /// Notes (text and free-text annotations) and links (URI link annotations) of a page.
    static func annotations(_ page: PDFImportDict, base: AffineTransform, options: PDFImportOptions) -> (notes: [ImportedNode], links: [ImportedNode]) {
        var notes: [ImportedNode] = []
        var links: [ImportedNode] = []
        for annotation in page.array("Annots")?.values.compactMap(\.dict) ?? [] {
            guard let box = annotation.numbers("Rect"), box.count == 4 else {
                continue
            }
            let rect = Rect(minX: min(box[0], box[2]), minY: min(box[1], box[3]), maxX: max(box[0], box[2]), maxY: max(box[1], box[3])).applying(base)
            switch annotation.name("Subtype") {
            case "Link" where options.importLinks:
                guard let uri = annotation.dict("A")?.text("URI") else {
                    continue
                }
                var builder = ImportPathBuilder()
                builder.rect(rect)
                links.append(.path(ImportedPath(contours: builder.build(), name: uri, url: uri)))
            case "Text", "FreeText":
                guard options.importNotes, let contents = annotation.text("Contents"), !contents.isEmpty else {
                    continue
                }
                let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                let runs = lines.enumerated().map { index, line in
                    ImportedTextRun(text: String(line), fontName: "Helvetica", fontSize: 12, origin: Point(x: rect.minX, y: rect.minY + 12 + Double(index) * 14.4))
                }
                notes.append(.text(ImportedText(runs: runs, name: annotation.text("T"))))
            default:
                continue
            }
        }
        return (notes, links)
    }
}
