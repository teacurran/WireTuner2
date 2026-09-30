import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// The Glyph menu over a selection (glyph-grid.adoc, "Acting on several glyphs"; glyph-editing.adoc,
// "Components"; FONT-008, FONT-010, FONT-012 rests): the Set Width / Side Bearing sheet's Set to,
// Add and Scale by, Build Accented Glyphs, Snap Components to Anchors, the outline clean-ups written
// into the artwork (Remove Overlaps, Correct Directions, Add Extrema), Round to Units over many
// glyphs, and the Select submenu's queries.  Each command is one change over the whole selection.

/// A horizontal metric the Set Width / Set Side Bearing sheet changes.
public enum GlyphMetric: Hashable, Sendable, CaseIterable {
    case width, left, right
}

/// What the sheet does to the metric of each glyph.
public enum GlyphMetricAdjustment: Hashable, Sendable {
    /// Every glyph gets the value.
    case set(Double)
    /// The value is added to each glyph's own.
    case add(Double)
    /// Each glyph's own value times the factor (the sheet's percentage / 100).
    case scale(Double)

    func applied(to value: Double) -> Double {
        switch self {
        case .set(let target): target
        case .add(let delta): value + delta
        case .scale(let factor): value * factor
        }
    }

    var isFinite: Bool {
        switch self {
        case .set(let value), .add(let value), .scale(let value): value.isFinite
        }
    }
}

/// menu:Glyph[Set Advance Width…], *Set Left Side Bearing…* and *Set Right Side Bearing…*: each
/// glyph's width set, or its artwork moved (left), or its width changed so the right bearing is the
/// result (right), in one change.  Glyphs without an outline have no bearings and are left alone by
/// the bearing forms.
public struct AdjustGlyphMetrics: Command {
    public var glyphs: [OpID]
    public var metric: GlyphMetric
    public var adjustment: GlyphMetricAdjustment

    public init(_ glyphs: [OpID], _ metric: GlyphMetric, _ adjustment: GlyphMetricAdjustment) {
        self.glyphs = glyphs
        self.metric = metric
        self.adjustment = adjustment
    }

    public var label: String {
        switch metric {
        case .width: GlyphEditing.label("Set width", count: glyphs.count)
        case .left: GlyphEditing.label("Set left side bearing", count: glyphs.count)
        case .right: GlyphEditing.label("Set right side bearing", count: glyphs.count)
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard adjustment.isFinite else { throw GlyphEditError.invalidValue(metric == .width ? "advance width" : "side bearing") }
        let index = GlyphIndex(state)
        let sources = metric == .width ? [:] : GlyphOutlines.sources(reachableFrom: glyphs, in: state, index: index)
        for id in glyphs {
            let glyph = try GlyphEditing.glyph(id, in: index)
            if metric == .width {
                let width = adjustment.applied(to: glyph.advanceWidth)
                try GlyphEditing.validate(width: width)
                if width != glyph.advanceWidth { builder.append(GlyphEditing.setWidth(id, width)) }
                continue
            }
            let metrics = GlyphMetrics(advanceWidth: glyph.advanceWidth, bounds: GlyphFlattener.outline(of: NodeID(id), sources: sources).bounds)
            guard metrics.bounds != nil else { continue }
            if metric == .left {
                let dx = adjustment.applied(to: metrics.leftSideBearing) - metrics.leftSideBearing
                if dx != 0 { GlyphEditing.transformArtwork(of: glyph, by: .translation(x: dx, y: 0), state: state, builder: &builder) }
            } else {
                let width = glyph.advanceWidth - metrics.rightSideBearing + adjustment.applied(to: metrics.rightSideBearing)
                try GlyphEditing.validate(width: width)
                if width != glyph.advanceWidth { builder.append(GlyphEditing.setWidth(id, width)) }
            }
        }
    }
}

// MARK: Components by anchors

enum GlyphAttachment {
    /// The transforms that attach `parts` in order: the first stays where it is (the base), and each
    /// later part whose mark anchor (`_top`) matches a base anchor (`top`) of the glyph itself or of
    /// a part placed before it moves so the two anchors meet, keeping its own scale and rotation.
    /// Parts with no matching pair keep their transform.
    static func snapped(_ parts: [(glyph: Glyph, transform: WTGeometry.AffineTransform)], own: [GlyphAnchorValue]) -> [WTGeometry.AffineTransform] {
        // Attachment points by name, glyph space: the glyph's own base anchors win; otherwise later
        // points (a mark stacked on a mark) replace earlier ones.
        var points: [String: Point] = [:]
        for anchor in own where anchor.role == .base && !anchor.isDuplicate { points[anchor.attachmentName] = anchor.position }
        let fixed = Set(points.keys)
        var result: [WTGeometry.AffineTransform] = []
        for (offset, part) in parts.enumerated() {
            var transform = part.transform
            if offset > 0 || !own.isEmpty,
               let mark = part.glyph.anchors.first(where: { $0.role == .mark && !$0.isDuplicate && points[$0.attachmentName] != nil }) {
                let placed = transform.apply(mark.position)
                let target = points[mark.attachmentName]!
                transform = transform.concatenating(.translation(x: target.x - placed.x, y: target.y - placed.y))
            }
            for anchor in part.glyph.anchors where anchor.role == .base && !anchor.isDuplicate && !fixed.contains(anchor.attachmentName) {
                points[anchor.attachmentName] = transform.apply(anchor.position)
            }
            result.append(transform)
        }
        return result
    }
}

/// menu:Glyph[Snap Components to Anchors]: every component of each glyph whose mark anchor matches a
/// base anchor of the glyph or of the component before it (the base letter, or a mark below) moves so
/// the anchors meet, one change.  "Snap components to anchors".
public struct SnapComponentsToAnchors: Command {
    public var glyphs: [OpID]
    public var label: String { "Snap components to anchors" }

