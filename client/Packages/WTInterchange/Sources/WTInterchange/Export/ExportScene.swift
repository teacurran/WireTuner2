// What an exporter reads (docs/_includes/io/exporting.adoc, "Merge semantics"): an immutable copy
// of the document taken at export start.  Exporters need no `WTModel`: the artwork is WTRender's
// resolved display list per page, and the document facts the formats carry beside the artwork --
// object names (SVG ids), alt text and *Decorative* (SVG and PDF accessibility, IO-031/IO-032),
// attached URLs (links), placed images' pixels and Document Info -- travel alongside it, keyed by
// the display list's `NodeID`s.  `WTModel` fills one of these on the main actor (IO-014's
// `SceneSnapshot`); tests build them directly.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender

/// The document facts an exporter may write about one node.
public struct ExportNodeInfo: Hashable, Sendable {
    /// The Object panel name (`CommonProps.name`); SVG ids come from it.
    public var name: String?
    /// The accessible description (`accessibleDescription`: the alt text, or a text node's text).
    public var alt: String?
    /// Skipped by assistive technology (`CommonProps.decorative`).
    public var decorative: Bool
    /// The attached URL (`CommonProps.url`), written as a link.
    public var url: String?
    /// The node is a layer: SVG writes its group with the layer name, PDF may write a layer.
    public var isLayer: Bool
    /// The Object panel note (`CommonProps.note`): a PDF comment under *Notes as comments*.
    public var note: String?

    public init(name: String? = nil, alt: String? = nil, decorative: Bool = false, url: String? = nil, isLayer: Bool = false, note: String? = nil) {
        self.name = name
        self.alt = alt
        self.decorative = decorative
        self.url = url
        self.isLayer = isLayer
        self.note = note
    }
}

/// A placed image's pixels, resolved from its blob (`ImageItem.assetID`).
public struct ExportAsset: @unchecked Sendable {
    /// The decoded image.
    public var image: CGImage
    /// The original file's bytes when it is a JPEG: written as-is (SVG data URL, PDF `DCTDecode`)
    /// instead of re-encoding, when no resampling is needed.
    public var jpegData: Data?

    public init(image: CGImage, jpegData: Data? = nil) {
        self.image = image
        self.jpegData = jpegData
    }
}

/// A placed EPS file's PostScript, written verbatim into EPS exports (import-formats.adoc,
/// "EPS"; export-vector.adoc): the file's bytes -- a DOS EPS binary header is fine, only its
/// PostScript section is written -- and its bounding box, which the export maps onto the
/// placed file's bounds.
public struct ExportPostScript: Hashable, Sendable {
    /// The file as placed (`placed_file` blob).
    public var data: Data
    /// `%%HiResBoundingBox` (or `%%BoundingBox`) in PostScript points, y up.
    public var boundingBox: Rect
    /// The placed bounds in the node's local space (`PlacedFile.effectiveBounds`) and the
    /// node's transform (local → pasteboard).
    public var bounds: Rect
    public var transform: AffineTransform

    public init(data: Data, boundingBox: Rect, bounds: Rect, transform: AffineTransform = .identity) {
        self.data = data
        self.boundingBox = boundingBox
        self.bounds = bounds
        self.transform = transform
    }
}

/// Document Info (file-info.adoc) as far as exporters write it.
public struct ExportDocumentInfo: Hashable, Sendable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var description: String?
    public var keywords: [String]
    /// BCP 47, e.g. `en-US`.
    public var language: String?
    public var creator: String
    /// The whole of Document Info (IO-012).  When set, PDF, SVG, PSD and the ImageIO bitmap
    /// formats write it through `MetadataWriter` -- every IPTC Core field, the IIM record where
    /// the format has one -- instead of the fields above.
    public var metadata: DocumentMetadata?

    public init(title: String? = nil, author: String? = nil, subject: String? = nil, description: String? = nil, keywords: [String] = [], language: String? = nil, creator: String = "WireTuner", metadata: DocumentMetadata? = nil) {
        self.metadata = metadata
        self.title = title
        self.author = author
        self.subject = subject
        self.description = description
        self.keywords = keywords
        self.language = language
        self.creator = creator
    }

    /// Whether any field a format would write is set.
    public var isEmpty: Bool {
        title == nil && author == nil && subject == nil && description == nil && keywords.isEmpty && language == nil && metadata == nil
    }

    /// The writer for `metadata`, with the empty-title fallback to `documentName`.
    func metadataWriter(documentName: String) -> MetadataWriter? {
        metadata.map { MetadataWriter(metadata: $0, documentName: documentName, creatorTool: creator) }
    }

    /// The language written: Document Info's when set, else `language`.
    var effectiveLanguage: String? {
        metadata.flatMap { $0.normalized.language.isEmpty ? nil : $0.normalized.language } ?? language
    }
}

