// The effect pipeline (FX-006; live-effects.adoc, "Client"): an effected item is resolved into
// *drawables* -- each fill or stroke with the effects attached to it -- and the object-level
// effects are applied over them.  Vector effects map outline geometry; raster effects and
// transparency wrap what has been drawn so far.  The result is a tree of `EffectNode`s in
// pasteboard space that both renderers draw: plain display items through their usual routes,
// transparency layers as groups, and raster and masked nodes through a device-aligned Core
// Graphics layer (the per-item fallback the Metal renderer composites as a texture).
//
// Order.  Effects apply in position order, attached effects before the object's own and a
// group's inherited effects after both.  Raster stages split a chain: every non-affine vector
// effect is applied to the geometry before any raster stage of its chain, and an affine one
// (Transform, Duet) that comes after a raster stage copies the rasterized result instead (the
// effects pages' deviation note).  Hidden effects, unknown kinds, effects attached to missing
// elements and a Combine anywhere but on a group are skipped.
//
// Caching.  Results are keyed by value -- the item's path, stack and transform -- in the same
// kind of memo the stroke outlines use, so an edit to one object recomputes only that object's
// chain and REND-004's invalidation needs no extra bookkeeping: the display list after the edit
// holds a different value for the edited item and the same values for every other.

import Foundation
import WTGeometry

/// A vector effect together with the space it works in.
struct FramedEffect: Hashable, Sendable {
    var effect: LiveEffect
    /// Item-local space → the space the effect works in: the identity for an item's own
    /// effects; for effects inherited from a group, the item's transform to pasteboard space.
    var toEffectSpace: AffineTransform
    /// The bounds centres are measured from, in effect space (the object's or the group's own).
    var reference: Rect
}

/// One raster operation of a raster stage.
enum RasterOperation: Hashable, Sendable {
    case bevelEmboss(LiveEffect.BevelEmboss)
    case blur(LiveEffect.Blur)
    case shadow(LiveEffect.Shadow)
    case sharpen(LiveEffect.Sharpen)
    /// Transparency's Feather.
    case feather(radius: Double, softness: Double)
}

/// Content rasterized and filtered at the raster resolution.
struct RasterNode: Hashable, Sendable {
    var operations: [RasterOperation]
    var content: [EffectNode]
    var settings: RasterSettings
}

/// Content multiplied by the inverse luminance of a gradient (Transparency's Gradient Mask).
struct MaskNode: Hashable, Sendable {
    var gradient: Gradient
    /// The gradient's space (the object's local space) → pasteboard.
    var frame: AffineTransform
    /// The object's own outline in the gradient's space: Auto size bounds and Contour distances.
    var region: DisplayPath
    var rule: FillRule
    var content: [EffectNode]
}

/// What an effected item draws, in pasteboard space.
indirect enum EffectNode: Hashable, Sendable {
    /// A plain item, drawn by the renderers' usual routes.
    case item(DisplayItem)
    /// Content composited at `opacity` (Basic transparency).
    case layer(opacity: Double, content: [EffectNode])
    case masked(MaskNode)
    case raster(RasterNode)

    /// A conservative pasteboard bound, raster spread included.
    var bounds: Rect? {
        switch self {
        case .item(let item):
            return item.bounds
        case .layer(_, let content):
            return EffectNode.union(content)
        case .masked(let mask):
            return EffectNode.union(mask.content)
        case .raster(let raster):
            return EffectNode.union(raster.content).map { $0.expanded(by: RasterEffectStage.spread(of: raster)) }
        }
    }

    static func union(_ nodes: [EffectNode]) -> Rect? {
        DisplayList.union(of: nodes.compactMap(\.bounds))
    }

    /// The node placed by `transform` (pasteboard → pasteboard): affine copies of a result.
    func transformed(by transform: AffineTransform) -> EffectNode {
        switch self {
        case .item(let item):
            return .item(item.transformed(by: transform))
        case .layer(let opacity, let content):
            return .layer(opacity: opacity, content: content.map { $0.transformed(by: transform) })
        case .masked(var mask):
            mask.frame = mask.frame.concatenating(transform)
            mask.content = mask.content.map { $0.transformed(by: transform) }
            return .masked(mask)
        case .raster(var raster):
            raster.content = raster.content.map { $0.transformed(by: transform) }
            return .raster(raster)
        }
    }

    /// Every plain item the node draws or rasterizes, for hit testing on effected geometry.
    var plainItems: [DisplayItem] {
        switch self {
        case .item(let item): return [item]
        case .layer(_, let content): return content.flatMap(\.plainItems)
        case .masked(let mask): return mask.content.flatMap(\.plainItems)
        case .raster(let raster): return raster.content.flatMap(\.plainItems)
        }
    }
}