    public init(_ glyphs: [OpID]) {
        self.glyphs = glyphs
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        for id in glyphs {
            let glyph = try GlyphEditing.glyph(id, in: index)
            let resolved = glyph.components.compactMap { component -> (GlyphComponent, Glyph)? in
                guard component.status == .resolved, let source = component.source.flatMap({ index[$0] }) else { return nil }
                return (component, source)
            }
            let snapped = GlyphAttachment.snapped(resolved.map { ($0.1, $0.0.transform) }, own: glyph.anchors)
            for ((component, _), transform) in zip(resolved, snapped) where transform != component.transform {
                try SetComponentTransform(component.id, of: id, to: transform).execute(&builder, state: state)
            }
        }
    }
}

/// menu:Glyph[Build Accented Glyphs]: each glyph whose character decomposes (canonically) into a base
/// letter and marks that are all glyphs of the font has its foreground artwork and components
/// replaced by components of those glyphs, placed by anchors, and takes the base's advance width, in
/// one change.  Glyphs that do not decompose, or whose parts are missing or would use the glyph
/// itself, are left alone (`parts(of:in:)` is nil for them).  "Build accented glyphs".
public struct BuildAccentedGlyphs: Command {
    public var glyphs: [OpID]
    public var label: String { glyphs.count == 1 ? "Build accented glyph" : "Build \(glyphs.count) accented glyphs" }

    public init(_ glyphs: [OpID]) {
        self.glyphs = glyphs
    }

    /// The glyphs `glyph` is built from: the base, then the marks; nil when it does not decompose
    /// into live glyphs.
    public static func parts(of glyph: Glyph, in index: GlyphIndex) -> [Glyph]? {
        guard let scalar = glyph.codepoints.first ?? GlyphNaming.codepoint(of: glyph.name), let character = Unicode.Scalar(scalar) else { return nil }
        let decomposed = String(character).decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
        guard decomposed.count >= 2 else { return nil }
        let parts = decomposed.compactMap { index.glyph(for: $0) }
        guard parts.count == decomposed.count, !parts.contains(where: { GlyphEditing.reaches($0.id, glyph.id, in: index) }) else { return nil }
        return parts
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let layers = LayerOrder(state)
        var sources: [NodeID: GlyphSource]?
        for id in glyphs {
            let glyph = try GlyphEditing.glyph(id, in: index)
            guard let parts = Self.parts(of: glyph, in: index) else { continue }
            let all = sources ?? GlyphOutlines.sources(in: state, index: index)
            sources = all
            for object in GlyphArtwork.objects(on: id, in: state) where layers.all[object.layer]?.printing ?? true {
                for node in object.objects { builder.append(Ops.setDeleted(node)) }
            }
            if !glyph.components.isEmpty { builder.append(Ops.elementDelete(id, glyph.components.map { GlyphFields.component($0.id) })) }
            let transforms = GlyphAttachment.snapped(parts.map { ($0, .identity) }, own: [])
            let placed = zip(parts, transforms).map { part, transform in
                (source: part.id, transform: transform, cached: GlyphOutlines.encode(GlyphFlattener.outline(of: NodeID(part.id), sources: all).path))
            }
            try GlyphEditing.insertComponents(into: id, placed, state: state, builder: &builder)
            if parts[0].advanceWidth != glyph.advanceWidth { builder.append(GlyphEditing.setWidth(id, parts[0].advanceWidth)) }
        }
    }
}

// MARK: Outline clean-ups

/// menu:Glyph[Remove Overlaps], *Correct Directions* and *Add Extrema*, written into the artwork
/// (glyph-grid.adoc, "Acting on several glyphs"): each glyph's foreground paths -- fills as drawn,
/// strokes expanded, transforms applied, components left alone -- are replaced by one black-filled
/// path of the result on the topmost foreground layer they used, in one change.  *Remove Overlaps*
/// merges them (the generator's union); *Correct Directions* turns outer contours one way and
/// counters the other; *Add Extrema* puts a point at every horizontal and vertical extreme.  A glyph
/// the operation would not change is left alone.
public struct RewriteGlyphOutlines: Command {
    public enum Operation: Hashable, Sendable, CaseIterable {
        case removeOverlaps, correctDirections, addExtrema