/// One page (or output area, or selection) of an export.
public struct ExportPage: Sendable {
    /// The page's name from the Document panel, if it has one (`{pagename}`, PDF bookmarks).
    public var name: String?
    /// What is exported, in pasteboard coordinates: the page, the output area or the
    /// selection's bounds.  Everything outside is cropped.
    public var bounds: Rect
    /// The artwork, back to front.
    public var displayList: DisplayList
    /// The page color, painted by *Page background* (SVG) and *Page color* (bitmaps).
    public var background: Color?
    /// Node ids of nested items (inside groups), by index path (top-level index, then child
    /// indices).  Top-level items take theirs from `displayList.nodeIDs`.
    public var nestedNodeIDs: [[Int]: NodeID]
    /// The bleed on every side, in points, when the page carries one (PDF bleed box).
    public var bleed: Double

    public init(name: String? = nil, bounds: Rect, displayList: DisplayList, background: Color? = nil, nestedNodeIDs: [[Int]: NodeID] = [:], bleed: Double = 0) {
        self.name = name
        self.bounds = bounds
        self.displayList = displayList
        self.background = background
        self.nestedNodeIDs = nestedNodeIDs
        self.bleed = bleed
    }

    /// The node the item at `indexPath` was built from, if any.
    public func nodeID(at indexPath: [Int]) -> NodeID? {
        if indexPath.count == 1, let index = indexPath.first, index < displayList.nodeIDs.count {
            return displayList.nodeIDs[index]
        }
        return nestedNodeIDs[indexPath]
    }
}

/// An immutable snapshot of what is being exported.
public struct ExportScene: Sendable {
    /// The file's base name, `{name}` in file-name patterns.
    public var name: String
    public var pages: [ExportPage]
    public var info: ExportDocumentInfo
    /// Facts about nodes, keyed by the display list's node ids.
    public var nodes: [NodeID: ExportNodeInfo]
    /// Placed images by asset id.  An image whose blob is not on this Mac is absent and exports
    /// as its placeholder, as it draws on screen.
    public var assets: [String: ExportAsset]
    /// The document's raster effects resolution (ppi): what the flattener renders regions it
    /// cannot express at unless the format's options override it.
    public var rasterResolution: Double
    /// The text blocks of the exported pages with their stories, for RTF and plain-text export
    /// (IO-030; export-text.adoc).  Empty when the snapshot was taken for artwork formats.
    public var text: [ExportTextBlock]
    /// The document's animation (WEB-019, WEB-020): nil when the document is not animated or
    /// the snapshot was taken for still formats.
    public var animation: ExportAnimation?
    /// The document as a `.wiretuner` package (`PackageWriter.data`), for *Embed {product}
    /// document* (IO-028); nil when the option is off or the snapshot was taken without it.
    public var package: Data?
    /// The PostScript of placed EPS files by node, for EPS export's pass-through (IO-018).
    public var placedPostScript: [NodeID: ExportPostScript]

    public init(name: String = "Untitled", pages: [ExportPage], info: ExportDocumentInfo = ExportDocumentInfo(), nodes: [NodeID: ExportNodeInfo] = [:], assets: [String: ExportAsset] = [:], rasterResolution: Double = 300, text: [ExportTextBlock] = [], animation: ExportAnimation? = nil, package: Data? = nil, placedPostScript: [NodeID: ExportPostScript] = [:]) {
        self.name = name
        self.pages = pages
        self.info = info
        self.nodes = nodes
        self.assets = assets
        self.rasterResolution = rasterResolution
        self.text = text
        self.animation = animation
        self.package = package
        self.placedPostScript = placedPostScript
    }

    /// The facts about `node`, if any are recorded.
    public func info(for node: NodeID?) -> ExportNodeInfo? {
        node.flatMap { nodes[$0] }
    }
}
