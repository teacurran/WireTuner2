import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// A numeric range of the Find & Replace Graphics panel: either bound may be open.
public struct ValueRange: Hashable, Sendable {
    public var min: Double?
    public var max: Double?

    public init(min: Double? = nil, max: Double? = nil) {
        self.min = min
        self.max = max
    }

    /// Exactly `value` (the Replace tab's *Max* left empty).
    public static func exactly(_ value: Double) -> ValueRange { ValueRange(min: value, max: value) }

    /// Whether `value` lies in the range (bounds inclusive, to a millionth of a point).
    public func contains(_ value: Double) -> Bool {
        let tolerance = 1e-6
        return (min.map { value >= $0 - tolerance } ?? true) && (max.map { value <= $0 + tolerance } ?? true)
    }
}

/// The Find & Replace Graphics panel's query (OBJ-022, find-replace.adoc "Client"): a predicate
/// over nodes built from one attribute's settings, run over a scope.  Objects on locked, hidden or
/// Guides layers are never found; hidden objects are.  Objects inside groups are found as well as
/// the groups.  `run` returns node ids in stacking order and writes nothing.
public struct AttributeQuery: Sendable {
    /// Where to search.
    public enum Scope: Hashable, Sendable {
        /// The selected objects and everything inside them.
        case selection([OpID])
        /// Objects whose bounds intersect the page's rectangle.
        case page(OpID)
        case document
    }

    /// The *Object type* choices.
    public enum ObjectType: String, Hashable, Sendable, CaseIterable {
        case path, rectangle, ellipse, polygon, compositePath, clippingPath, group, blend, textBlock, bitmap, embeddedFile, envelope,
             extrusion, connectorLine, symbolInstance
    }

    /// The *Text effect* choices (a `TextEffect` case).
    public enum TextEffectKind: String, Hashable, Sendable, CaseIterable {
        case highlight, underline, strikethrough, inline, shadow, zoom
    }

    /// The Select tab's attributes.
    public enum Criterion: Sendable {
        /// Uses the colour as a fill, stroke, gradient stop or text colour.
        case color(Wiretuner_Doc_V1_ColorRef)
        /// Has the graphic style (`CommonProps.style`) or, on text, the paragraph or character
        /// style.
        case style(OpID)
        /// Its fills and strokes equal those of the object `node`.
        case sameAs(OpID)
        /// Its bounds' width and height lie in the ranges.
        case size(width: ValueRange, height: ValueRange)
        case fillType(Wiretuner_Doc_V1_FillKind)
        case strokeType(Wiretuner_Doc_V1_StrokeKind)
        case strokeWidth(ValueRange)
        /// Text set in the family and face (nil: any) at a size in the range.
        case font(family: String?, style: String?, size: ValueRange)
        /// Text with any effect (nil) or a specific one.
        case textEffect(TextEffectKind?)
        /// A name containing the string, ignoring case.
        case name(String)
        case objectType(ObjectType)
        /// The same shape (and stroke and fill) as the sample.
        case pathShape(PathShape)
        /// A custom halftone.
        case halftone
        /// Overprinting on a fill, stroke or text.
        case overprint
    }

    public var criterion: Criterion
    public var scope: Scope

    public init(_ criterion: Criterion, in scope: Scope = .document) {
        self.criterion = criterion
        self.scope = scope
    }

    /// Raw kinds that are objects without a `NodeKind` yet: bitmaps, envelopes, perspective objects
    /// and SVG animations.
    static let otherObjectKinds: Set<UInt32> = [170, 102, 103, 190]

    /// Every raw kind the query searches.
    static let searchedKinds = Set(Objects.kinds.map(\.rawValue)).union(otherObjectKinds)

