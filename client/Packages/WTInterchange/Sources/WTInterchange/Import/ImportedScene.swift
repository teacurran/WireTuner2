// What an importer produces (import-formats.adoc, "Client"; IMG-008): a neutral description of the
// converted artwork, independent of `WTModel`.  Coordinates are points, y down, with the imported
// page's (or view box's, or drawing's) top-left corner at the origin, exactly as the document's
// pasteboard; colours are WTRender's tagged `Color`; images and placed files carry their encoded
// bytes as content-addressed blobs.  `WTModel` turns an `ImportedScene` into `CreateNode` ops in
// one change labelled "Import <file>" -- the mapping it implements is written out on
// import-formats.adoc, "Client", *Imported scene to document*.

import CryptoKit
import Foundation
import UniformTypeIdentifiers
import WTGeometry
import WTRender
import struct WTRender.StrokeStyle

// MARK: - Blobs

/// An encoded file stored in the document (D-024): an image's pixels, a placed file, an embedded
/// image of a vector file.  Content-addressed by SHA-256, so two imports of the same bytes are one
/// blob and one upload.
public struct ImportedBlob: Hashable, Sendable {
    /// SHA-256 of `data`, 32 bytes (`PixelSource.blob_sha256`).
    public let sha256: Data
    /// The encoded bytes.
    public let data: Data
    /// The UTI of the encoding (`PixelSource.format`): `public.png`, `public.jpeg`…
    public let uti: String

    public init(data: Data, uti: String) {
        self.data = data
        self.uti = uti
        sha256 = ImportedBlob.hash(data)
    }

    /// The SHA-256 of `data`.
    public static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// The hash as 64 lower-case hex digits (the blob cache's and the package's file name).
    public var hex: String { ImportedBlob.hex(sha256) }

    /// `bytes` as lower-case hex.
    public static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The media type of the encoding (`image/png`), or `application/octet-stream`.
    public var mediaType: String {
        UTType(uti)?.preferredMIMEType ?? "application/octet-stream"
    }
}

// MARK: - Images

/// `ColorMode` of an image's pixel source.
public enum ImportedColorMode: String, Hashable, Sendable, CaseIterable {
    case bilevel
    case grayscale
    case indexed
    case rgb
    case cmyk

    /// The renderer's mode.
    public var imageMode: ImageMode {
        switch self {
        case .bilevel: return .bilevel
        case .grayscale: return .grayscale
        case .indexed: return .indexed
        case .rgb: return .rgb
        case .cmyk: return .cmyk
        }
    }
}

/// `PixelSource`: the facts of an encoded image the renderer needs before its blob is available.
public struct ImportedPixels: Hashable, Sendable {
    public var blob: ImportedBlob
    public var width: Int
    public var height: Int
    public var mode: ImportedColorMode
    /// 1, 8 or 16.
    public var bitsPerChannel: Int
    public var hasAlpha: Bool

    public init(blob: ImportedBlob, width: Int, height: Int, mode: ImportedColorMode, bitsPerChannel: Int, hasAlpha: Bool) {
        self.blob = blob
        self.width = width
        self.height = height
        self.mode = mode
        self.bitsPerChannel = bitsPerChannel
        self.hasAlpha = hasAlpha
    }
}

/// An `image` node: pixels, resolution and placement.
public struct ImportedImage: Hashable, Sendable {
    public var pixels: ImportedPixels
    /// Pixels per inch (`ImageProps.dpi_x`, `dpi_y`); never 0.
    public var dpiX: Double
    public var dpiY: Double
    /// Maps the natural rect `(0, 0, width / dpiX · 72, height / dpiY · 72)` into the parent
    /// (`CommonProps.transform`).
    public var transform: AffineTransform
    /// `CommonProps.name` / `ImageProps.source_name`.
    public var name: String?
    /// The profile the file carries (CMS-012): `ImageColorSettings.embedded_profile`.
    public var embeddedProfile: ImportedProfile?

