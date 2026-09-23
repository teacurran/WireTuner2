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

    public init(name: String? = nil, alt: String? = nil, decorative: Bool = false, url: String? = nil, isLayer: Bool = false) {
        self.name = name
        self.alt = alt
        self.decorative = decorative
        self.url = url
        self.isLayer = isLayer
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

    public init(title: String? = nil, author: String? = nil, subject: String? = nil, description: String? = nil, keywords: [String] = [], language: String? = nil, creator: String = "WireTuner") {
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
        title == nil && author == nil && subject == nil && description == nil && keywords.isEmpty && language == nil
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

    public init(name: String = "Untitled", pages: [ExportPage], info: ExportDocumentInfo = ExportDocumentInfo(), nodes: [NodeID: ExportNodeInfo] = [:], assets: [String: ExportAsset] = [:], rasterResolution: Double = 300) {
        self.name = name
        self.pages = pages
        self.info = info
        self.nodes = nodes
        self.assets = assets
        self.rasterResolution = rasterResolution
    }

    /// The facts about `node`, if any are recorded.
    public func info(for node: NodeID?) -> ExportNodeInfo? {
        node.flatMap { nodes[$0] }
    }
}