/// A derived group's drawing: what each entry is and which child it stands for.
struct DerivedGroup: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        /// What is drawn (and hit) for this entry, in pasteboard space.
        var item: DisplayItem
        /// The child it stands for; nil for derived geometry (blend steps, extrusion sides, a
        /// Combine outline), which hits as the group itself.
        var origin: Int?
        /// Invisible entries are hit only with Subselect (the members under a Combine).
        var visible: Bool = true
    }

    var entries: [Entry]
    /// What the group draws: the visible entries with the group's own raster and transparency
    /// stages applied.
    var nodes: [EffectNode]
    /// The entries without the group's appearance effects, for Keyline.
    var keylineItems: [DisplayItem]
}

enum EffectPipeline {
    private static let pathCache = RenderCache<PathItem, [EffectNode]>(capacity: 8192)
    private static let groupCache = RenderCache<GroupItem, DerivedGroup>(capacity: 2048)

    /// Whether `item`'s chain is resolved and cached: what an edit recomputes is what is not.
    static func isResolved(_ item: PathItem) -> Bool {
        pathCache.contains(item)
    }

    /// Whether `group`'s drawing is resolved and cached.
    static func isResolved(_ group: GroupItem) -> Bool {
        groupCache.contains(group)
    }

    // MARK: Paths

    /// What an effected path item draws, bottom first.
    static func nodes(for item: PathItem) -> [EffectNode] {
        pathCache.value(for: item) {
            resolve(item)
        }
    }

    /// The tight bounds of an item's own path in its local space.
    static func ownBounds(_ path: DisplayPath) -> Rect {
        path.contours.bounds
    }

    private static func resolve(_ item: PathItem) -> [EffectNode] {
        let appearance = item.appearance
        let reference = ownBounds(item.path)
        let own = appearance.liveEffects
        func framed(_ element: EffectElement) -> FramedEffect {
            FramedEffect(effect: element.effect, toEffectSpace: .identity, reference: reference)
        }
        let objectChain = own.filter { $0.target == .object }.map(framed) + item.inheritedEffects
        let object = Chain(objectChain)
        var nodes: [EffectNode] = []
        let base = [EffectShape(contours: item.path.contours)]
        for (index, element) in appearance.items.enumerated() {
            let attached = Chain(own.filter { $0.target == .element(index) }.map(framed))
            var shapes = applyVector(attached.vector, to: base)
            shapes = applyVector(object.vector, to: shapes)
            var drawable = shapes.compactMap { shape -> EffectNode? in
                guard !shape.contours.isEmpty else { return nil }
                return .item(.path(PathItem(path: shape.path, appearance: Appearance([element.overridingRule(shape.rule)]), transform: item.transform)))
            }
            drawable = applyStages(attached.stages, to: drawable, item: item)
            drawable = applyCopies(attached.copies, to: drawable, transform: item.transform)
            nodes += drawable
        }
        nodes = applyStages(object.stages, to: nodes, item: item)
        return applyCopies(object.copies, to: nodes, transform: item.transform)
    }

    /// A chain split at its raster stages.
    struct Chain {
        /// Geometry effects, in order.
        var vector: [FramedEffect] = []
        /// Raster and transparency stages, in order.
        var stages: [LiveEffect] = []
        /// Affine effects after a stage: copies of the result.
        var copies: [FramedEffect] = []

        init(_ effects: [FramedEffect]) {
            for framed in effects {
                switch framed.effect {
                case .combine:
                    continue  // meaningful only on a group, handled there
                case .transform, .duet:
                    if stages.isEmpty {
                        vector.append(framed)
                    } else {
                        copies.append(framed)
                    }
                case _ where framed.effect.isVector:
                    vector.append(framed)
                default:
                    stages.append(framed.effect)
                }
            }
        }
    }

    // MARK: Vector effects

    static func applyVector(_ effects: [FramedEffect], to shapes: [EffectShape]) -> [EffectShape] {
        var result = shapes
        for framed in effects {
            let toSpace = framed.toEffectSpace
            let back = toSpace.inverted()
            let inSpace = toSpace.isIdentity || back == nil ? result : result.map { $0.applying(toSpace) }
            var output = kernel(framed.effect, shapes: inSpace, reference: framed.reference)
            if !toSpace.isIdentity, let back {
                output = output.map { $0.applying(back) }
            }
            result = output
        }
        return result
    }