    public init(pixels: ImportedPixels, dpiX: Double = 72, dpiY: Double = 72, transform: AffineTransform = .identity, name: String? = nil,
                embeddedProfile: ImportedProfile? = nil) {
        self.embeddedProfile = embeddedProfile
        self.pixels = pixels
        self.dpiX = dpiX > 0 ? dpiX : 72
        self.dpiY = dpiY > 0 ? dpiY : 72
        self.transform = transform
        self.name = name
    }

    /// The natural rect in the node's own space, in points.
    public var naturalRect: Rect {
        ImageItem.naturalRect(pixelWidth: pixels.width, pixelHeight: pixels.height, dpiX: dpiX, dpiY: dpiY)
    }
}

// MARK: - Paths

/// One contour: a start point and segments.  Quadratic curves are raised to cubics on the way in
/// (exactly), so every segment is a line or a cubic, as the document's `PathPoint`s hold them.
public struct ImportedContour: Hashable, Sendable {
    public enum Segment: Hashable, Sendable {
        case line(to: Point)
        case cubic(control1: Point, control2: Point, to: Point)

        public var end: Point {
            switch self {
            case .line(let end), .cubic(_, _, let end): return end
            }
        }
    }

    public var start: Point
    public var segments: [Segment]
    public var closed: Bool

    public init(start: Point, segments: [Segment] = [], closed: Bool = false) {
        self.start = start
        self.segments = segments
        self.closed = closed
    }

    /// The last point reached.
    public var end: Point { segments.last?.end ?? start }

    /// The contour with every point transformed (exact for Béziers).
    public func applying(_ transform: AffineTransform) -> ImportedContour {
        ImportedContour(start: transform.apply(start), segments: segments.map { segment in
            switch segment {
            case .line(let end): return .line(to: transform.apply(end))
            case .cubic(let c1, let c2, let end): return .cubic(control1: transform.apply(c1), control2: transform.apply(c2), to: transform.apply(end))
            }
        }, closed: closed)
    }

    /// Every point mentioned, for the control-point hull.
    public var allPoints: [Point] {
        [start] + segments.flatMap { segment -> [Point] in
            switch segment {
            case .line(let end): return [end]
            case .cubic(let c1, let c2, let end): return [c1, c2, end]
            }
        }
    }

    /// One document path point: the anchor and its handles as offsets from it (zero =
    /// retracted), and whether it is a smooth curve point.
    public struct PathPoint: Hashable, Sendable {
        public var anchor: Point
        public var inHandle: Vector
        public var outHandle: Vector
        /// Both handles extended and collinear (`POINT_KIND_CURVE`); otherwise a corner.
        public var smooth: Bool
    }

    /// The contour as the document's `PathPoint`s (contour.proto): the anchors in order, each
    /// with the handle of the segment arriving (`in`) and leaving (`out`) as offsets.  A closed
    /// contour whose last segment ends on its start does not repeat the start; the closing
    /// segment's handles land on the first and last points.
    public var pathPoints: [PathPoint] {
        var anchors = [start]
        var ins: [Vector] = [.zero]
        var outs: [Vector] = [.zero]
        for segment in segments {
            let from = anchors[anchors.count - 1]
            switch segment {
            case .line(let end):
                anchors.append(end)
                ins.append(.zero)
                outs.append(.zero)
            case .cubic(let c1, let c2, let end):
                outs[outs.count - 1] = c1 - from
                anchors.append(end)
                ins.append(c2 - end)
                outs.append(.zero)
            }
        }
        if closed, anchors.count > 1, anchors[anchors.count - 1].isApproximatelyEqual(to: start, tolerance: 1e-9) {
            ins[0] = ins[ins.count - 1]
            anchors.removeLast()
            ins.removeLast()
            outs.removeLast()
        }
        return anchors.indices.map { index in
            let a = ins[index]
            let b = outs[index]
            let smooth = a.length > 1e-9 && b.length > 1e-9 && abs(a.cross(b)) <= 1e-6 * a.length * b.length && a.dot(b) < 0
            return PathPoint(anchor: anchors[index], inHandle: a, outHandle: b, smooth: smooth)
        }
    }
}

/// A named colour of the imported file (a FreeHand swatch): `WTModel` writes it as a reference
/// to the document's swatch of that name and colour, created when there is none.
public struct ImportedSwatch: Hashable, Sendable {
    public var name: String
    public var color: Color
    /// Spot (true) or process (false).
    public var spot: Bool

