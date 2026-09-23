// The renderer-agnostic display list (docs/spec/client.adoc, "The display list").
//
// A display list is a value type of *resolved* drawing primitives for one canvas: every
// item's `transform` maps its local space straight to pasteboard space (transform chains are
// already flattened), styles are values rather than references, and items are stored in draw
// order (back to front).  It knows nothing about Metal or Core Graphics.  Building it from
// `WTModel` is wired by the model tasks; REND-001 delivers the type and its builder.
// Geometry (`Point`, `Rect`, `AffineTransform`, `FillRule`) comes from WTGeometry.

/// Identifies the canvas a display list and its tiles belong to: a pasteboard or a master page.
import WTGeometry

public struct CanvasID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { rawValue }
}

/// An sRGB colour with straight (non-premultiplied) alpha, components in 0...1.
public struct Color: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// A neutral grey.
    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public static let black = Color(white: 0)
    public static let white = Color(white: 1)
    public static let clear = Color(white: 0, alpha: 0)

    /// The colour with its alpha multiplied by `factor`.
    public func withAlpha(multipliedBy factor: Double) -> Color {
        Color(red: red, green: green, blue: blue, alpha: alpha * factor)
    }
}

/// What a fill or stroke is painted with.  Gradients and tiled fills join in the colour epic.
public enum Paint: Hashable, Sendable {
    /// The well-known *None*: paints nothing and, for hit testing, covers nothing
    /// (docs/_includes/appearance/attribute-stack.adoc, "Hit testing").
    case none
    case solid(Color)

    /// The colour a solid paint paints with; nil for *None*.
    public var color: Color? {
        switch self {
        case .none: return nil
        case .solid(let color): return color
        }
    }

    public var isNone: Bool { self == .none }
}

public enum LineCap: Hashable, Sendable {
    case butt
    case round
    case square
}

public enum LineJoin: Hashable, Sendable {
    case miter
    case round
    case bevel
}

/// Stroke geometry parameters, in the item's local units.
public struct StrokeStyle: Hashable, Sendable {
    public var width: Double
    public var cap: LineCap
    public var join: LineJoin
    public var miterLimit: Double
    /// Alternating dash and gap lengths; empty for a solid stroke.
    public var dash: [Double]
    public var dashPhase: Double

    public init(
        width: Double = 1,
        cap: LineCap = .butt,
        join: LineJoin = .miter,
        miterLimit: Double = 10,
        dash: [Double] = [],
        dashPhase: Double = 0
    ) {
        self.width = width
        self.cap = cap
        self.join = join
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashPhase = dashPhase
    }

    /// How far, in local units, the stroked outline can extend beyond the path's control
    /// bounds: half the width times the worst of the miter limit and a square cap's diagonal.
    var outset: Double {
        width * max(miterLimit, 2.0.squareRoot()) / 2
    }

    /// A width of 0 is a hairline: one device pixel at any zoom
    /// (docs/_includes/appearance/stroke-attributes.adoc, "Stroke width presets").
    public var isHairline: Bool { width <= 0 }

    /// The dash the renderers apply, normalized as the stroke page's read-time rules say: no
    /// lengths, a negative or non-finite length, or all-zero lengths read as solid (empty); an
    /// odd count repeats its cycle, which Core Graphics does natively (PDF semantics).
    public var effectiveDash: [Double] {
        guard !dash.isEmpty,
              dash.allSatisfy({ $0.isFinite && $0 >= 0 }),
              dash.contains(where: { $0 > 0 })
        else {
            return []
        }
        return dash
    }
}

/// A filled path.
public struct FillItem: Hashable, Sendable {
    public var path: DisplayPath
    public var rule: FillRule
    public var paint: Paint
    /// Local → pasteboard.
    public var transform: AffineTransform

    public init(path: DisplayPath, rule: FillRule = .nonZero, paint: Paint, transform: AffineTransform = .identity) {
        self.path = path
        self.rule = rule
        self.paint = paint
        self.transform = transform
    }
}

/// A stroked path.  GEO-003 replaces on-the-fly stroking with pre-expanded outlines; the
/// style stays here so both renderers keep stroking identically until then.
public struct StrokeItem: Hashable, Sendable {
    public var path: DisplayPath
    public var style: StrokeStyle
    public var paint: Paint
    /// Local → pasteboard.
    public var transform: AffineTransform