        public var title: String {
            switch self {
            case .removeOverlaps: "Remove Overlaps"
            case .correctDirections: "Correct Directions"
            case .addExtrema: "Add Extrema"
            }
        }
    }

    public var glyphs: [OpID]
    public var operation: Operation
    public var label: String { operation.title }

    public init(_ glyphs: [OpID], _ operation: Operation) {
        self.glyphs = glyphs
        self.operation = operation
    }

    /// The contours `operation` makes of `glyph`'s foreground artwork (glyph space, y down), and
    /// the objects it replaces; nil when there is nothing to rewrite or nothing would change.
    static func rewrite(_ glyph: Glyph, _ operation: Operation, in state: EngineState, layers: LayerOrder)
        -> (contours: [Contour], replaced: [OpID], layer: OpID)? {
        var shapes: [GlyphShape] = []
        var replaced: [OpID] = []
        var topmost: OpID?
        for (layer, nodes) in GlyphArtwork.objects(on: glyph.id, in: state) {
            guard let info = layers.all[layer], info.printing, info.role != .guides else { continue }
            let layerTransform = PathEditing.transform(state.props(layer).layer.common.transform)
            for node in nodes {
                let own = GlyphOutlines.shapes(of: node, parentTransform: layerTransform, state: state)
                // Only what reaches the font is rewritten: an open unstroked path stays as drawn.
                guard !GlyphFlattener.outline(of: GlyphSource(shapes: own), sources: [:], options: GlyphFlattener.Options(keepOverlaps: true)).path.isEmpty
                else { continue }
                shapes += own
                replaced.append(node)
                topmost = layer
            }
        }
        guard let topmost, !shapes.isEmpty else { return nil }
        let source = GlyphSource(shapes: shapes)
        let merged = GlyphFlattener.outline(of: source, sources: [:]).path.contours.filter { !$0.isEmpty }
        let drawn = GlyphFlattener.outline(of: source, sources: [:], options: GlyphFlattener.Options(keepOverlaps: true)).path.contours.filter { !$0.isEmpty }
        let contours: [Contour]
        switch operation {
        case .removeOverlaps:
            contours = merged
        case .correctDirections:
            // Positively wound outers in glyph space, as the union leaves them (the generator
            // turns them for the font after its y flip).
            contours = GlyphContours.correctingDirections(drawn, outer: .counterClockwise)
            guard contours != drawn else { return nil }
        case .addExtrema:
            contours = GlyphContours.addingExtrema(drawn)
            guard contours != drawn else { return nil }
        }
        return (contours, replaced, topmost)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let index = GlyphIndex(state)
        let layers = LayerOrder(state)
        for id in glyphs {
            let glyph = try GlyphEditing.glyph(id, in: index)
            guard let rewrite = Self.rewrite(glyph, operation, in: state, layers: layers) else { continue }
            let last = state.store.children(rewrite.layer).last.flatMap { state.store.placement($0)?.position }
            for node in rewrite.replaced { builder.append(Ops.setDeleted(node)) }
            guard !rewrite.contours.isEmpty else { continue }
            let key = try PathEditing.keys(between: last, and: nil, count: 1)[0]
            try GlyphPaths.create(rewrite.contours, parent: rewrite.layer, position: key, canvas: id, builder: &builder)
        }
    }
}

/// menu:Glyph[Round to Units] over the selection: `RoundGlyphPoints` for each glyph, one change.
public struct RoundGlyphsToUnits: Command {
    public var glyphs: [OpID]
    public var label: String { "Round to Units" }