    public init(name: String, color: Color, spot: Bool = false) {
        self.name = name
        self.color = color
        self.spot = spot
    }
}

/// A tiled fill's tile (`TiledFill`): artwork repeated across the object.
public struct ImportedTile: Hashable, Sendable {
    /// The tile artwork, in tile space (points, y down); its geometric bounds are one cell.
    public var nodes: [ImportedNode]
    /// Degrees.
    public var angle: Double
    /// Percent.
    public var scaleX: Double
    public var scaleY: Double
    /// Shift of the pattern in the object's own coordinates, points.
    public var offset: Point

    public init(nodes: [ImportedNode], angle: Double = 0, scaleX: Double = 100, scaleY: Double = 100, offset: Point = .zero) {
        self.nodes = nodes
        self.angle = angle
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offset = offset
    }
}

/// A paint an importer can produce.
public enum ImportedPaint: Hashable, Sendable {
    case none
    case solid(Color)
    /// A gradient whose axis is in the path's own coordinates.
    case gradient(Gradient)
    /// A named colour (`BasicFill` referencing a swatch).
    case swatch(ImportedSwatch)
    /// An 8 × 8 bitmap pattern in one colour (`PatternFill`, `PatternStroke`).
    case pattern(PatternPaint)
    /// Tiled artwork (`TiledFill`).
    case tiled(ImportedTile)
    /// A lens (`LensFill`), in the path's own coordinates.
    case lens(LensFill)

    public var isNone: Bool { self == .none }

    /// The paint's colour for single-colour consumers: the solid or named colour, the first
    /// stop, a pattern's or lens's colour; nil for none and a tile.
    public var representativeColor: Color? {
        switch self {
        case .none, .tiled: return nil
        case .solid(let color): return color
        case .gradient(let gradient): return gradient.sortedStops.first?.color
        case .swatch(let swatch): return swatch.color
        case .pattern(let pattern): return pattern.color
        case .lens(let lens): return lens.color
        }
    }

    /// The named colours the paint uses.
    public var swatches: [ImportedSwatch] {
        switch self {
        case .swatch(let swatch): return [swatch]
        case .tiled(let tile): return tile.nodes.flatMap(\.swatches)
        default: return []
        }
    }
}

/// An arrowhead of a stroke (`Arrowhead`): an outline in stroke-width units, origin at the
/// path's end, +x pointing beyond it.
public struct ImportedArrowhead: Hashable, Sendable {
    public var contours: [ImportedContour]
    /// Filled with the stroke colour; otherwise stroked one unit wide.
    public var filled: Bool
    public var name: String

    public init(contours: [ImportedContour], filled: Bool = true, name: String = "") {
        self.contours = contours
        self.filled = filled
        self.name = name
    }
}

/// A stroke: paint and geometry.
public struct ImportedStroke: Hashable, Sendable {
    public var paint: ImportedPaint
    public var style: StrokeStyle
    public var startArrowhead: ImportedArrowhead?
    public var endArrowhead: ImportedArrowhead?

    public init(paint: ImportedPaint, style: StrokeStyle = StrokeStyle(), startArrowhead: ImportedArrowhead? = nil, endArrowhead: ImportedArrowhead? = nil) {
        self.paint = paint
        self.style = style
        self.startArrowhead = startArrowhead
        self.endArrowhead = endArrowhead
    }
}

/// A `path` node.
public struct ImportedPath: Hashable, Sendable {
    public var contours: [ImportedContour]
    public var fill: ImportedPaint
    public var fillRule: FillRule
    public var stroke: ImportedStroke?
    /// 0 ... 1, the node's own opacity (a group opacity is on the group).
    public var opacity: Double
    public var transform: AffineTransform
    public var name: String?
    /// An attached URL (`CommonProps.url`): PDF link areas, SVG `<a>`.
    public var url: String?

