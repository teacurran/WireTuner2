// The flattener (export-vector.adoc, "Client"; IO-017): one shared stage that takes a page of the
// export snapshot and a target's capabilities and returns a scene holding only what the target can
// carry.  In order:
//
// 1. Items whose drawing WTRender derives on read -- live vector effects, blends, extrusions,
//    envelopes, perspective, non-Basic strokes, arrowheads -- are expanded to the paths they
//    draw by `VectorCapture`.
// 2. Transparency, gradient masks and blur/shadow/glow that the target keeps live become groups
//    with an opacity, a soft mask or a filter around the item's flattened drawing.
// 3. Text becomes outlines where the target or the options require it.
// 4. What cannot be expressed -- sampled paints (Rectangle, Contour and Cone gradients, patterns,
//    textures, Custom and Tiled fills), lenses, raster effects the target has no filter for,
//    feathers -- is rendered to an image with alpha at the raster resolution.
// 5. For targets without transparency, `OpaqueCompositor` turns everything translucent into
//    opaque pieces or opaque images composited over what lies beneath.

import CoreGraphics
import Foundation
import WTGeometry
import WTRender
import enum WTRender.LineCap
import enum WTRender.LineJoin
import struct WTRender.StrokeStyle

/// What the flattener changed, for the export summary.
public struct FlattenReport: Sendable {
    /// Regions rendered to images, one line each.
    public var rasterized: [String] = []
    /// Items expanded to paths.
    public var expanded = 0
    /// Glyph runs converted to outlines.
    public var outlinedRuns = 0
    /// Translucent areas cut into opaque pieces (opaque targets).
    public var planarized = 0

    public init() {}

    /// Lines for `ExportSummary.notes`.
    public var notes: [String] {
        var result = rasterized
        if expanded > 0 {
            result.append("\(expanded) object\(expanded == 1 ? "" : "s") with live effects expanded to paths")
        }
        if outlinedRuns > 0 {
            result.append("\(outlinedRuns) text run\(outlinedRuns == 1 ? "" : "s") converted to outlines")
        }
        if planarized > 0 {
            result.append("\(planarized) transparent area\(planarized == 1 ? "" : "s") flattened into opaque pieces")
        }
        return result
    }
}

/// Reduces a page to what a target format can carry.
public struct Flattener: Sendable {
    public var target: FlattenTarget
    /// Pixels per inch for everything rendered to images.
    public var rasterResolution: Double
    /// Convert every glyph run to outlines even when the target keeps text.
    public var outlineText: Bool

    public init(target: FlattenTarget, rasterResolution: Double = 300, outlineText: Bool = false) {
        self.target = target
        self.rasterResolution = rasterResolution
        self.outlineText = outlineText
    }

    /// `page` flattened; `scene` supplies placed images.
    public func flatten(_ page: ExportPage, scene: ExportScene) -> (page: FlatPage, report: FlattenReport) {
        let run = FlattenRun(flattener: self, page: page, scene: scene)
        var nodes: [FlatNode] = []
        for (index, item) in page.displayList.items.enumerated() {
            guard let bounds = page.displayList.itemBounds[index], bounds.intersects(page.bounds) else {
                continue
            }
            nodes += run.flatten(item, at: [index])
        }
        if !target.contains(.transparency) {
            var compositor = OpaqueCompositor(page: page, rasterResolution: rasterResolution)
            nodes = compositor.composite(nodes)
            run.report.planarized += compositor.planarized
            run.report.rasterized += compositor.rasterized
        }
        return (FlatPage(bounds: page.bounds, background: page.background, nodes: nodes), run.report)
    }
}

/// One page's flattening.
final class FlattenRun {
    let flattener: Flattener
    let page: ExportPage
    let scene: ExportScene
    var report = FlattenReport()

    init(flattener: Flattener, page: ExportPage, scene: ExportScene) {
        self.flattener = flattener
        self.page = page
        self.scene = scene
    }

    var target: FlattenTarget { flattener.target }