    /// The matching nodes of `state`, in stacking order.  `bounds` gives an object's pasteboard
    /// bounds for page scope and *Size* (the scene's, when the caller has it); by default the
    /// geometry bounds, a text block's frame, or the object's origin.  `candidates` is the scope's
    /// `candidates(_:in:)` when the caller already holds them for this state (the panel keeps them
    /// per document revision): walking the tree sorts every parent's children, which is most of
    /// the cost on a large document.
    public func run(in state: EngineState, candidates: [OpID]? = nil, bounds: ((OpID) -> Rect?)? = nil) -> [OpID] {
        let bounds = bounds ?? { AttributeQuery.bounds(of: $0, in: state) }
        var candidates = candidates ?? Self.candidates(scope, in: state)
        if case .page(let id) = scope {
            guard let page = PageList(state)[id] else { return [] }
            candidates = candidates.filter { bounds($0)?.intersects(page.rect) == true }
        }
        let matcher = AttributeMatcher(criterion: criterion, state: state, bounds: bounds)
        return candidates.filter(matcher.matches)
    }

    /// The Select tab's btn:[Find]: the found objects, added to `selection` when *Add to
    /// selection* is ticked, else replacing it.
    public func select(in state: EngineState, adding selection: [OpID]? = nil, bounds: ((OpID) -> Rect?)? = nil) -> [OpID] {
        let found = run(in: state, bounds: bounds)
        guard let selection else { return found }
        let known = Set(selection)
        return selection + found.filter { !known.contains($0) }
    }

    /// The objects a scope searches, in stacking order, before page filtering.
    public static func candidates(_ scope: Scope, in state: EngineState) -> [OpID] {
        let order = LayerOrder(state)
        var searchable: Set<OpID> = []
        for layer in order.layers where layer.role == .ordinary && layer.visible && !layer.locked {
            searchable.insert(layer.id)
        }
        var result: [OpID] = []
        func walk(_ node: OpID) {
            let kind = state.store.kind(node)
            guard searchedKinds.contains(kind), state.isLive(node) else { return }
            result.append(node)
            if kind == NodeKind.group.rawValue {
                state.liveChildren(node).forEach(walk)
            }
        }
        switch scope {
        case .selection(let nodes):
            var seen: Set<OpID> = []
            for node in Objects.stackingOrder(nodes, in: state) where order.layer(of: node, in: state).map(searchable.contains) == true {
                let start = result.count
                walk(node)
                // A member of an already walked group is not listed twice.
                result = Array(result[..<start]) + result[start...].filter { seen.insert($0).inserted }
            }
        case .page, .document:
            for layer in order.layers where searchable.contains(layer.id) {
                order.objects(on: layer.id, in: state).forEach(walk)
            }
        }
        return result
    }

    /// The default bounds: the geometry bounds, a text block's frame through its transform, or
    /// else the object's origin in pasteboard space.
    public static func bounds(of node: OpID, in state: EngineState) -> Rect? {
        if let rect = Objects.bounds(of: node, in: state) { return rect }
        let transform = Objects.pasteboardTransform(of: node, in: state)
        if let text = state.textNode(node) {
            let block = text.props.block
            return Rect(x: 0, y: -block.height, width: block.width, height: block.height).applying(transform)
        }
        let origin = transform.apply(Point(x: 0, y: 0))
        return Rect(x: origin.x, y: origin.y, width: 0, height: 0)
    }
}

/// The per-node test of one criterion.
struct AttributeMatcher {
    let criterion: AttributeQuery.Criterion
    let state: EngineState
    let bounds: (OpID) -> Rect?
    /// `sameAs`: the reference object's look.
    let reference: Look?

    init(criterion: AttributeQuery.Criterion, state: EngineState, bounds: @escaping (OpID) -> Rect?) {
        self.criterion = criterion
        self.state = state
        self.bounds = bounds
        if case .sameAs(let node) = criterion { reference = Look(node, in: state) } else { reference = nil }
    }