    public init(_ glyphs: [OpID]) {
        self.glyphs = glyphs
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for glyph in glyphs { try RoundGlyphPoints(glyph).execute(&builder, state: state) }
    }
}

// MARK: Select

/// menu:Glyph[Select] (glyph-grid.adoc, "Selecting glyphs"): which glyphs each item selects.
public enum GlyphSelectionQuery: Hashable, Sendable, CaseIterable {
    case withOutlines, empty, encoded, unencoded, withProblems, usingSelectedAsComponent, sameMarkColor

    public var title: String {
        switch self {
        case .withOutlines: "Glyphs with Outlines"
        case .empty: "Empty Glyphs"
        case .encoded: "Encoded"
        case .unencoded: "Unencoded"
        case .withProblems: "Glyphs with Problems"
        case .usingSelectedAsComponent: "Glyphs Using Selected as Component"
        case .sameMarkColor: "Same Mark Color"
        }
    }

    /// Whether the item needs a selection to act on.
    public var needsSelection: Bool { self == .usingSelectedAsComponent || self == .sameMarkColor }

    /// The glyphs the item selects, in grid order.  `selected` is the current selection.
    public func glyphs(selected: [OpID], in state: EngineState) -> [OpID] {
        let index = GlyphIndex(state)
        switch self {
        case .encoded:
            return index.glyphs.filter { !$0.codepoints.isEmpty }.map(\.id)
        case .unencoded:
            return index.glyphs.filter { $0.codepoints.isEmpty }.map(\.id)
        case .withOutlines, .empty:
            let outlines = GlyphFlattener.outlines(GlyphOutlines.sources(in: state, index: index))
            let drawn = Set(outlines.filter { !$0.value.path.isEmpty }.map { OpID($0.key) })
            return index.glyphs.filter { drawn.contains($0.id) == (self == .withOutlines) }.map(\.id)
        case .withProblems:
            let flagged = Set(FontValidation.problems(in: state, index: index).compactMap(\.glyph))
            return index.glyphs.filter { flagged.contains($0.id) }.map(\.id)
        case .usingSelectedAsComponent:
            let chosen = Set(selected)
            return index.glyphs.filter { glyph in glyph.components.contains { $0.source.map(chosen.contains) ?? false } }.map(\.id)
        case .sameMarkColor:
            let colors = Set(selected.compactMap { index[$0]?.markColor })
            return index.glyphs.filter { colors.contains($0.markColor) }.map(\.id)
        }
    }
}

// MARK: Components on the canvas

/// A component as a glyph canvas draws and hit-tests it (glyph-editing.adoc, "Components").
public struct PlacedComponent: Hashable, Sendable, Identifiable {
    public var id: OpID
    /// The source glyph, nil once removed.
    public var source: OpID?
    public var status: GlyphComponent.Status
    public var transform: WTGeometry.AffineTransform
    /// The source's flattened outline placed in glyph space (the cached outline of a removed
    /// source; empty for a component cut from a loop).
    public var outline: FilledPath
    /// The source glyph's name, or its last name for a removed one ("loop" for a cut one).
    public var name: String

    /// Whether the canvas draws it as a hatched placeholder.
    public var isPlaceholder: Bool { status != .resolved }

    /// Where it is drawn and hit: the outline's bounds, or a small box at its origin when there
    /// is no outline.
    public var bounds: Rect {
        if !outline.isEmpty { return outline.bounds }
        let origin = transform.apply(Point.zero)
        return Rect(x: origin.x, y: origin.y - 100, width: 100, height: 100)
    }
}

extension GlyphOutlines {
    /// The flattener input of `glyphs` and every glyph their components reach (not the whole font).
    public static func sources(reachableFrom glyphs: [OpID], in state: EngineState, index: GlyphIndex? = nil) -> [NodeID: GlyphSource] {
        let index = index ?? GlyphIndex(state)
        let layers = LayerOrder(state)
        var result: [NodeID: GlyphSource] = [:]
        var pending = glyphs
        while let id = pending.popLast() {
            guard result[NodeID(id)] == nil, let glyph = index[id] else { continue }
            result[NodeID(id)] = source(of: glyph, objects: GlyphArtwork.objects(on: id, in: state), layers: layers, state: state)
            pending += glyph.components.filter { $0.status == .resolved }.compactMap(\.source)
        }
        return result
    }