    /// `item` at `indexPath`, tagged with its node when it has one.
    func flatten(_ item: DisplayItem, at indexPath: [Int]) -> [FlatNode] {
        let nodes: [FlatNode]
        if indexPath.count == 1, page.displayList.lensIndices.contains(indexPath[0]) {
            nodes = rasterWithBackdrop(through: indexPath[0], reason: "lens")
        } else {
            nodes = flattenContent(item, at: indexPath)
        }
        guard let node = page.nodeID(at: indexPath) else {
            return nodes
        }
        if nodes.count == 1, nodes[0].node == nil {
            return [nodes[0].tagged(node)]
        }
        return nodes.isEmpty ? [] : [.group(FlatGroup(children: nodes, node: node))]
    }

    private func flattenContent(_ item: DisplayItem, at indexPath: [Int]) -> [FlatNode] {
        switch item {
        case .fill(let fill):
            return flattenPath(PathItem(path: fill.path, appearance: Appearance([.fill(FillPaint(paint: fill.paint, rule: fill.rule))]), transform: fill.transform))
        case .stroke(let stroke):
            return flattenPath(PathItem(path: stroke.path, appearance: Appearance([.stroke(StrokePaint(paint: stroke.paint, style: stroke.style))]), transform: stroke.transform))
        case .path(let path):
            return flattenPath(path)
        case .image(let image):
            return flattenImage(image)
        case .text(let text):
            return flattenText(text)
        case .group(let group):
            return flattenGroup(group, at: indexPath)
        }
    }

    // MARK: Paths

    /// Whether a paint can be written as is (nil: it paints nothing).
    enum PaintResolution {
        case nothing
        case paint(FlatPaint)
        case unsupported
    }

    func resolve(_ paint: Paint, on path: DisplayPath) -> PaintResolution {
        if paint.isNone {
            return .nothing
        }
        switch paint {
        case .solid(let color):
            return .paint(.color(color))
        case .gradient(let gradient):
            guard target.contains(.gradients), let bounds = path.controlBounds, let flat = FlatGradient(gradient, bounds: bounds) else {
                return .unsupported
            }
            return .paint(.gradient(flat))
        default:
            return .unsupported
        }
    }

    func flattenPath(_ item: PathItem) -> [FlatNode] {
        if item.hasEffects {
            return flattenEffected(item)
        }
        var nodes: [FlatNode] = []
        for element in item.appearance.items {
            nodes += flattenElement(element, of: item)
        }
        return nodes
    }

    /// One fill or stroke of an item without effects.
    func flattenElement(_ element: AppearanceItem, of item: PathItem) -> [FlatNode] {
        let single = PathItem(path: item.path, appearance: Appearance([element]), transform: item.transform)
        switch element {
        case .fill(let fill):
            switch resolve(fill.paint, on: item.path) {
            case .nothing:
                return []
            case .paint(let paint):
                return [.path(FlatPath(path: item.path, transform: item.transform, paint: paint, style: .fill(fill.rule), overprint: fill.overprint))]
            case .unsupported:
                return raster([.path(single)], reason: "fill paint")
            }
        case .stroke(let stroke):
            let resolution = resolve(stroke.paint, on: item.path)
            if case .nothing = resolution {
                return []
            }
            if case .paint(let paint) = resolution, stroke.kind == .basic, !stroke.hasArrowheads, target.contains(.strokes) {
                var style = stroke.style
                style.dash = style.effectiveDash
                return [.path(FlatPath(path: item.path, transform: item.transform, paint: paint, style: .stroke(style), overprint: stroke.overprint))]
            }
            return expand([.path(single)], reason: "stroke")
        }
    }

    /// An item with live effects: effects the target keeps become groups around the plain
    /// drawing; vector effects are expanded; anything else is rendered.
    func flattenEffected(_ item: PathItem) -> [FlatNode] {
        let effects = item.appearance.effects.filter { element in
            guard !element.hidden, element.effect != .unsupported else { return false }
            if case .element(let index) = element.target {
                return item.appearance.items.indices.contains(index)
            }
            return true
        }
        if effects.contains(where: { $0.effect.isVector }) {
            if effects.allSatisfy({ $0.effect.isVector }) {
                return expand([.path(item)], reason: "live effect")
            }
            return raster([.path(item)], reason: "live effect")
        }
        var plain = item
        plain.appearance.effects = []
        var drawn: [FlatNode] = []
        for (index, element) in item.appearance.items.enumerated() {
            let attached = effects.filter { $0.target == .element(index) }.map(\.effect)
            guard let wrapped = wrap(flattenElement(element, of: plain), in: attached, frame: item.transform, region: item.path, rule: item.appearance.fills.first?.rule ?? .nonZero) else {
                return raster([.path(item)], reason: "raster effect")
            }
            drawn += wrapped
        }
        let object = effects.filter { $0.target == .object }.map(\.effect)
        guard let result = wrap(drawn, in: object, frame: item.transform, region: item.path, rule: item.appearance.fills.first?.rule ?? .nonZero) else {
            return raster([.path(item)], reason: "raster effect")
        }
        return result
    }