    func matches(_ node: OpID) -> Bool {
        switch criterion {
        case .color(let color):
            return colors(node).contains { ColorMatching.same($0, color) }
        case .style(let style):
            return styles(node).contains(style)
        case .sameAs(let other):
            return node != other && reference.map { Look(node, in: state) == $0 } == true
        case .size(let width, let height):
            return bounds(node).map { width.contains($0.width) && height.contains($0.height) } ?? false
        case .fillType(let kind):
            return entries(node).contains { $0.kind == AttributeKind.fill(normalizing: kind) }
        case .strokeType(let kind):
            return entries(node).contains { $0.kind == AttributeKind.stroke(normalizing: kind) }
        case .strokeWidth(let range):
            return entries(node).contains { AttributeFields.width($0).map(range.contains) == true }
        case .font(let family, let style, let size):
            return textAttributes(node).contains { values in
                let resolved = TextLayoutReading.attributes(values)
                return Self.same(family, resolved.fontFamily) && Self.same(style, resolved.fontStyle) && size.contains(resolved.size)
            }
        case .textEffect(let kind):
            return textAttributes(node).contains { values in
                values.contains { value in
                    guard case .effect(let effect)? = value.value, let which = Self.kind(effect) else { return false }
                    return kind == nil || kind == which
                }
            }
        case .name(let text):
            // The name register alone, without reading the whole node (the design-point budget).
            let stored = state.register(node, RegisterPath([state.store.kind(node), 1, 1]))?.value.flatMap { WireReader.fields($0)?.last?.payload }
            return !text.isEmpty && String(decoding: stored ?? [], as: UTF8.self).lowercased().contains(text.lowercased())
        case .objectType(let type):
            return Self.type(of: node, in: state) == type
        case .pathShape(let sample):
            return sample.matches(node, in: state)
        case .halftone:
            return NodeValues.common(state.props(node)).map { $0.hasHalftone && $0.halftone != Wiretuner_Doc_V1_Halftone() } == true
        case .overprint:
            return entries(node).contains { entry in
                switch entry.kind {
                case .fill(.basic): entry.fill.settings.basic.overprint
                case .stroke(.basic): entry.stroke.settings.basic.overprint
                default: false
                }
            } || textAttributes(node).contains { $0.contains { if case .overprint(true)? = $0.value { true } else { false } } }
        }
    }

    /// The visible and hidden rows of the node's stack.
    func entries(_ node: OpID) -> [AttributeEntry] {
        AppearanceEditing.entries(node, in: state)
    }

    /// The winning mark values of each run of a text node; empty for anything else.
    func textAttributes(_ node: OpID) -> [[Wiretuner_Doc_V1_TextMarkValue]] {
        state.textNode(node)?.runs.map(\.values) ?? []
    }

    /// Every colour the node paints with: each row's colour and gradient stops, and its text's.
    func colors(_ node: OpID) -> [Wiretuner_Doc_V1_ColorRef] {
        var result: [Wiretuner_Doc_V1_ColorRef] = []
        for entry in entries(node) {
            if let color = AttributeFields.color(entry) { result.append(color) }
            if entry.kind == .fill(.gradient) { result += entry.fill.settings.gradient.stops.map(\.color) }
        }
        for values in textAttributes(node) {
            for value in values {
                if case .fill(let color)? = value.value { result.append(color) }
            }
        }
        return result
    }

    /// The graphic style and, on text, every paragraph and character style.
    func styles(_ node: OpID) -> Set<OpID> {
        var result: Set<OpID> = []
        if let common = NodeValues.common(state.props(node)), common.hasStyle { result.insert(OpID(common.style.id)) }
        if let text = state.textNode(node) {
            for paragraph in text.paragraphs where paragraph.props.hasStyle { result.insert(OpID(paragraph.props.style.id)) }
            for values in text.runs.map(\.values) {
                for value in values {
                    if case .style(let style)? = value.value { result.insert(OpID(style.id)) }
                }
            }
        }
        return result
    }

    /// Whether `wanted` (nil: any) names `actual`, ignoring case.
    static func same(_ wanted: String?, _ actual: String?) -> Bool {
        guard let wanted else { return true }
        return wanted.lowercased() == (actual ?? "").lowercased()
    }

    static func kind(_ effect: Wiretuner_Doc_V1_TextEffect) -> AttributeQuery.TextEffectKind? {
        switch effect.effect {
        case .highlight?: .highlight
        case .underline?: .underline
        case .strikethrough?: .strikethrough
        case .inline?: .inline
        case .shadow?: .shadow
        case .zoom?: .zoom
        case nil: nil
        }
    }