    /// The flattened outline of `glyph`, reading only the glyphs it reaches.
    public static func reachableOutline(of glyph: OpID, in state: EngineState, index: GlyphIndex? = nil) -> GlyphOutline {
        GlyphFlattener.outline(of: NodeID(glyph), sources: sources(reachableFrom: [glyph], in: state, index: index))
    }

    /// `glyph`'s components with their placed outlines, in element order (empty when it is not a
    /// live glyph).
    public static func placedComponents(of glyph: OpID, in state: EngineState, index: GlyphIndex? = nil) -> [PlacedComponent] {
        let index = index ?? GlyphIndex(state)
        guard let read = index[glyph], !read.components.isEmpty else { return [] }
        let sources = self.sources(reachableFrom: read.components.compactMap { $0.status == .resolved ? $0.source : nil }, in: state, index: index)
        return read.components.map { component in
            let outline: FilledPath
            let name: String
            switch component.status {
            case .resolved:
                outline = GlyphFlattener.outline(of: NodeID(component.source!), sources: sources).path.applying(component.transform)
                name = index[component.source!]?.name ?? ""
            case .dangling:
                outline = decode(component.cached).applying(component.transform)
                name = component.source.map { GlyphFields.lastName(of: $0, in: state) } ?? ""
            case .loop:
                outline = .empty
                name = "loop"
            }
            return PlacedComponent(id: component.id, source: component.source, status: component.status, transform: component.transform,
                                   outline: outline, name: name)
        }
    }
}

extension GlyphFields {
    /// The name a removed glyph last had (its stored name register), "" when unreadable.
    static func lastName(of glyph: OpID, in state: EngineState) -> String {
        guard state.store.kind(glyph) == kind else { return "" }
        return state.props(glyph).glyph.name
    }
}

// MARK: Mark attachment preview

/// menu:View[Show Mark Attachment] (glyph-editing.adoc, "Anchors"; FONT-013): which glyphs a glyph
/// canvas draws faintly, and where.  On a glyph with base anchors, every other glyph with a mark
/// anchor of the same attachment name, moved so the anchors meet; on a mark glyph (mark anchors
/// only), one sample base -- `a`, then `A`, then the first glyph with a matching base anchor --
/// moved so its base anchor meets the mark's.
public enum MarkAttachment {
    public struct Placement: Hashable, Sendable {
        /// The glyph drawn.
        public var glyph: OpID
        /// Where its outline goes (glyph-canvas space).
        public var offset: Vector
    }

    /// At most this many marks are drawn on one base.
    public static let limit = 64

    /// The glyphs to draw on `glyph`'s canvas; `anchors` replaces the glyph's own (an anchor being
    /// dragged).
    public static func placements(on glyph: OpID, anchors: [GlyphAnchorValue]? = nil, in index: GlyphIndex) -> [Placement] {
        guard let read = index[glyph] else { return [] }
        let own = (anchors ?? read.anchors).filter { !$0.isDuplicate }
        let bases = own.filter { $0.role == .base }
        if !bases.isEmpty {
            var result: [Placement] = []
            for other in index.glyphs where other.id != glyph && result.count < limit {
                for base in bases {
                    if let mark = other.anchors.first(where: { $0.role == .mark && !$0.isDuplicate && $0.attachmentName == base.attachmentName }) {
                        result.append(Placement(glyph: other.id, offset: base.position - mark.position))
                        break
                    }
                }
            }
            return result
        }
        let marks = own.filter { $0.role == .mark }
        guard !marks.isEmpty else { return [] }
        func pair(_ candidate: Glyph) -> Placement? {
            guard candidate.id != glyph else { return nil }
            for mark in marks {
                if let base = candidate.anchors.first(where: { $0.role == .base && !$0.isDuplicate && $0.attachmentName == mark.attachmentName }) {
                    return Placement(glyph: candidate.id, offset: mark.position - base.position)
                }
            }
            return nil
        }
        let preferred = ["a", "A"].compactMap { index.glyph(named: $0) }.lazy.compactMap(pair).first
        return (preferred ?? index.glyphs.lazy.compactMap(pair).first).map { [$0] } ?? []
    }
}
