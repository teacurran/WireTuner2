import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FONT-002 / FONT-015 (model side): glyph artwork read from the state as `WTRender.GlyphSource`s
// -- the objects on each glyph canvas on printing layers, each with its transform chain, fill
// rule, fills and strokes, and each glyph's components with the model's loop and dangling rules
// applied -- and the derived metrics: side bearings from the flattened outline's bounds, never
// stored (typeface-documents.adoc, "Derived, never stored").

/// A glyph's horizontal metrics as derived.
public struct GlyphMetrics: Hashable, Sendable {
    public var advanceWidth: Double
    /// Min x of the flattened outline; 0 without an outline.
    public var leftSideBearing: Double
    /// Advance width - max x; the advance width without an outline.
    public var rightSideBearing: Double
    /// The outline's bounds in glyph-canvas space, nil without one.
    public var bounds: Rect?

    public init(advanceWidth: Double, bounds: Rect?) {
        self.advanceWidth = advanceWidth
        self.bounds = bounds
        leftSideBearing = bounds?.minX ?? 0
        rightSideBearing = bounds.map { advanceWidth - $0.maxX } ?? advanceWidth
    }
}

/// Reading glyph artwork for flattening.
public enum GlyphOutlines {
    /// The flattener input of every live glyph.
    public static func sources(in state: EngineState, index: GlyphIndex? = nil) -> [NodeID: GlyphSource] {
        let index = index ?? GlyphIndex(state)
        let objects = GlyphArtwork.objectsByGlyph(in: state)
        let layers = LayerOrder(state)
        var result: [NodeID: GlyphSource] = [:]
        for glyph in index.glyphs {
            result[NodeID(glyph.id)] = source(of: glyph, objects: objects[glyph.id] ?? [], layers: layers, state: state)
        }
        return result
    }

    /// One glyph's flattener input: its shapes on printing layers, then its components.
    static func source(of glyph: Glyph, objects: [(layer: OpID, objects: [OpID])], layers: LayerOrder, state: EngineState) -> GlyphSource {
        var shapes: [GlyphShape] = []
        for (layer, nodes) in objects {
            guard let info = layers.all[layer], info.printing, info.role != .guides else { continue }
            let layerTransform = PathEditing.transform(state.props(layer).layer.common.transform)
            for node in nodes {
                shapes += self.shapes(of: node, parentTransform: layerTransform, state: state)
            }
        }
        let components = glyph.components.map { component -> GlyphComponentPlacement in
            switch component.status {
            case .resolved: GlyphComponentPlacement(source: .glyph(NodeID(component.source!)), transform: component.transform)
            case .dangling: GlyphComponentPlacement(source: .placeholder(decode(component.cached)), transform: component.transform)
            case .loop: GlyphComponentPlacement(source: .placeholder(.empty), transform: component.transform)
            }
        }
        return GlyphSource(shapes: shapes, components: components)
    }

    /// The shapes of `node` and, for a group, its members, placed by their transform chains.
    /// Kinds a glyph cannot hold (text, images, instances) contribute nothing.
    static func shapes(of node: OpID, parentTransform: WTGeometry.AffineTransform, state: EngineState) -> [GlyphShape] {
        let props = state.props(node)
        let transform = Objects.transform(of: node, in: state).concatenating(parentTransform)
        switch state.nodeKind(node) {
        case .group?:
            return state.liveChildren(node).flatMap { shapes(of: $0, parentTransform: transform, state: state) }
        case .path?, .rect?, .ellipse?, .polygon?:
            guard let path = Objects.localPath(node, in: state), path.isRenderable, let appearance = NodeValues.appearance(props) else { return [] }
            let display = DocumentDisplayListBuilder.display(path) { _ in true }.path
            let resolved = Appearances.resolve(appearance, order: AppearanceEditing.stack(node, in: state), evenOdd: path.evenOdd)
            var filled = false
            var strokes: [StrokePaint] = []
            for item in resolved.items {
                switch item {
                case .fill: filled = true
                case .stroke(let stroke): strokes.append(stroke)
                }
            }
            return [GlyphShape(contours: display.contours, transform: transform, fillRule: path.evenOdd ? .evenOdd : .nonZero, filled: filled,
                               strokes: strokes)]
        default:
            return []
        }
    }

    /// The flattened outline of `glyph`.
    public static func outline(of glyph: OpID, in state: EngineState, options: GlyphFlattener.Options = GlyphFlattener.Options()) -> GlyphOutline {
        GlyphFlattener.outline(of: NodeID(glyph), sources: sources(in: state), options: options)
    }

    /// Every live glyph's flattened outline.
    public static func outlines(in state: EngineState, options: GlyphFlattener.Options = GlyphFlattener.Options()) -> [OpID: GlyphOutline] {
        Dictionary(uniqueKeysWithValues: GlyphFlattener.outlines(sources(in: state), options: options).map { (OpID($0.key), $0.value) })
    }

    /// The derived metrics of `glyph` (nil when it is not a live glyph).
    public static func metrics(of glyph: OpID, in state: EngineState) -> GlyphMetrics? {
        guard let read = GlyphIndex(state)[glyph] else { return nil }
        return GlyphMetrics(advanceWidth: read.advanceWidth, bounds: outline(of: glyph, in: state).bounds)
    }

    // MARK: Cached outlines

    /// `path` in the compact encoding `NodeRef.cached` holds for a component (glyph-editing.adoc,
    /// "Source glyph deleted vs. use"): a version byte, then per contour a closed flag, the
    /// segment count, the start point and three points per segment, as little-endian Float32.
    public static func encode(_ path: FilledPath) -> Data {
        var out: [UInt8] = [1]
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out += $0 } }
        func put(_ point: Point) {
            put32(Float(point.x).bitPattern)
            put32(Float(point.y).bitPattern)
        }
        put32(UInt32(path.contours.count))
        for contour in path.contours {
            out.append(contour.isClosed ? 1 : 0)
            put32(UInt32(contour.segments.count))
            put(contour.segments.first?.p0 ?? .zero)
            for segment in contour.segments {
                put(segment.p1)
                put(segment.p2)
                put(segment.p3)
            }
        }
        return Data(out)
    }

    /// The path `encode` wrote; empty for data that does not parse.
    public static func decode(_ data: Data) -> FilledPath {
        let bytes = [UInt8](data)
        var position = 0
        func get32() -> UInt32? {
            guard position + 4 <= bytes.count else { return nil }
            defer { position += 4 }
            return bytes[position..<(position + 4)].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
        func point() -> Point? {
            guard let x = get32(), let y = get32() else { return nil }
            return Point(x: Double(Float(bitPattern: x)), y: Double(Float(bitPattern: y)))
        }
        guard bytes.first == 1 else { return .empty }
        position = 1
        guard let count = get32(), count <= 100_000 else { return .empty }
        var contours: [Contour] = []
        for _ in 0..<count {
            guard position < bytes.count else { return .empty }
            let closed = bytes[position] == 1
            position += 1
            guard let segments = get32(), segments <= 1_000_000, var current = point() else { return .empty }
            var list: [CubicBezier] = []
            for _ in 0..<segments {
                guard let p1 = point(), let p2 = point(), let p3 = point() else { return .empty }
                list.append(CubicBezier(current, p1, p2, p3))
                current = p3
            }
            contours.append(Contour(segments: list, closed: closed))
        }
        return FilledPath(contours: contours)
    }
}