    static func type(of node: OpID, in state: EngineState) -> AttributeQuery.ObjectType? {
        switch state.store.kind(node) {
        case NodeKind.path.rawValue: state.liveElements(node, PathFields.contours).count > 1 ? .compositePath : .path
        case NodeKind.rect.rawValue: .rectangle
        case NodeKind.ellipse.rawValue: .ellipse
        case NodeKind.polygon.rawValue: .polygon
        case NodeKind.group.rawValue: state.props(node).group.kind == .clip ? .clippingPath : .group
        case NodeKind.blend.rawValue: .blend
        case NodeKind.text.rawValue: .textBlock
        case 170: .bitmap
        case NodeKind.placedFile.rawValue: .embeddedFile
        case 102: .envelope
        case NodeKind.extrude.rawValue: .extrusion
        case NodeKind.connector.rawValue: .connectorLine
        case NodeKind.instance.rawValue: .symbolInstance
        default: nil
        }
    }
}

/// The fills and strokes of an object with element ids (and nested ids) cleared: what *Same as
/// selection* and *Path shape* compare.
struct Look: Hashable {
    var fills: [Wiretuner_Doc_V1_Fill]
    var strokes: [Wiretuner_Doc_V1_Stroke]

    init?(_ node: OpID, in state: EngineState) {
        guard let appearance = StackOwner.appearance(node, in: state), StackOwner.of(node, in: state) != nil else { return nil }
        self.init(appearance)
    }

    init(_ appearance: Wiretuner_Doc_V1_AppearanceProps) {
        fills = appearance.fills.map { fill in
            var copy = fill
            copy.clearID()
            for index in copy.settings.gradient.stops.indices { copy.settings.gradient.stops[index].clearID() }
            return copy
        }
        strokes = appearance.strokes.map { stroke in
            var copy = stroke
            copy.clearID()
            return copy
        }
    }
}

/// Colour identity for the query: the same swatch, the same unnamed tint of the same swatch, or
/// an equal inline colour.
enum ColorMatching {
    static func same(_ a: Wiretuner_Doc_V1_ColorRef, _ b: Wiretuner_Doc_V1_ColorRef) -> Bool {
        switch (a.ref, b.ref) {
        case (.swatch(let x)?, .swatch(let y)?): x.id == y.id
        case (.tint(let x)?, .tint(let y)?): x.base.id == y.base.id && x.percent == y.percent
        case (.inline(let x)?, .inline(let y)?): x == y
        case (.none?, .none?), (nil, nil), (.none?, nil), (nil, .none?): true
        default: false
        }
    }
}

/// A *Path shape* sample (find-replace.adoc, "Path shape"): the outline of a path, rectangle,
/// ellipse or polygon in pasteboard space with its fills and strokes, from the native pasteboard
/// (*Paste In*) or from an object.
///
/// A candidate matches when it has the same number of contours, each with the same number of
/// points and the same closedness, whose anchors and handles in pasteboard space are the sample's
/// under one similarity -- a uniform scale, a rotation and a translation, no reflection -- to
/// within `tolerance` of the shape's size, and whose fills and strokes equal the sample's.  Points
/// are compared in stored drawing order (a copy keeps it).
public struct PathShape: Hashable, Sendable {
    /// Relative tolerance: the RMS misfit over the RMS radius of the candidate's points.
    public static let tolerance = 1e-3

    /// Per contour, its closedness and its points in pasteboard space as anchor, in control, out
    /// control.
    public var contours: [(closed: Bool, points: [Point])] { zip(closedness, points).map { ($0, $1) } }

    private var closedness: [Bool]
    private var points: [[Point]]
    var look: Look

    /// The sample `node` gives; nil for anything but a path, rectangle, ellipse or polygon.
    public init?(_ node: OpID, in state: EngineState) {
        guard state.isLive(node), let path = Objects.localPath(node, in: state), let look = Look(node, in: state) else { return nil }
        self.init(path, transform: Objects.pasteboardTransform(of: node, in: state), look: look)
    }