    /// `content` wrapped in a group per effect, first effect innermost; nil when an effect
    /// cannot be kept live by the target.
    func wrap(_ content: [FlatNode], in effects: [LiveEffect], frame: AffineTransform, region: DisplayPath, rule: FillRule) -> [FlatNode]? {
        var result = content
        for effect in effects where !result.isEmpty {
            switch effect {
            case .transparency(let transparency):
                switch transparency.style {
                case .basic:
                    let opacity = 1 - transparency.effectiveAmount / 100
                    if opacity < 1 {
                        result = [.group(FlatGroup(children: result, opacity: opacity))]
                    }
                case .gradientMask:
                    let stops = transparency.mask?.sortedStops ?? []
                    guard stops.count >= 2, let gradient = transparency.mask else {
                        let opacity = 1 - (stops.first.map { ColorMath.luminance(red: $0.color.red, green: $0.color.green, blue: $0.color.blue) } ?? 0)
                        if opacity < 1 {
                            result = [.group(FlatGroup(children: result, opacity: opacity))]
                        }
                        continue
                    }
                    guard target.contains(.softMasks), let regionBounds = region.controlBounds, let flat = FlatGradient(gradient, bounds: regionBounds),
                          let bounds = FlatNode.union(result.compactMap(\.bounds))
                    else {
                        return nil
                    }
                    result = [.group(FlatGroup(children: result, softMask: FlatSoftMask(gradient: flat, frame: frame, bounds: bounds)))]
                case .feather:
                    if transparency.effectiveRadius > 0 {
                        return nil
                    }
                }
            case .blur(let blur):
                guard blur.effectiveRadius > 0 else { continue }
                guard target.contains(.filters), blur.style == .gaussian else { return nil }
                result = [.group(FlatGroup(children: result, filter: .blur(sigma: blur.effectiveRadius)))]
            case .shadow(let shadow):
                guard shadow.effectiveOpacity > 0 else { continue }
                guard target.contains(.filters), let filter = FlattenRun.filter(for: shadow) else { return nil }
                result = [.group(FlatGroup(children: result, filter: filter))]
            case .bevelEmboss(let bevel):
                if bevel.effectiveWidth > 0 { return nil }
            case .sharpen(let sharpen):
                if sharpen.effectiveAmount > 0 { return nil }
            default:
                return nil
            }
        }
        return result
    }

    /// The SVG filter of a drop shadow or an outer glow (WTRender's raster filter geometry:
    /// σ = softness / 3, offset along `angle` measured with y up); nil for inner kinds.
    static func filter(for shadow: LiveEffect.Shadow) -> FlatFilter? {
        let color = shadow.color.withAlpha(multipliedBy: shadow.effectiveOpacity / 100)
        let sigma = shadow.effectiveSoftness / 3
        switch shadow.style {
        case .dropShadow:
            let angle = (shadow.angle.isFinite ? shadow.angle : 0) * .pi / 180
            return .dropShadow(dx: shadow.effectiveOffset * cos(angle), dy: -shadow.effectiveOffset * sin(angle), sigma: sigma, color: color)
        case .glow:
            return .glow(radius: shadow.effectiveOffset, sigma: sigma, color: color)
        case .innerShadow, .innerGlow:
            return nil
        }
    }

    // MARK: Images and text

    func flattenImage(_ image: ImageItem) -> [FlatNode] {
        if let asset = scene.assets[image.assetID] {
            return [.image(FlatImage(image: asset.image, rect: image.rect, transform: image.transform, jpegData: asset.jpegData))]
        }
        // The placeholder WTRender draws: a light grey block with dark grey diagonals.
        var diagonals = DisplayPath()
        diagonals.move(to: Point(x: image.rect.minX, y: image.rect.minY))
        diagonals.addLine(to: Point(x: image.rect.maxX, y: image.rect.maxY))
        diagonals.move(to: Point(x: image.rect.maxX, y: image.rect.minY))
        diagonals.addLine(to: Point(x: image.rect.minX, y: image.rect.maxY))
        return [
            .path(FlatPath(path: DisplayPath(rect: image.rect), transform: image.transform, paint: .color(Color(white: 0.75)))),
            .path(FlatPath(path: diagonals, transform: image.transform, paint: .color(Color(white: 0.45)), style: .stroke(StrokeStyle(width: 1)))),
        ]
    }

