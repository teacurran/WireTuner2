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

/// What a fill or stroke is painted with (docs/_includes/appearance/fill-attributes.adoc,
/// gradients.adoc).  A stroke's paint fills its outline, so a Pattern stroke is a Basic stroke
/// painted `.pattern`.
public enum Paint: Hashable, Sendable {
    /// The well-known *None*: paints nothing and, for hit testing, covers nothing
    /// (docs/_includes/appearance/attribute-stack.adoc, "Hit testing").
    case none
    case solid(Color)
    case gradient(Gradient)
    case pattern(PatternPaint)
    case custom(CustomFill)
    case textured(TexturedFill)
    case tiled(TiledFill)
    case lens(LensFill)

    /// The colour a solid paint paints with; nil for *None* and every other kind.
    public var color: Color? {
        switch self {
        case .solid(let color): return color
        default: return nil
        }
    }

    /// Whether the paint paints nothing: *None*, a gradient without stops, a tiled fill whose
    /// tile paints nothing.  Lens and transparent Custom fills paint (and hit) everywhere
    /// inside the path.
    public var isNone: Bool {
        switch self {
        case .none: return true
        case .gradient(let gradient): return gradient.stops.isEmpty
        case .tiled(let tiled): return tiled.tileBounds == nil
        case .solid, .pattern, .custom, .textured, .lens: return false
        }
    }

    /// Whether the paint looks at what is beneath the object (a lens).
    public var isLens: Bool {
        if case .lens = self { return true }
        return false
    }
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

/// A placed raster image (IMG-004; docs/_includes/imported/bitmaps.adoc).  `assetID` is the
/// blob's SHA-256 in hex, which the renderer's `ImageStore` resolves; until the pixels are
/// decoded (or with no store) the renderers draw the placeholder over the cropped frame.
public struct ImageItem: Hashable, Sendable {
    public var assetID: String
    /// The image's natural frame in local space (`naturalRect`).
    public var rect: Rect
    /// Local → pasteboard.
    public var transform: AffineTransform
    /// The crop in unit image space (0...1 of the natural frame, y down); nil is uncropped.
    public var crop: Rect?
    public var mode: ImageMode
    public var hasAlpha: Bool
    public var displayAlpha: Bool
    public var transparentBackground: Bool
    public var ramp: GrayRamp
    /// The resolved tint (`ImageProps.tint`) for bilevel and grayscale images.
    public var tint: Color?
    /// The effective source profile (`ImageColorSettings`, resolved by WTModel); nil draws the
    /// decoded image in its own colour space.
    public var sourceProfile: WTColor.ProfileRef?
    /// The image's rendering intent override; nil uses the document intent.
    public var intent: WTColor.RenderingIntent?
    /// `source_name`, for the placeholder.
    public var name: String

    public init(
        assetID: String,
        rect: Rect,
        transform: AffineTransform = .identity,
        crop: Rect? = nil,
        mode: ImageMode = .rgb,
        hasAlpha: Bool = false,
        displayAlpha: Bool = true,
        transparentBackground: Bool = false,
        ramp: GrayRamp = .normal,
        tint: Color? = nil,
        sourceProfile: WTColor.ProfileRef? = nil,
        intent: WTColor.RenderingIntent? = nil,
        name: String = ""
    ) {
        self.assetID = assetID
        self.rect = rect
        self.transform = transform
        self.crop = crop
        self.mode = mode
        self.hasAlpha = hasAlpha
        self.displayAlpha = displayAlpha
        self.transparentBackground = transparentBackground
        self.ramp = ramp
        self.tint = tint
        self.sourceProfile = sourceProfile
        self.intent = intent
        self.name = name
    }

    /// The natural frame of a `pixelWidth` × `pixelHeight` image at `dpiX` × `dpiY` pixels per
    /// inch, in points at the origin; a resolution of 0 (or not finite) reads as 72.
    public static func naturalRect(pixelWidth: Int, pixelHeight: Int, dpiX: Double, dpiY: Double) -> Rect {
        func read(_ dpi: Double) -> Double { dpi.isFinite && dpi > 0 ? dpi : 72 }
        return Rect(x: 0, y: 0, width: Double(pixelWidth) / read(dpiX) * 72, height: Double(pixelHeight) / read(dpiY) * 72)
    }

    /// The crop that applies: nil when unset or when any edge lies outside 0...1 or the area
    /// is not positive (importing.adoc, "Read-time normalizations").
    public var effectiveCrop: Rect? {
        guard let crop, crop.minX >= 0, crop.minY >= 0, crop.maxX <= 1, crop.maxY <= 1, crop.width > 0, crop.height > 0 else {
            return nil
        }
        return crop
    }