    /// The sample the first object of a clipboard payload gives (its transform is the pasteboard
    /// transform); nil when it is not a path, rectangle, ellipse or polygon.
    public init?(_ payload: ClipboardPayload) {
        guard let tree = payload.nodes.first else { return nil }
        let path: VectorPath
        switch tree.props.kind {
        case .path(let props)?: path = VectorPath(props)
        case .rect(let props)?: path = ShapeGeometry.path(props)
        case .ellipse(let props)?: path = ShapeGeometry.path(props)
        case .polygon(let props)?: path = ShapeGeometry.path(props)
        default: return nil
        }
        self.init(path, transform: tree.transform, look: Look(NodeValues.appearance(tree.props)!))
    }

    init(_ path: VectorPath, transform: AffineTransform, look: Look) {
        let renderable = path.contours.filter(\.isRenderable)
        closedness = renderable.map(\.closed)
        points = renderable.map { contour in
            contour.drawn.flatMap { [transform.apply($0.anchor), transform.apply($0.inControl), transform.apply($0.outControl)] }
        }
        self.look = look
    }

    /// Whether the object `node` has this shape, stroke and fill.
    public func matches(_ node: OpID, in state: EngineState) -> Bool {
        guard let candidate = PathShape(node, in: state), candidate.look == look else { return false }
        return similarity(to: candidate) != nil
    }

    /// The similarity mapping this shape's points onto `other`'s (pasteboard space), or nil when
    /// the shapes differ.  *Transform to fit original* (OBJ-023) places a replacement with
    /// `fit(_:into:)` over the matched object's bounds instead.
    public func similarity(to other: PathShape) -> AffineTransform? {
        guard closedness == other.closedness, points.map(\.count) == other.points.map(\.count) else { return nil }
        let z = points.flatMap { $0 }, w = other.points.flatMap { $0 }
        guard !z.isEmpty else { return nil }
        let n = Double(z.count)
        let zc = Point(x: z.map(\.x).reduce(0, +) / n, y: z.map(\.y).reduce(0, +) / n)
        let wc = Point(x: w.map(\.x).reduce(0, +) / n, y: w.map(\.y).reduce(0, +) / n)
        // The least-squares complex factor a = Σ conj(z)·w / Σ |z|² (scale and rotation).
        var re = 0.0, im = 0.0, zz = 0.0, ww = 0.0
        for (p, q) in zip(z, w) {
            let (zx, zy, wx, wy) = (p.x - zc.x, p.y - zc.y, q.x - wc.x, q.y - wc.y)
            re += zx * wx + zy * wy
            im += zx * wy - zy * wx
            zz += zx * zx + zy * zy
            ww += wx * wx + wy * wy
        }
        guard zz > 0, ww > 0 else { return zz == ww ? .translation(x: wc.x - zc.x, y: wc.y - zc.y) : nil }
        let (a, b) = (re / zz, im / zz)
        var misfit = 0.0
        for (p, q) in zip(z, w) {
            let (zx, zy) = (p.x - zc.x, p.y - zc.y)
            let (dx, dy) = (q.x - wc.x - (a * zx - b * zy), q.y - wc.y - (b * zx + a * zy))
            misfit += dx * dx + dy * dy
        }
        guard (misfit / ww).squareRoot() <= Self.tolerance else { return nil }
        return AffineTransform(a: a, b: b, c: -b, d: a, tx: wc.x - (a * zc.x - b * zc.y), ty: wc.y - (b * zc.x + a * zc.y))
    }

    /// *Transform to fit original*: the matrix scaling and moving `replacement` (a replacement's
    /// pasteboard bounds) onto `original` (the matched object's), each axis on its own; the
    /// identity for an empty replacement.
    public static func fit(_ replacement: Rect, into original: Rect) -> AffineTransform {
        guard replacement.width > 0, replacement.height > 0 else { return .identity }
        let sx = original.width / replacement.width, sy = original.height / replacement.height
        return AffineTransform(a: sx, b: 0, c: 0, d: sy, tx: original.minX - replacement.minX * sx, ty: original.minY - replacement.minY * sy)
    }
}