    func flattenText(_ text: TextRunItem) -> [FlatNode] {
        guard let run = text.glyphRun else {
            var baseline = DisplayPath()
            baseline.move(to: Point(x: text.bounds.minX, y: text.origin.y))
            baseline.addLine(to: Point(x: text.bounds.maxX, y: text.origin.y))
            return [
                .path(FlatPath(path: DisplayPath(rect: text.bounds), transform: text.transform, paint: .color(text.color.withAlpha(multipliedBy: 0.15)))),
                .path(FlatPath(path: baseline, transform: text.transform, paint: .color(text.color), style: .stroke(StrokeStyle(width: 1)))),
            ]
        }
        if target.contains(.text) && !flattener.outlineText {
            return [.text(FlatText(text: text.text, run: run, color: text.color, transform: text.transform))]
        }
        report.outlinedRuns += 1
        return [.path(FlatPath(path: run.outline, transform: text.transform, paint: .color(text.color)))]
    }

    // MARK: Groups

    func flattenGroup(_ group: GroupItem, at indexPath: [Int]) -> [FlatNode] {
        let clip = group.clip.map { FlatClip(path: $0, rule: group.clipRule, transform: group.transform) }
        if group.isDerived {
            if group.live == nil, !group.appearance.effects.contains(where: { $0.effect.isVector }), group.appearance.items.isEmpty {
                var plain = group
                plain.appearance = Appearance()
                let content = flattenGroup(plain, at: indexPath)
                let reference = FlatNode.union(group.children.compactMap(\.ownBounds)) ?? Rect.zero
                let effects = group.appearance.effects.filter { !$0.hidden && $0.target == .object }.map(\.effect)
                if let wrapped = wrap(content, in: effects, frame: .identity, region: DisplayPath(rect: reference), rule: .nonZero) {
                    return wrapped
                }
            }
            return expand([.group(group)], reason: "live group")
        }
        var children: [FlatNode] = []
        for (index, child) in group.children.enumerated() {
            children += flatten(child, at: indexPath + [index])
        }
        return [.group(FlatGroup(children: children, clip: clip, opacity: group.opacity))]
    }

    // MARK: Expansion and rasterization

    /// `items` as the paths WTRender draws for them, or rendered when that drawing is not plain
    /// vector artwork (a gradient-painted brush, say).
    func expand(_ items: [DisplayItem], reason: String) -> [FlatNode] {
        let region = DisplayList(canvas: "export", items: items).bounds
        if let region, let nodes = VectorCapture.capture(items, region: region.expanded(by: 1)) {
            report.expanded += 1
            return nodes
        }
        return raster(items, reason: reason)
    }

    /// `items` rendered to an image over their bounds (cropped to the page).
    func raster(_ items: [DisplayItem], reason: String) -> [FlatNode] {
        guard let bounds = DisplayList(canvas: "export", items: items).bounds,
              let image = RegionRasterizer.render(items, region: bounds.intersection(page.bounds.expanded(by: 1)), ppi: flattener.rasterResolution)
        else {
            return []
        }
        report.rasterized.append("\(reason) rendered at \(Numbers.format(flattener.rasterResolution, places: 0)) ppi")
        return [.image(image)]
    }

    /// A lens and everything beneath it rendered over the lens's bounds: a lens shows its
    /// backdrop, which only the whole canvas below it can supply.
    func rasterWithBackdrop(through index: Int, reason: String) -> [FlatNode] {
        let items = Array(page.displayList.items[0...index])
        guard let bounds = page.displayList.itemBounds[index],
              let image = RegionRasterizer.render(items, region: bounds.intersection(page.bounds.expanded(by: 1)), ppi: flattener.rasterResolution)
        else {
            return []
        }
        report.rasterized.append("\(reason) rendered at \(Numbers.format(flattener.rasterResolution, places: 0)) ppi")
        return [.image(image)]
    }
}
