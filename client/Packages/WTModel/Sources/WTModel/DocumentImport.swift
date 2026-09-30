import Foundation
import WTCRDT
import WTGeometry
import WTInterchange
import WTProto
import WTRender
import struct WTGeometry.AffineTransform

// A foreign file opened as a new document (creating-opening.adoc, "Opening other file types";
// IO-040, D-082): WTInterchange's `ImportedDocument` written as a new document's first change,
// "Created from <file>" -- like a template, part of the document and not an undo step.  The file's
// pages (a PDF's pages, an Illustrator file's artboards) become pages at their own sizes, set in
// rows on the pasteboard; its layers become document layers in the file's order, bottom to top,
// with artwork outside any layer on "Foreground"; the *Notes* and *URLs* layers follow.  A file
// layer that is hidden, locked, non-printing or drawn as outlines in the file (an Illustrator
// layer, D-085) is created so: hidden, locked, a background layer, a keyline layer.  The
// document template (swatches, the Normal styles) is written too, so the new document is a
// WireTuner document like any other.  Blobs must be in the cache before it runs, as for an import.

/// What `CreateDocument(.imported(_))` writes: the opened file and how its images and placed
/// files are recorded.
public struct DocumentImport: Sendable {
    public var document: ImportedDocument
    /// The file's link record, for a document that is one placed file or image (a placed EPS, a
    /// placed SVG animation); vector artwork's images get none, as on import.
    public var link: ImportLink?
    /// An SVG animation's poster.
    public var poster: ImportedPoster?
    /// What the images' embedded profiles do.
    public var embeddedProfiles: EmbeddedProfilePolicy

    public init(_ document: ImportedDocument, link: ImportLink? = nil, poster: ImportedPoster? = nil, embeddedProfiles: EmbeddedProfilePolicy = .useEmbedded) {
        self.document = document
        self.link = link
        self.poster = poster
        self.embeddedProfiles = embeddedProfiles
    }

    /// The layer loose artwork (outside any of the file's layers) goes onto.
    public static let looseLayer = "Foreground"
    /// The gap between pages on the pasteboard: Add Pages' inch.
    public static let gap = AddPages.gap

    /// Whether the document is a single placed file or image, which keeps a link record to the file.
    var isSinglePlacement: Bool {
        guard document.pages.count == 1, document.pages[0].nodes.count == 1 else { return false }
        switch document.pages[0].nodes[0] {
        case .placed, .image: return true
        default: return false
        }
    }

    /// Each page's rect on the pasteboard: rows left to right with `gap` between pages, a new row
    /// when the next page would pass the pasteboard's edge, the whole block centred on the
    /// pasteboard; every side clamped to the largest page (222 in).
    public var pageRects: [Rect] {
        let side = DocumentCreation.pasteboardSide
        let sizes = document.pages.map { page in
            Size(width: min(max(page.size.width, 1), PageGeometry.maximumSide), height: min(max(page.size.height, 1), PageGeometry.maximumSide))
        }
        var rects: [Rect] = []
        var x = 0.0
        var y = 0.0
        var rowHeight = 0.0
        for size in sizes {
            if x > 0, x + size.width > side {
                x = 0
                y += rowHeight + Self.gap
                rowHeight = 0
            }
            rects.append(Rect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + Self.gap
            rowHeight = max(rowHeight, size.height)
        }
        let block = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        let dx = max((side - block.width) / 2, 0) - block.minX
        let dy = max((side - block.height) / 2, 0) - block.minY
        return rects.map { Rect(x: $0.minX + dx, y: $0.minY + dy, width: $0.width, height: $0.height) }
    }

    /// The document layers in order, bottom to top, with the nodes each receives in stacking
    /// order, already in pasteboard space (their pages' offsets applied, a file layer's own
    /// transform composed onto its children), and the settings of the file layer that first
    /// names each (`.normal` for *Foreground* and the named layers).
    public var layerContents: [(name: String, nodes: [ImportedNode], state: ImportedLayerState)] {
        var order: [String] = []
        var contents: [String: [ImportedNode]] = [:]
        var states: [String: ImportedLayerState] = [:]
        func add(_ node: ImportedNode, to name: String) {
            if contents[name] == nil {
                order.append(name)
                contents[name] = []
            }
            contents[name]!.append(node)
        }
        let rects = pageRects
        for (page, rect) in zip(document.pages, rects) {
            let offset = AffineTransform.translation(x: rect.minX, y: rect.minY)
            for node in page.nodes {
                if case .group(let group) = node, group.role == .layer {
                    let toPage = group.transform.concatenating(offset)
                    let name = group.name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.looseLayer
                    if states[name] == nil { states[name] = group.layerState }
                    if group.children.isEmpty, contents[name] == nil {
                        order.append(name)
                        contents[name] = []
                    }
                    for child in group.children { add(child.applying(toPage), to: name) }
                } else {
                    add(node.applying(offset), to: Self.looseLayer)
                }
            }
        }
        for (page, rect) in zip(document.pages, rects) {
            let offset = AffineTransform.translation(x: rect.minX, y: rect.minY)
            for layer in page.layers where !layer.nodes.isEmpty {
                for node in layer.nodes { add(node.applying(offset), to: layer.name) }
            }
        }
        return order.map { ($0, contents[$0]!, states[$0] ?? .normal) }
    }

    /// Writes the document: template, pages, layers and artwork.
    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try DocumentTemplate().execute(&builder, state: state)
        let rects = pageRects
        let pageKeys = try PathEditing.keys(between: nil, and: nil, count: rects.count)
        for (index, (rect, key)) in zip(rects, pageKeys).enumerated() {
            let page = document.pages[index]
            builder.append(Ops.create(parent: WellKnown.pages, position: key, props: PageFields.values {
                if let name = page.name, !name.isEmpty { $0.common.name = String(name.prefix(256)) }
                $0.origin = PageEditing.point(rect.origin)
                $0.geometry = Self.geometry(width: rect.width, height: rect.height).stored
            }))
        }
        var writer = ImportWriter(state: state, link: isSinglePlacement ? link : nil, poster: poster)
        writer.embeddedProfiles = embeddedProfiles
        let layers = layerContents
        let layerKeys = try PathEditing.keys(between: nil, and: nil, count: layers.count)
        for (layer, layerKey) in zip(layers, layerKeys) {
            var props = Wiretuner_Doc_V1_NodeProps()
            props.layer.common.name = String(layer.name.prefix(256))
            props.layer.visible = layer.state.visible
            props.layer.locked = layer.state.locked
            props.layer.printing = layer.state.printing
            props.layer.keyline = layer.state.outline
            let id = builder.append(Ops.create(parent: WellKnown.layers, position: layerKey, props: props))
            let keys = try PathEditing.keys(between: nil, and: nil, count: layer.nodes.count)
            for (node, key) in zip(layer.nodes, keys) {
                try writer.create(node, parent: id, position: key, builder: &builder)
            }
        }
    }

    /// A page geometry of `width` × `height`: a standard size's name when it is one (either
    /// orientation, within half a point), else Custom.
    public static func geometry(width: Double, height: Double) -> PageGeometry {
        for preset in PagePreset.standard {
            if abs(preset.width - width) < 0.5 && abs(preset.height - height) < 0.5 {
                return PageGeometry(preset: preset.name, width: width, height: height, orientation: .portrait)
            }
            if abs(preset.width - height) < 0.5 && abs(preset.height - width) < 0.5 {
                return PageGeometry(preset: preset.name, width: width, height: height, orientation: .landscape)
            }
        }
        return PageGeometry(width: width, height: height)
    }
}