    static func kernel(_ effect: LiveEffect, shapes: [EffectShape], reference: Rect) -> [EffectShape] {
        switch effect {
        case .bend(let settings): return BendKernel.apply(settings, to: shapes, reference: reference)
        case .duet(let settings): return DuetKernel.apply(settings, to: shapes, reference: reference)
        case .expandPath(let settings): return ExpandKernel.apply(settings, to: shapes)
        case .ragged(let settings): return RaggedKernel.apply(settings, to: shapes)
        case .sketch(let settings): return SketchKernel.apply(settings, to: shapes)
        case .transform(let settings): return TransformKernel.apply(settings, to: shapes, reference: reference)
        case .corners(let settings): return CornersKernel.apply(settings, to: shapes)
        case .combine, .bevelEmboss, .blur, .shadow, .sharpen, .transparency, .unsupported: return shapes
        }
    }

    /// The placements (pasteboard → pasteboard) an affine effect copies a result to.
    static func placements(_ framed: FramedEffect, transform: AffineTransform) -> [AffineTransform] {
        let local: [AffineTransform]
        switch framed.effect {
        case .transform(let settings): local = TransformKernel.copies(settings, reference: framed.reference)
        case .duet(let settings): local = DuetKernel.placements(settings, reference: framed.reference)
        default: local = [.identity]
        }
        // Effect space → pasteboard.
        guard let toEffect = framed.toEffectSpace.inverted(), let fromPasteboard = transform.inverted() else {
            return local
        }
        let effectToPasteboard = toEffect.concatenating(transform)
        let pasteboardToEffect = fromPasteboard.concatenating(framed.toEffectSpace)
        return local.map { pasteboardToEffect.concatenating($0).concatenating(effectToPasteboard) }
    }

    static func applyCopies(_ copies: [FramedEffect], to nodes: [EffectNode], transform: AffineTransform) -> [EffectNode] {
        var result = nodes
        for framed in copies {
            let placements = placements(framed, transform: transform)
            result = placements.flatMap { placement in result.map { $0.transformed(by: placement) } }
        }
        return result
    }

    // MARK: Raster and transparency stages

    static func applyStages(_ stages: [LiveEffect], to nodes: [EffectNode], item: PathItem) -> [EffectNode] {
        applyStages(stages, to: nodes, settings: item.appearance.raster, frame: item.transform, region: item.path, rule: item.appearance.fills.first?.rule ?? .nonZero)
    }

    static func applyStages(_ stages: [LiveEffect], to nodes: [EffectNode], settings: RasterSettings, frame: AffineTransform, region: DisplayPath, rule: FillRule) -> [EffectNode] {
        var result = nodes
        for stage in stages where !result.isEmpty {
            switch stage {
            case .transparency(let transparency):
                result = transparencyStage(transparency, content: result, settings: settings, frame: frame, region: region, rule: rule)
            case .bevelEmboss(let bevel) where bevel.effectiveWidth > 0:
                result = rasterStage(.bevelEmboss(bevel), content: result, settings: settings)
            case .blur(let blur) where blur.effectiveRadius > 0:
                result = rasterStage(.blur(blur), content: result, settings: settings)
            case .shadow(let shadow) where shadow.effectiveOpacity > 0:
                result = rasterStage(.shadow(shadow), content: result, settings: settings)
            case .sharpen(let sharpen) where sharpen.effectiveAmount > 0:
                result = rasterStage(.sharpen(sharpen), content: result, settings: settings)
            default:
                continue
            }
        }
        return result
    }

    static func transparencyStage(_ transparency: LiveEffect.Transparency, content: [EffectNode], settings: RasterSettings, frame: AffineTransform, region: DisplayPath, rule: FillRule) -> [EffectNode] {
        switch transparency.style {
        case .basic:
            let opacity = 1 - transparency.effectiveAmount / 100
            return opacity >= 1 ? content : [.layer(opacity: opacity, content: content)]
        case .feather:
            guard transparency.effectiveRadius > 0 else { return content }
            return rasterStage(.feather(radius: transparency.effectiveRadius, softness: transparency.effectiveSoftness), content: content, settings: settings)
        case .gradientMask:
            let stops = transparency.mask?.sortedStops ?? []
            guard stops.count >= 2, let gradient = transparency.mask else {
                // Fewer than two live stops: Basic at the single stop's luminance (or opaque).
                let opacity = 1 - (stops.first.map { TransparencyStage.luminance($0.color) } ?? 0)
                return opacity >= 1 ? content : [.layer(opacity: opacity, content: content)]
            }
            return [.masked(MaskNode(gradient: gradient, frame: frame, region: region, rule: rule, content: content))]
        }
    }

    /// Appends `operation` to a lone raster node, or wraps `content` in a new one.
    static func rasterStage(_ operation: RasterOperation, content: [EffectNode], settings: RasterSettings) -> [EffectNode] {
        if content.count == 1, case .raster(var raster) = content[0], raster.settings == settings {
            raster.operations.append(operation)
            return [.raster(raster)]
        }
        return [.raster(RasterNode(operations: [operation], content: content, settings: settings))]
    }