    public init(contours: [ImportedContour], fill: ImportedPaint = .none, fillRule: FillRule = .nonZero, stroke: ImportedStroke? = nil, opacity: Double = 1, transform: AffineTransform = .identity, name: String? = nil, url: String? = nil) {
        self.contours = contours
        self.fill = fill
        self.fillRule = fillRule
        self.stroke = stroke
        self.opacity = opacity
        self.transform = transform
        self.name = name
        self.url = url
    }
}

// MARK: - Text

/// One styled run of a text block.
public struct ImportedTextRun: Hashable, Sendable {
    public var text: String
    /// The PostScript name the file asks for; `WTModel` resolves it through font substitution
    /// (font-substitution.adoc) when it is not installed.
    public var fontName: String
    /// Points.
    public var fontSize: Double
    public var fill: ImportedPaint
    /// The baseline origin of the run's first character in the block's space.
    public var origin: Point
    /// The family and style when the file names them rather than a PostScript name (FreeHand);
    /// they win over `fontName`, which is then only the preview's font.
    public var family: String?
    public var style: String?

    public init(text: String, fontName: String, fontSize: Double, fill: ImportedPaint = .solid(.black), origin: Point, family: String? = nil, style: String? = nil) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.fill = fill
        self.origin = origin
        self.family = family
        self.style = style
    }
}

/// How the lines of a text block align (`ParagraphProps.alignment`).
public enum ImportedTextAlignment: Hashable, Sendable {
    case left
    case right
    case center
    case justify
}

/// A `text` node: point text of one or more runs, set on one baseline or several; with a
/// `frame`, area text whose rectangle's top-left corner is the block's origin; with a `path`,
/// text on that path.
public struct ImportedText: Hashable, Sendable {
    public var runs: [ImportedTextRun]
    public var transform: AffineTransform
    public var name: String?
    /// Area text: the block's width and height in points (`TextBlockProps`), its rectangle
    /// from the block's origin.  The runs' origins are only the preview's layout.
    public var frame: Size?
    /// Text on a path: the path in the block's space (`TextOnPathProps`, the path child).
    public var path: ImportedPath?
    /// The paragraphs' alignment.
    public var alignment: ImportedTextAlignment

    public init(runs: [ImportedTextRun], transform: AffineTransform = .identity, name: String? = nil, frame: Size? = nil, path: ImportedPath? = nil,
                alignment: ImportedTextAlignment = .left) {
        self.runs = runs
        self.transform = transform
        self.name = name
        self.frame = frame
        self.path = path
        self.alignment = alignment
    }

    /// The text of every run in order.
    public var string: String { runs.map(\.text).joined() }
}

// MARK: - Placed files

/// A file kept as-is and shown through its preview (`placed_file`, `svg_animation`).
public struct ImportedPlacedFile: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `PLACED_FILE_FORMAT_EPS`: PostScript kept verbatim for print pass-through.
        case eps
        /// `SvgAnimationProps`: the animation mechanisms found and the declared duration
        /// (0 = indefinite).
        case svgAnimation(css: Bool, smil: Bool, script: Bool, durationMs: UInt64)
    }

    public var kind: Kind
    public var blob: ImportedBlob
    /// The file's own box in points (EPS `%%BoundingBox`, SVG view box), y down.
    public var bounds: Rect
    public var transform: AffineTransform
    public var name: String?
    /// An EPS file's preview re-encoded as a PNG blob, with its pixel size
    /// (`PlacedFileContent.preview_sha256`, `preview_width`, `preview_height`); drawn scaled into
    /// `bounds`.  Nil when the file carries none: the renderer draws a gray box with the name.
    public var preview: ImportedPixels?

    public init(kind: Kind, blob: ImportedBlob, bounds: Rect, transform: AffineTransform = .identity, name: String? = nil, preview: ImportedPixels? = nil) {
        self.kind = kind
        self.blob = blob
        self.bounds = bounds
        self.transform = transform
        self.name = name
        self.preview = preview
    }
}

// MARK: - Groups