    public init(path: DisplayPath, style: StrokeStyle = StrokeStyle(), paint: Paint, transform: AffineTransform = .identity) {
        self.path = path
        self.style = style
        self.paint = paint
        self.transform = transform
    }
}

/// A placed raster image.  Until the image pipeline lands the renderers draw a neutral
/// placeholder over `rect`; `assetID` names the blob the pipeline will resolve.
public struct ImageItem: Hashable, Sendable {
    public var assetID: String
    /// The image's frame in local space.
    public var rect: Rect
    /// Local → pasteboard.
    public var transform: AffineTransform

    public init(assetID: String, rect: Rect, transform: AffineTransform = .identity) {
        self.assetID = assetID
        self.rect = rect
        self.transform = transform
    }
}

/// A positioned run of text.  With a `glyphRun` (from `WTText`, TXT-001) the renderers fill
/// its glyph outlines in `color`; without one they draw the run's bounds and baseline as a
/// placeholder.
public struct TextRunItem: Hashable, Sendable {
    public var text: String
    /// The baseline origin in local space.
    public var origin: Point
    /// The run's ink bounds in local space.
    public var bounds: Rect
    public var color: Color
    /// Local → pasteboard.
    public var transform: AffineTransform
    /// The laid-out glyphs, in local space.
    public var glyphRun: GlyphRun?

    public init(text: String, origin: Point, bounds: Rect, color: Color = .black, transform: AffineTransform = .identity, glyphRun: GlyphRun? = nil) {
        self.text = text
        self.origin = origin
        self.bounds = bounds
        self.color = color
        self.transform = transform
        self.glyphRun = glyphRun
    }

    /// A run of laid-out glyphs, its bounds the glyphs' ink (or the origin alone for a run
    /// without ink, such as spaces).
    public init(text: String, glyphRun: GlyphRun, origin: Point, color: Color = .black, transform: AffineTransform = .identity) {
        self.init(
            text: text,
            origin: origin,
            bounds: glyphRun.inkBounds ?? Rect(x: origin.x, y: origin.y, width: 0, height: 0),
            color: color,
            transform: transform,
            glyphRun: glyphRun
        )
    }
}

/// A group of items drawn together, optionally clipped and composited with one opacity.
/// Children carry their own resolved transforms; `transform` applies to `clip` only.
public struct GroupItem: Hashable, Sendable {
    public var children: [DisplayItem]
    public var clip: DisplayPath?
    public var clipRule: FillRule
    /// 0...1; values below 1 composite the whole group through a transparency layer.
    public var opacity: Double
    /// Clip local → pasteboard.
    public var transform: AffineTransform
    /// The layer highlight colour, set on the group a layer becomes: Keyline modes draw every
    /// descendant's hairlines in the nearest ancestor's colour (REND-005).  Nil inherits.
    public var highlightColor: Color?

    public init(
        children: [DisplayItem],
        clip: DisplayPath? = nil,
        clipRule: FillRule = .nonZero,
        opacity: Double = 1,
        transform: AffineTransform = .identity,
        highlightColor: Color? = nil
    ) {
        self.children = children
        self.clip = clip
        self.clipRule = clipRule
        self.opacity = min(max(opacity, 0), 1)
        self.transform = transform
        self.highlightColor = highlightColor
    }
}

/// One resolved drawing primitive.
public indirect enum DisplayItem: Hashable, Sendable {
    case fill(FillItem)
    case stroke(StrokeItem)
    /// A path painted by its attribute stack (REND-002).
    case path(PathItem)
    case image(ImageItem)
    case text(TextRunItem)
    case group(GroupItem)

    /// The item's own transform (for a group, the clip's).
    public var transform: AffineTransform {
        switch self {
        case .fill(let item): return item.transform
        case .stroke(let item): return item.transform
        case .path(let item): return item.transform
        case .image(let item): return item.transform
        case .text(let item): return item.transform
        case .group(let item): return item.transform
        }
    }

    /// A conservative pasteboard-space bound on everything the item can paint, or nil when it
    /// paints nothing.  Renderers cull on this; hit testing (REND-003) refines it.
    public var bounds: Rect? {
        switch self {
        case .fill(let item):
            return item.path.controlBounds.map { $0.applying(item.transform) }
        case .stroke(let item):
            let outset = item.style.outset
            return item.path.controlBounds.map { $0.expanded(by: outset).applying(item.transform) }
        case .path(let item):
            let outset = item.appearance.outset
            return item.path.controlBounds.map { $0.expanded(by: outset).applying(item.transform) }
        case .image(let item):
            return item.rect.applying(item.transform)
        case .text(let item):
            return item.bounds.applying(item.transform)
        case .group(let item):
            guard let content = DisplayList.union(of: item.children.compactMap(\.bounds)) else {
                return nil
            }
            guard let clip = item.clip else {
                return content
            }
            guard let clipBounds = clip.controlBounds else {
                return nil
            }
            return content.intersection(clipBounds.applying(item.transform)).nonNull
        }
    }
}