    // MARK: Groups

    /// What a derived group draws and how its entries hit.
    static func derived(_ group: GroupItem) -> DerivedGroup {
        groupCache.value(for: group) {
            resolve(group)
        }
    }

    private static func resolve(_ group: GroupItem) -> DerivedGroup {
        var entries: [DerivedGroup.Entry]
        switch group.live {
        case .none:
            entries = group.children.enumerated().map { DerivedGroup.Entry(item: $0.element, origin: $0.offset) }
        case .blend(let blend):
            entries = BlendResolver.entries(blend, children: group.children)
        case .extrude(let extrude):
            entries = ExtrudeResolver.entries(extrude, children: group.children)
        case .envelope(let envelope):
            entries = EnvelopeResolver.entries(envelope, children: group.children)
        case .perspective(let perspective):
            entries = PerspectiveResolver.entries(perspective, children: group.children)
        }
        let keyline = entries.filter(\.visible).map(\.item)
        let effects = group.appearance.liveEffects.filter { $0.target == .object }
        if let combine = effects.first(where: { if case .combine = $0.effect { return true } else { return false } }),
           case .combine(let settings) = combine.effect {
            let operands = entries.filter(\.visible).map { CombineResolver.outline(of: $0.item) }
            let combined = CombineKernel.combine(operands, operation: settings.operation)
            var appearance = group.appearance
            appearance.effects = appearance.effects.filter { if case .combine = $0.effect { return false } else { return true } }
            let outline = DisplayItem.path(PathItem(path: DisplayPath(contours: combined.contours), appearance: appearance))
            let members = entries.map { DerivedGroup.Entry(item: $0.item, origin: $0.origin, visible: false) }
            return DerivedGroup(entries: [DerivedGroup.Entry(item: outline, origin: nil)] + members, nodes: [.item(outline)], keylineItems: group.children)
        }
        // Without a Combine: the group's vector effects apply to each member, in pasteboard
        // space about the group's centre; its raster and transparency stages to the whole.
        let reference = DisplayList.union(of: entries.filter(\.visible).compactMap(\.item.geometricBounds)) ?? .null
        let chain = Chain(effects.map { FramedEffect(effect: $0.effect, toEffectSpace: .identity, reference: reference) })
        if !chain.vector.isEmpty {
            entries = entries.map { entry in
                var result = entry
                result.item = entry.item.inheriting(chain.vector)
                return result
            }
        }
        var nodes = entries.filter(\.visible).map { EffectNode.item($0.item) }
        nodes = applyStages(chain.stages, to: nodes, settings: group.appearance.raster, frame: .identity, region: DisplayPath(rect: reference.isNull ? .zero : reference), rule: .nonZero)
        nodes = applyCopies(chain.copies, to: nodes, transform: .identity)
        return DerivedGroup(entries: entries, nodes: nodes, keylineItems: keyline)
    }
}

extension AppearanceItem {
    /// The element with its fill rule replaced when an effect imposes one.
    func overridingRule(_ rule: FillRule?) -> AppearanceItem {
        guard let rule, case .fill(var fill) = self else {
            return self
        }
        fill.rule = rule
        return .fill(fill)
    }
}

extension DisplayItem {
    /// The item with `effects` (framed in pasteboard space) appended to what it inherits:
    /// paths directly, groups through their children, glyph runs and the legacy fill and stroke
    /// items as the paths they paint.  Images and placeholder text are left as they are.
    func inheriting(_ effects: [FramedEffect]) -> DisplayItem {
        func framed(for transform: AffineTransform) -> [FramedEffect] {
            effects.map { effect in
                var result = effect
                result.toEffectSpace = transform.concatenating(effect.toEffectSpace)
                return result
            }
        }
        switch self {
        case .path(var item):
            item.inheritedEffects += framed(for: item.transform)
            return .path(item)
        case .fill(let fill):
            return DisplayItem.path(PathItem(path: fill.path, appearance: Appearance([.fill(FillPaint(paint: fill.paint, rule: fill.rule))]), transform: fill.transform)).inheriting(effects)
        case .stroke(let stroke):
            return DisplayItem.path(PathItem(path: stroke.path, appearance: Appearance([.stroke(StrokePaint(paint: stroke.paint, style: stroke.style))]), transform: stroke.transform)).inheriting(effects)
        case .text(let text):
            guard let run = text.glyphRun else { return self }
            return DisplayItem.path(PathItem(path: run.outline, appearance: Appearance([.fill(FillPaint(paint: .solid(text.color)))]), transform: text.transform)).inheriting(effects)
        case .group(var group):
            group.children = group.children.map { $0.inheriting(effects) }
            return .group(group)
        case .image:
            return self
        }
    }
}
