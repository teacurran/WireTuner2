// FONT-015 (glyph flattener, opentype-features.adoc "Build tasks"; font-export.adoc "What happens
// to your artwork"): the objects on a glyph canvas, in stacking order, become one filled outline
// in glyph-canvas space.  Components are resolved recursively through their source glyphs (depth
// 8, the font-format limit; loops are cut by the model before this runs, and a revisit is refused
// here as well), fills contribute their closed contours, strokes are expanded to shapes with their
// joins and caps (GEO-003, the same `StrokeExpansion` the renderers fill), open contours with no
// stroke are dropped and reported, and everything is merged with a non-zero union (GEO-002)
// unless overlaps are kept.  Colours, gradients, effects and transparency are not read: a glyph
// is a shape.  Y negation, direction, extrema, rounding and quadratic conversion are the caller's
// (`GlyphContours`), since CFF and TrueType want different directions.

import WTGeometry

/// One object's geometry on a glyph canvas: its contours in its own space, placed by `transform`
/// (the object's transform chain into glyph space), with what paints it.
public struct GlyphShape: Hashable, Sendable {
    public var contours: [Contour]
    public var transform: AffineTransform
    public var fillRule: FillRule
    /// Whether any fill paints the shape (only closed contours fill).
    public var filled: Bool
    /// The strokes, bottom first; each is expanded to its outline.
    public var strokes: [StrokePaint]

    public init(contours: [Contour], transform: AffineTransform = .identity, fillRule: FillRule = .nonZero, filled: Bool = true,
                strokes: [StrokePaint] = []) {
        self.contours = contours
        self.transform = transform
        self.fillRule = fillRule
        self.filled = filled
        self.strokes = strokes
    }
}

/// A component as the flattener draws it: another glyph's outline, or a placeholder outline
/// (a dangling component's cached outline, or nothing for a cut loop).
public struct GlyphComponentPlacement: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case glyph(NodeID)
        /// Not resolved: drawn from `outline` (possibly empty), and reported.
        case placeholder(FilledPath)
    }

    public var source: Source
    /// Source glyph space → this glyph's space.
    public var transform: AffineTransform

    public init(source: Source, transform: AffineTransform = .identity) {
        self.source = source
        self.transform = transform
    }
}

/// Everything drawn on one glyph canvas.
public struct GlyphSource: Hashable, Sendable {
    public var shapes: [GlyphShape]
    public var components: [GlyphComponentPlacement]

    public init(shapes: [GlyphShape] = [], components: [GlyphComponentPlacement] = []) {
        self.shapes = shapes
        self.components = components
    }

    /// Whether the glyph has no artwork and no components.
    public var isEmpty: Bool { shapes.isEmpty && components.isEmpty }
}

/// What flattening left out or could not resolve (the Find Problems and validation inputs).
public struct GlyphFlatteningReport: Hashable, Sendable {
    /// Open contours with no stroke, skipped.
    public var droppedOpenContours = 0
    /// Components drawn as placeholders: dangling, cut loops, a source glyph unknown to the
    /// flattener, or nesting beyond `GlyphFlattener.maximumDepth`.
    public var placeholders = 0
    /// Whether a component chain reached the depth limit.
    public var depthExceeded = false
    /// Strokes that paint copies of artwork (Brush strokes) rather than a region, skipped.
    public var skippedStrokes = 0

    public init() {}

    mutating func absorb(_ other: GlyphFlatteningReport) {
        droppedOpenContours += other.droppedOpenContours
        placeholders += other.placeholders
        depthExceeded = depthExceeded || other.depthExceeded
        skippedStrokes += other.skippedStrokes
    }
}

/// A glyph's flattened outline.
public struct GlyphOutline: Hashable, Sendable {
    /// Non-zero filled, glyph-canvas space (y down).  After the union the contours do not cross:
    /// outer contours are positively wound, counters negatively.
    public var path: FilledPath
    public var report: GlyphFlatteningReport

    public init(path: FilledPath, report: GlyphFlatteningReport = GlyphFlatteningReport()) {
        self.path = path
        self.report = report
    }

    public static let empty = GlyphOutline(path: .empty)

    /// The outline's bounds, nil when empty.
    public var bounds: Rect? {
        path.isEmpty ? nil : path.bounds
    }
}

/// Flattens glyph artwork into outlines.
public enum GlyphFlattener {
    /// Deepest component nesting drawn; deeper components read as placeholders.
    public static let maximumDepth = 8
    /// Stroke expansion tolerance, font units.
    public static let tolerance = 1.0 / 64

    public struct Options: Hashable, Sendable {
        /// Keep the contours as drawn instead of unioning them (*Keep overlaps*).
        public var keepOverlaps: Bool

        public init(keepOverlaps: Bool = false) {
            self.keepOverlaps = keepOverlaps
        }
    }