/// The drawing primitives of one canvas in draw order, with per-item bounds precomputed for
/// culling.  Value type: a render in flight never sees a half-applied change.
public struct DisplayList: Hashable, Sendable {
    public let canvas: CanvasID
    /// Items back to front.
    public let items: [DisplayItem]
    /// `items[i]`'s pasteboard bounds, computed once at construction.
    public let itemBounds: [Rect?]
    /// The union of every item's bounds; nil for a list that paints nothing.
    public let bounds: Rect?
    /// The document node each top-level item was built from (REND-004), parallel to `items`;
    /// empty when the builder supplied none, nil for an item that has no node of its own.
    public let nodeIDs: [NodeID?]
    /// Top-level item index by node id.
    private let nodeIndex: [NodeID: Int]

    public init(canvas: CanvasID, items: [DisplayItem], nodeIDs: [NodeID?] = []) {
        self.canvas = canvas
        self.items = items
        let itemBounds = items.map(\.bounds)
        self.itemBounds = itemBounds
        self.bounds = DisplayList.union(of: itemBounds.compactMap { $0 })
        // Normalized to the item count so a short or long id list cannot misaddress items.
        let ids = nodeIDs.isEmpty ? [] : Array((nodeIDs + Array(repeating: nil, count: max(items.count - nodeIDs.count, 0))).prefix(items.count))
        self.nodeIDs = ids
        var index: [NodeID: Int] = [:]
        index.reserveCapacity(ids.count)
        for (position, id) in ids.enumerated() {
            if let id {
                index[id] = position
            }
        }
        nodeIndex = index
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// The index of the top-level item built from `node`, if the list has one.
    public func index(of node: NodeID) -> Int? {
        nodeIndex[node]
    }

    /// The pasteboard bounds of the item built from `node`, if it paints anything.
    public func bounds(of node: NodeID) -> Rect? {
        index(of: node).flatMap { itemBounds[$0] }
    }

    public static func == (lhs: DisplayList, rhs: DisplayList) -> Bool {
        lhs.canvas == rhs.canvas && lhs.nodeIDs == rhs.nodeIDs && lhs.items == rhs.items
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canvas)
        hasher.combine(items)
        hasher.combine(nodeIDs)
    }

    /// The indices of the items whose bounds intersect `rect`, in draw order.
    public func indices(intersecting rect: Rect) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(min(items.count, 64))
        for (index, bounds) in itemBounds.enumerated() {
            if let bounds, bounds.intersects(rect) {
                result.append(index)
            }
        }
        return result
    }

    static func union(of rects: [Rect]) -> Rect? {
        guard var result = rects.first else {
            return nil
        }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }
}

/// Collects items with explicit z indices and produces a `DisplayList` in draw order.
/// Items with equal z keep insertion order (a stable sort), which is how layer order, then
/// sibling order, becomes one sequence.
public struct DisplayListBuilder: Sendable {
    private struct Entry: Sendable {
        let z: Int
        let sequence: Int
        let item: DisplayItem
        let node: NodeID?
    }

    public let canvas: CanvasID
    private var entries: [Entry] = []

    public init(canvas: CanvasID) {
        self.canvas = canvas
    }

    public var count: Int { entries.count }

    /// Adds `item` at depth `z`; larger z draws later (on top).  `node` names the document
    /// node it was built from, for change-driven invalidation and hit testing (REND-004).
    public mutating func add(_ item: DisplayItem, z: Int = 0, node: NodeID? = nil) {
        entries.append(Entry(z: z, sequence: entries.count, item: item, node: node))
    }

    /// The list, sorted by z then insertion order.
    public func build() -> DisplayList {
        let sorted = entries.sorted { lhs, rhs in
            lhs.z != rhs.z ? lhs.z < rhs.z : lhs.sequence < rhs.sequence
        }
        let nodes = sorted.map(\.node)
        return DisplayList(canvas: canvas, items: sorted.map(\.item), nodeIDs: nodes.contains { $0 != nil } ? nodes : [])
    }
}