/// How a layer of the opened file was set in it (D-085): what a `.layer` group's document layer
/// is created with when the file opens as a document.  An import (a scene placed on the current
/// layer) leaves hidden layers out and ignores the rest.
public struct ImportedLayerState: Hashable, Sendable {
    /// Shown (Illustrator's eye; a PDF optional content group that is on).
    public var visible: Bool
    /// Locked against editing (Illustrator's lock).
    public var locked: Bool
    /// Printed; a layer that is not becomes a background layer.
    public var printing: Bool
    /// Drawn as outlines (Illustrator's Outline view of the layer, the layer's keyline).
    public var outline: Bool

    public init(visible: Bool = true, locked: Bool = false, printing: Bool = true, outline: Bool = false) {
        self.visible = visible
        self.locked = locked
        self.printing = printing
        self.outline = outline
    }

    /// Visible, unlocked, printing, previewed: a layer created without the file saying otherwise.
    public static let normal = ImportedLayerState()
}

/// A `group` node, a clipping group, or a layer of the imported file.
public struct ImportedGroup: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// An ordinary group.
        case group
        /// A layer of the source file (Illustrator, DXF, PDF optional content): imported as a
        /// group named after it (import-formats.adoc).
        case layer
        /// An instance of the scene's symbol with this `ImportedSymbol.key` (FreeHand): the
        /// group's `transform` places the symbol and its children are the symbol's artwork, so
        /// a consumer that knows no symbols draws the expanded group.
        case instance(symbol: String)
    }

    public var children: [ImportedNode]
    /// A clipping group's clip (`GroupProps.clip_path`, OBJ-027): the path that clips the
    /// children, in the group's space.  Its paint is ignored unless `clipAppearance`.
    public var clip: ImportedPath?
    public var opacity: Double
    public var transform: AffineTransform
    public var name: String?
    public var role: Role
    /// The clip path keeps its fill and stroke (FreeHand's *Paste Inside*: the fill is drawn
    /// below the contents and the stroke above them, as a WireTuner clip group draws its clip
    /// path).  Off for formats whose clips are geometry only (PDF, SVG).
    public var clipAppearance: Bool
    /// A `.layer` group's settings in the file; `.normal` for every other group.
    public var layerState: ImportedLayerState

    public init(children: [ImportedNode], clip: ImportedPath? = nil, opacity: Double = 1, transform: AffineTransform = .identity, name: String? = nil, role: Role = .group,
                clipAppearance: Bool = false, layerState: ImportedLayerState = .normal) {
        self.children = children
        self.clip = clip
        self.opacity = opacity
        self.transform = transform
        self.name = name
        self.role = role
        self.clipAppearance = clipAppearance
        self.layerState = layerState
    }
}

/// One node of an imported subtree.
public indirect enum ImportedNode: Hashable, Sendable {
    case group(ImportedGroup)
    case path(ImportedPath)
    case text(ImportedText)
    case image(ImportedImage)
    case placed(ImportedPlacedFile)

    /// The node's name.
    public var name: String? {
        switch self {
        case .group(let group): return group.name
        case .path(let path): return path.name
        case .text(let text): return text.name
        case .image(let image): return image.name
        case .placed(let placed): return placed.name
        }
    }

    /// The node's transform into its parent.
    public var transform: AffineTransform {
        switch self {
        case .group(let group): return group.transform
        case .path(let path): return path.transform
        case .text(let text): return text.transform
        case .image(let image): return image.transform
        case .placed(let placed): return placed.transform
        }
    }

    /// Every node of the subtree, depth first, parents before children.
    public var descendants: [ImportedNode] {
        if case .group(let group) = self {
            return [self] + group.children.flatMap(\.descendants)
        }
        return [self]
    }

    /// The named colours the subtree paints with (fills, strokes, text, tiles, and clip paths
    /// that keep their appearance), in first-use order with repeats.
    public var swatches: [ImportedSwatch] {
        switch self {
        case .group(let group):
            let clip = group.clipAppearance ? group.clip.map { ImportedNode.path($0).swatches } ?? [] : []
            return clip + group.children.flatMap(\.swatches)
        case .path(let path):
            return path.fill.swatches + (path.stroke?.paint.swatches ?? [])
        case .text(let text):
            return text.runs.flatMap(\.fill.swatches) + (text.path.map { ImportedNode.path($0).swatches } ?? [])
        case .image, .placed:
            return []
        }
    }
}

// MARK: - Scene

