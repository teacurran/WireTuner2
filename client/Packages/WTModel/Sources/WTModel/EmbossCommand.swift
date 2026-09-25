import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// FX-034: the Emboss operation (path-effects.adoc, "Embossing"): highlight and shadow facets built
// as real paths around a closed shape's edges and grouped with it.  The kernel is here, in the
// package, so it runs anywhere the model does; the dialog is the app's.

/// The dialog's style buttons.
public enum EmbossStyle: String, CaseIterable, Hashable, Sendable {
    case emboss, deboss, chisel, ridge, quilt

    public var title: String { rawValue.capitalized }
}

/// The Emboss dialog's settings.
public struct EmbossSettings: Hashable, Sendable {
    public var style: EmbossStyle
    /// *Vary: Colors* (the two colour boxes) rather than *Contrast* (tints and shades of the
    /// object's own colour).
    public var varyColors: Bool
    public var highlight: Color
    public var shadow: Color
    /// Points, 1 ... 72.
    public var depth: Double
    /// The light direction, degrees counter-clockwise from the right (as on screen).
    public var angle: Double
    /// Emboss and Deboss: the relief blended in steps.
    public var softEdge: Bool

    public init(style: EmbossStyle = .emboss, varyColors: Bool = false, highlight: Color = .white, shadow: Color = .black, depth: Double = 4,
                angle: Double = 135, softEdge: Bool = false) {
        self.style = style
        self.varyColors = varyColors
        self.highlight = highlight
        self.shadow = shadow
        self.depth = depth
        self.angle = angle
        self.softEdge = softEdge
    }
}

/// One facet: a filled region (pasteboard space) in one colour.
public struct EmbossFacet: Hashable, Sendable {
    public var contours: [Contour]
    public var color: Color

    public init(contours: [Contour], color: Color) {
        self.contours = contours
        self.color = color
    }
}

/// The facet builder (path-effects.adoc, "Client": offsets of the outline along the light,
/// boolean differences for the lit and shaded bands, five style recipes, soft edge as stepped
/// facets).
public enum EmbossKernel {
    /// Whether `node` can be embossed: a closed path, rectangle, ellipse or polygon whose top fill
    /// is basic, gradient or pattern.
    public static func isEligible(_ node: OpID, in state: EngineState) -> Bool {
        guard let path = Objects.localPath(node, in: state), path.contours.contains(where: { $0.closed && $0.isRenderable }),
              let fill = NodeValues.appearance(state.props(node))?.fills.last else { return false }
        return [.basic, .unspecified, .gradient, .pattern].contains(fill.settings.kind)
    }

    /// The colour the facets start from: the top fill's colour, a gradient's first stop, else black.
    public static func baseColor(_ node: OpID, in state: EngineState) -> Color {
        guard let fill = NodeValues.appearance(state.props(node))?.fills.last else { return .black }
        let resolver = ColorResolver(state)
        switch fill.settings.kind {
        case .gradient:
            return GradientReading.ramp(fill.settings.gradient).first.flatMap { resolver.color($0.color) } ?? .black
        case .pattern:
            return resolver.color(fill.settings.pattern.color) ?? .black
        default:
            return resolver.color(fill.settings.basic.color) ?? .black
        }
    }

    /// `node`'s closed outline in pasteboard space.
    public static func shape(_ node: OpID, in state: EngineState) -> FilledPath {
        guard let path = Objects.localPath(node, in: state) else { return .empty }
        let transform = Objects.pasteboardTransform(of: node, in: state)
        let contours = path.contours.filter { $0.closed && $0.isRenderable }.map { vector in
            Contour(segments: vector.segments.map { $0.cubic.applying(transform) }, closed: true)
        }
        return FilledPath(contours: contours, fillRule: path.evenOdd ? .evenOdd : .nonZero)
    }

    /// The highlight and shadow colours for `base` (*Contrast*: a tint and a shade in process
    /// CMYK; *Colors*: the two boxes).
    public static func colors(base: Color, settings: EmbossSettings) -> (highlight: Color, shadow: Color) {
        settings.varyColors ? (settings.highlight, settings.shadow)
            : (CopiesBehind.mix(base, .white, amount: 0.6), CopiesBehind.mix(base, .black, amount: 0.5))
    }