    /// The part of the natural frame that shows, in local space.
    public var visibleRect: Rect {
        guard let crop = effectiveCrop else {
            return rect
        }
        return Rect(x: rect.minX + crop.minX * rect.width, y: rect.minY + crop.minY * rect.height, width: crop.width * rect.width, height: crop.height * rect.height)
    }

    /// How the decoded pixels are treated (ramp, tint and *Transparent* on bilevel and
    /// grayscale images, alpha shown or not), the tint through `colorManagement`.
    func treatment(_ colorManagement: ColorManagement) -> ImageTreatment {
        ImageTreatment(
            mode: mode,
            ramp: ramp,
            tint: tint.map { colorManagement.sampledColor($0).srgb },
            transparentBackground: transparentBackground,
            displayAlpha: displayAlpha,
            hasAlpha: hasAlpha
        )
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
    /// The glyph fill prints over what is beneath it (`TextMarkValue.overprint`): composited
    /// with the multiply blend mode under overprint preview, as overprinting paths are.
    public var overprint: Bool
    /// Whether the run may be greeked when its type is smaller on screen than the renderer's
    /// `greekTypeBelow` (type-specifications: selected text is always drawn in full, so the
    /// builder clears this for text being edited or selected).
    public var greekable: Bool

    public init(text: String, origin: Point, bounds: Rect, color: Color = .black, transform: AffineTransform = .identity, glyphRun: GlyphRun? = nil, overprint: Bool = false, greekable: Bool = true) {
        self.text = text
        self.origin = origin
        self.bounds = bounds
        self.color = color
        self.transform = transform
        self.glyphRun = glyphRun
        self.overprint = overprint
        self.greekable = greekable
    }

    /// A run of laid-out glyphs, its bounds the glyphs' ink (or the origin alone for a run
    /// without ink, such as spaces).
    public init(text: String, glyphRun: GlyphRun, origin: Point, color: Color = .black, transform: AffineTransform = .identity, overprint: Bool = false, greekable: Bool = true) {
        self.init(
            text: text,
            origin: origin,
            bounds: glyphRun.inkBounds ?? Rect(x: origin.x, y: origin.y, width: 0, height: 0),
            color: color,
            transform: transform,
            glyphRun: glyphRun,
            overprint: overprint,
            greekable: greekable
        )
    }

    /// The type size in device pixels under `transform` (local → device): the run's font size
    /// scaled, or its bounds' height for a placeholder run.
    func pixelSize(under transform: AffineTransform) -> Double {
        let size = glyphRun.map { $0.font.size } ?? bounds.height
        return size * abs(self.transform.concatenating(transform).determinant).squareRoot()
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
    /// The group's own attribute stack (FX-006, FX-048): its effects apply to the group as one
    /// shape; its fills and strokes draw only over a Combine effect's outline.
    public var appearance: Appearance
    /// A live wrapper kind whose drawing is derived from the children on read (blend,
    /// extrusion, envelope, perspective); nil for a plain group.
    public var live: LiveGroup?
    /// Drawn in Preview and the fast modes but never in Keyline: the text effects `WTText`
    /// emits around glyph runs (text-effects, "Keyline view never shows them").
    public var hiddenInKeyline: Bool

    public init(
        children: [DisplayItem],
        clip: DisplayPath? = nil,
        clipRule: FillRule = .nonZero,
        opacity: Double = 1,
        transform: AffineTransform = .identity,
        highlightColor: Color? = nil,
        appearance: Appearance = Appearance(),
        live: LiveGroup? = nil,
        hiddenInKeyline: Bool = false
    ) {
        self.hiddenInKeyline = hiddenInKeyline
        self.children = children
        self.clip = clip
        self.clipRule = clipRule
        self.opacity = min(max(opacity, 0), 1)
        self.transform = transform
        self.highlightColor = highlightColor
        self.appearance = appearance
        self.live = live
    }

    /// Whether the group's drawing is derived (a live kind or effects of its own).
    public var isDerived: Bool {
        live != nil || appearance.hasEffects
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
            if item.hasEffects {
                return EffectNode.union(EffectPipeline.nodes(for: item))
            }
            return item.appearance.paintedBounds(of: item.path).map { $0.applying(item.transform) }
        case .image(let item):
            return item.visibleRect.applying(item.transform)
        case .text(let item):
            return item.bounds.applying(item.transform)
        case .group(let item):
            let drawn = item.isDerived ? EffectNode.union(EffectPipeline.derived(item).nodes) : DisplayList.union(of: item.children.compactMap(\.bounds))
            guard let content = drawn else {
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
    /// The top-level items that carry a lens fill (at any depth): they repaint whenever
    /// anything beneath them does (ATTR-019).
    public let lensIndices: [Int]

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
        lensIndices = items.indices.filter { items[$0].containsLens }
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// The index of the top-level item built from `node`, if the list has one.
    public func index(of node: NodeID) -> Int? {
        nodeIndex[node]
    }

    /// The pasteboard bounds of the item built from `node`, if it paints anything.
    /// The pasteboard frames of every placed image of blob `assetID`, at any depth: what to
    /// repaint when its pixels arrive or finish decoding (IMG-004).
    public func bounds(ofImageAsset assetID: String) -> [Rect] {
        var result: [Rect] = []
        func visit(_ items: [DisplayItem]) {
            for item in items {
                switch item {
                case .image(let image) where image.assetID == assetID:
                    result.append(image.visibleRect.applying(image.transform))
                case .group(let group):
                    visit(group.children)
                default:
                    break
                }
            }
        }
        visit(items)
        return result
    }

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

extension DisplayItem {
    /// The item placed by `transform` (its local space → the space `transform` maps into):
    /// `transform` is appended to the item's own transform, and to every descendant's and the
    /// clip's in a group.  Brush copies, tiles and snapshots are instanced this way.
    public func transformed(by transform: AffineTransform) -> DisplayItem {
        switch self {
        case .fill(var item):
            item.transform = item.transform.concatenating(transform)
            return .fill(item)
        case .stroke(var item):
            item.transform = item.transform.concatenating(transform)
            return .stroke(item)
        case .path(var item):
            item.transform = item.transform.concatenating(transform)
            return .path(item)
        case .image(var item):
            item.transform = item.transform.concatenating(transform)
            return .image(item)
        case .text(var item):
            item.transform = item.transform.concatenating(transform)
            return .text(item)
        case .group(var item):
            item.children = item.children.map { $0.transformed(by: transform) }
            item.transform = item.transform.concatenating(transform)
            return .group(item)
        }
    }

    /// Whether the item or anything inside it carries a lens fill.
    var containsLens: Bool {
        switch self {
        case .path(let item): return item.appearance.hasLens
        case .group(let group): return group.children.contains { $0.containsLens }
        case .fill(let item): return item.paint.isLens
        case .stroke, .image, .text: return false
        }
    }
}

extension DisplayList {
    /// Everything drawn before the item at `indexPath` (top-level index, then child indices):
    /// the earlier top-level items, and inside each enclosing group the earlier siblings, kept
    /// in their groups so clips and opacity still apply.  A lens's backdrop.
    func items(before indexPath: [Int]) -> [DisplayItem] {
        DisplayList.items(items, before: indexPath[...])
    }

    private static func items(_ items: [DisplayItem], before path: ArraySlice<Int>) -> [DisplayItem] {
        guard let first = path.first, first < items.count else {
            return items
        }
        var result = Array(items[..<first])
        if case .group(var group) = items[first], path.count > 1 {
            group.children = DisplayList.items(group.children, before: path.dropFirst())
            if !group.children.isEmpty {
                result.append(.group(group))
            }
        }
        return result
    }
}

extension DisplayItem {
    /// The item's geometry in pasteboard (parent) space without stroke outsets: path control
    /// bounds, image frames, text bounds, a group's children within its clip.  What a tile's
    /// cell and a brush symbol's size are measured by.
    var geometricBounds: Rect? {
        switch self {
        case .fill(let item):
            return item.path.controlBounds.map { $0.applying(item.transform) }
        case .stroke(let item):
            return item.path.controlBounds.map { $0.applying(item.transform) }
        case .path(let item):
            return item.path.controlBounds.map { $0.applying(item.transform) }
        case .image(let item):
            return item.visibleRect.applying(item.transform)
        case .text(let item):
            return item.bounds.applying(item.transform)
        case .group(let group):
            guard let content = DisplayList.union(of: group.children.compactMap(\.geometricBounds)) else {
                return nil
            }
            guard let clip = group.clip else {
                return content
            }
            return clip.controlBounds.flatMap { content.intersection($0.applying(group.transform)).nonNull }
        }
    }
}

extension DisplayItem {
    /// The item's own geometry in pasteboard space, effects excluded: what the Object panel
    /// shows and alignment uses (live-effects.adoc, "Effects and the rest of the object").
    public var ownBounds: Rect? { geometricBounds }

    /// The effected bounds menu:View[Show Effect Bounds] draws, for an item whose live effects or
    /// derived drawing change what it paints; nil otherwise.
    public var effectBounds: Rect? {
        switch self {
        case .path(let item) where item.hasEffects: return bounds
        case .group(let group) where group.isDerived: return bounds
        default: return nil
        }
    }
}