/// Artwork for a named document layer rather than the import group: the PDF importer's *Notes*
/// and *URLs* layers (import-formats.adoc, "PDF").
public struct ImportedLayer: Hashable, Sendable {
    public var name: String
    public var nodes: [ImportedNode]

    public init(name: String, nodes: [ImportedNode]) {
        self.name = name
        self.nodes = nodes
    }
}

/// A symbol of the imported file: artwork its instances (`ImportedGroup.Role.instance`) share.
public struct ImportedSymbol: Hashable, Sendable {
    /// Unique within the scene.
    public var key: String
    public var name: String
    /// The artwork in symbol space.
    public var nodes: [ImportedNode]

    public init(key: String, name: String, nodes: [ImportedNode]) {
        self.key = key
        self.name = name
        self.nodes = nodes
    }
}

/// The result of one import.
public struct ImportedScene: Hashable, Sendable {
    /// How the document receives it (importing.adoc, "What happens to imported artwork").
    public enum Kind: Hashable, Sendable {
        /// Converted to native objects, wrapped in one group named after the file.
        case vector
        /// One image node.
        case bitmap
        /// One placed file (EPS, SVG animation, a legacy Illustrator file that fell back).
        case placed
    }

    public var kind: Kind
    /// The file name the import group (or the single node) is named after.
    public var name: String
    /// The natural size and origin in points: the page, view box or extents.  Click placement
    /// puts this rect's top-left corner at the pointer.
    public var bounds: Rect
    /// The artwork, back to front.  For `bitmap` and `placed` exactly one node.
    public var nodes: [ImportedNode]
    /// Artwork for named document layers.
    public var layers: [ImportedLayer]
    /// What was approximated or left out, for the import notice.
    public var notes: [String]
    /// The symbols the scene's instance groups use.
    public var symbols: [ImportedSymbol]

    public init(kind: Kind, name: String, bounds: Rect, nodes: [ImportedNode], layers: [ImportedLayer] = [], notes: [String] = [],
                symbols: [ImportedSymbol] = []) {
        self.kind = kind
        self.name = name
        self.bounds = bounds
        self.nodes = nodes
        self.layers = layers
        self.notes = notes
        self.symbols = symbols
    }

    /// The subtree `WTModel` creates on the current layer: for a vector import one group named
    /// after the file holding `nodes`; otherwise the single node, named after the file when it
    /// has no name of its own.
    public var subtree: ImportedNode {
        switch kind {
        case .vector:
            return .group(ImportedGroup(children: nodes, name: name))
        case .bitmap, .placed:
            guard let node = nodes.first else {
                return .group(ImportedGroup(children: [], name: name))
            }
            switch node {
            case .image(var image):
                image.name = image.name ?? name
                return .image(image)
            case .placed(var placed):
                placed.name = placed.name ?? name
                return .placed(placed)
            default:
                return node
            }
        }
    }

    /// Every blob the scene references, once each, in first-use order (a placed file's own blob
    /// before its preview's).
    public var blobs: [ImportedBlob] {
        var seen = Set<Data>()
        var result: [ImportedBlob] = []
        func visit(_ node: ImportedNode) {
            var found: [ImportedBlob] = []
            switch node {
            case .image(let image): found = [image.pixels.blob] + (image.embeddedProfile?.blob.map { [$0] } ?? [])
            case .placed(let placed): found = [placed.blob] + (placed.preview.map { [$0.blob] } ?? [])
            case .group(let group): group.children.forEach(visit)
            case .path, .text: break
            }
            for blob in found where seen.insert(blob.sha256).inserted {
                result.append(blob)
            }
        }
        nodes.forEach(visit)
        layers.flatMap(\.nodes).forEach(visit)
        symbols.flatMap(\.nodes).forEach(visit)
        return result
    }

    /// Every named colour the scene uses, once per name and colour, in first-use order.
    public var swatches: [ImportedSwatch] {
        var seen = Set<ImportedSwatch>()
        return (nodes + layers.flatMap(\.nodes) + symbols.flatMap(\.nodes)).flatMap(\.swatches).filter { seen.insert($0).inserted }
    }
}