    /// The facets of `shape` (bottom first).
    public static func facets(_ shape: FilledPath, base: Color, settings: EmbossSettings) -> [EmbossFacet] {
        guard !shape.isEmpty else { return [] }
        let depth = min(max(settings.depth, 1), 72)
        let radians = settings.angle * .pi / 180
        let light = Vector(dx: cos(radians), dy: -sin(radians))
        let (lit, shaded) = colors(base: base, settings: settings)
        func moved(_ path: FilledPath, _ distance: Double) -> FilledPath {
            path.applying(.translation(light * distance))
        }
        /// The crescents of `path` facing and facing away from the light, `distance` wide.
        func crescents(_ path: FilledPath, _ distance: Double) -> (toward: FilledPath, away: FilledPath) {
            (Boolean.subtracting(path, moved(path, -distance)), Boolean.subtracting(path, moved(path, distance)))
        }
        /// The band between `outer` and `inner`, split by the line through the centre across the light.
        func halves(_ outer: FilledPath, _ inner: FilledPath) -> (toward: FilledPath, away: FilledPath) {
            let band = Boolean.subtracting(outer, inner)
            let bounds = Self.bounds(outer) ?? Rect(x: 0, y: 0, width: 0, height: 0)
            let reach = max(bounds.width, bounds.height) * 2
            let across = Vector(dx: -light.dy, dy: light.dx)
            let c = bounds.center
            let towardHalf = FilledPath(Contour(polygon: [c + across * reach, c + across * reach + light * reach, c - across * reach + light * reach, c - across * reach]))
            return (Boolean.intersection(band, towardHalf), Boolean.subtracting(band, towardHalf))
        }
        var facets: [(FilledPath, Color)] = []
        switch settings.style {
        case .emboss, .deboss:
            let (up, down) = settings.style == .emboss ? (lit, shaded) : (shaded, lit)
            let steps = settings.softEdge ? max(2, Int((depth / 2).rounded())) : 1
            for step in (1...steps).reversed() {
                let fraction = Double(step) / Double(steps)
                let (toward, away) = crescents(shape, depth * fraction)
                let blend = 1 - fraction + 1 / Double(steps)
                facets.append((toward, CopiesBehind.mix(base, up, amount: min(blend, 1))))
                facets.append((away, CopiesBehind.mix(base, down, amount: min(blend, 1))))
            }
        case .chisel:
            let (toward, away) = halves(shape, Offset.inset(shape, by: depth))
            facets = [(toward, lit), (away, shaded)]
        case .ridge:
            let middle = Offset.inset(shape, by: depth / 2)
            let outer = halves(shape, middle)
            let inner = halves(middle, Offset.inset(shape, by: depth))
            facets = [(outer.toward, lit), (outer.away, shaded), (inner.toward, shaded), (inner.away, lit)]
        case .quilt:
            let outer = crescents(shape, depth / 2)
            let pillow = crescents(Offset.inset(shape, by: depth / 2), depth / 2)
            facets = [(outer.toward, shaded), (outer.away, lit), (pillow.toward, lit), (pillow.away, shaded)]
        }
        return facets.compactMap { path, color in
            let contours = path.contours.filter { !$0.segments.isEmpty }
            return contours.isEmpty ? nil : EmbossFacet(contours: contours, color: color)
        }
    }

    static func bounds(_ path: FilledPath) -> Rect? {
        let points = path.contours.flatMap { $0.segments.flatMap { [$0.p0, $0.p1, $0.p2, $0.p3] } }
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce(Rect(x: first.x, y: first.y, width: 0, height: 0)) { $0.union(Rect(x: $1.x, y: $1.y, width: 0, height: 0)) }
    }
}

/// Emboss's change: each object and its facets grouped in the object's place -- `CreateNode(group)`,
/// the object moved to its bottom, a basic-filled path per facet above it.  Labelled "Emboss".
public struct EmbossObjects: Command {
    public var objects: [(node: OpID, facets: [EmbossFacet])]
    public var label: String { "Emboss" }

    public init(_ objects: [(node: OpID, facets: [EmbossFacet])]) {
        self.objects = objects
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let lists = Dictionary(objects.map { ($0.node, $0.facets) }, uniquingKeysWith: { first, _ in first })
        for node in Objects.stackingOrder(Objects.editable(lists.keys.filter { Objects.isObject($0, in: state) }, in: state), in: state) {
            guard let facets = lists[node], !facets.isEmpty, let parent = Objects.parent(of: node, in: state) else { continue }
            let fromPasteboard = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
            var props = Wiretuner_Doc_V1_NodeProps()
            props.group.kind = .group
            let slot = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
            let group = builder.append(Ops.create(parent: parent, position: slot, props: props))
            let keys = try PathEditing.keys(between: nil, and: nil, count: facets.count + 1)
            builder.append(Ops.move(node, parent: group, position: keys[0]))
            for (facet, key) in zip(facets, keys.dropFirst()) {
                var path = Wiretuner_Doc_V1_NodeProps()
                path.path = Wiretuner_Doc_V1_PathProps()
                if !fromPasteboard.isIdentity { path.path.common.transform = PathEditing.proto(fromPasteboard) }
                let created = builder.append(Ops.create(parent: group, position: key, props: path))
                try CreatePath.appendContours(facet.contours.map(GlyphPaths.newContour), to: created, builder: &builder)
                var fill = Wiretuner_Doc_V1_Fill()
                fill.settings.kind = .basic
                fill.settings.basic.color = ColorResolver.inline(facet.color)
                var appearance = Wiretuner_Doc_V1_AppearanceProps()
                appearance.fills = [fill]
                for op in try PathEditing.appearanceInserts(created, kind: .path, appearancePath: PathFields.appearance, appearance) {
                    builder.append(op)
                }
            }
        }
    }
}