    /// The outline of `glyph` from `sources` (every glyph a component may reach).
    public static func outline(of glyph: NodeID, sources: [NodeID: GlyphSource], options: Options = Options()) -> GlyphOutline {
        var memo: [Key: GlyphOutline] = [:]
        return outline(glyph, depth: 0, visiting: [], sources: sources, options: options, memo: &memo)
    }

    /// Every glyph's outline, sharing the component work.
    public static func outlines(_ sources: [NodeID: GlyphSource], options: Options = Options()) -> [NodeID: GlyphOutline] {
        var memo: [Key: GlyphOutline] = [:]
        var result: [NodeID: GlyphOutline] = [:]
        for glyph in sources.keys {
            result[glyph] = outline(glyph, depth: 0, visiting: [], sources: sources, options: options, memo: &memo)
        }
        return result
    }

    /// The outline of artwork that is not (yet) a glyph: a source whose components name glyphs
    /// in `sources`.
    public static func outline(of source: GlyphSource, sources: [NodeID: GlyphSource], options: Options = Options()) -> GlyphOutline {
        var memo: [Key: GlyphOutline] = [:]
        return flatten(source, depth: 0, visiting: [], sources: sources, options: options, memo: &memo)
    }

    private struct Key: Hashable {
        var glyph: NodeID
        var depth: Int
    }

    private static func outline(_ glyph: NodeID, depth: Int, visiting: Set<NodeID>, sources: [NodeID: GlyphSource], options: Options,
                                memo: inout [Key: GlyphOutline]) -> GlyphOutline {
        let key = Key(glyph: glyph, depth: depth)
        if let known = memo[key] { return known }
        guard let source = sources[glyph] else { return .empty }
        let result = flatten(source, depth: depth, visiting: visiting.union([glyph]), sources: sources, options: options, memo: &memo)
        memo[key] = result
        return result
    }

    private static func flatten(_ source: GlyphSource, depth: Int, visiting: Set<NodeID>, sources: [NodeID: GlyphSource], options: Options,
                                memo: inout [Key: GlyphOutline]) -> GlyphOutline {
        var report = GlyphFlatteningReport()
        var operands: [FilledPath] = []
        for shape in source.shapes {
            operands += paths(of: shape, report: &report)
        }
        for component in source.components {
            switch component.source {
            case .placeholder(let outline):
                report.placeholders += 1
                if !outline.isEmpty { operands.append(outline.applying(component.transform)) }
            case .glyph(let id):
                guard depth < maximumDepth, !visiting.contains(id), sources[id] != nil else {
                    report.placeholders += 1
                    report.depthExceeded = report.depthExceeded || depth >= maximumDepth
                    continue
                }
                let nested = outline(id, depth: depth + 1, visiting: visiting, sources: sources, options: options, memo: &memo)
                report.absorb(nested.report)
                if !nested.path.isEmpty { operands.append(nested.path.applying(component.transform)) }
            }
        }
        return GlyphOutline(path: combine(operands, keepOverlaps: options.keepOverlaps), report: report)
    }

    /// The filled regions of one shape in glyph space: its closed contours when filled, each
    /// stroke's outline, with open unstroked contours counted as dropped.
    static func paths(of shape: GlyphShape, report: inout GlyphFlatteningReport) -> [FilledPath] {
        let drawn = shape.contours.filter { !$0.isEmpty }
        var result: [FilledPath] = []
        let closed = drawn.filter(\.isClosed)
        if shape.filled, !closed.isEmpty {
            result.append(FilledPath(contours: closed, fillRule: shape.fillRule).applying(shape.transform))
        }
        if shape.strokes.isEmpty {
            report.droppedOpenContours += drawn.count - closed.count
        }
        let display = DisplayPath(contours: drawn)
        for stroke in shape.strokes {
            let regions = StrokeExpansion.regions(for: stroke, path: display, hairlineWidth: 1, tolerance: tolerance)
            if regions.isEmpty, !drawn.isEmpty { report.skippedStrokes += 1 }
            for region in regions {
                switch region {
                case .fill(let path, let rule, _):
                    result.append(FilledPath(contours: path.contours, fillRule: rule).applying(shape.transform))
                case .items:
                    report.skippedStrokes += 1
                }
            }
        }
        return result
    }

    /// `operands` merged into one non-zero path: their union, or with `keepOverlaps` each
    /// operand's own region redrawn without crossings, side by side.
    static func combine(_ operands: [FilledPath], keepOverlaps: Bool) -> FilledPath {
        let live = operands.filter { !$0.isEmpty }
        guard !live.isEmpty else { return .empty }
        if keepOverlaps {
            return FilledPath(contours: live.flatMap { $0.fillRule == .nonZero && $0.contours.count == 1 ? $0.contours : Boolean.normalize($0).contours })
        }
        return live.count == 1 ? Boolean.normalize(live[0]) : Boolean.union(live)
    }
}
