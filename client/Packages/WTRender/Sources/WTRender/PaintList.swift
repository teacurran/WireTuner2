// The display list lowered to what the Metal renderer draws (REND-006): filled polygons in
// device pixels, each with a fill rule, a premultiplied colour and a blend mode; polygons
// covering a Core Graphics-rasterized paint texture; and nested groups composited through
// offscreen textures with a clip and an opacity.  The lowering mirrors `CoreGraphicsRenderer`'s
// drawing rules item for item -- attribute stacks bottom first, GEO-003 stroke outlines and
// arrowheads (ATTR-007), hairlines one device pixel from the CTM, view modes, overprint preview
// -- so the two renderers differ only in how a polygon becomes pixels, which is what REND-007
// compares.  Paints other than a solid colour (gradients, patterns, Custom, Textured, Tiled and
// Lens fills) are drawn by `PaintDrawing` into a bitmap aligned with the surface's pixels and
// composited through Metal's own coverage of the region: the per-item fallback the ATTR paint
// tasks allow, recorded in docs/spec/client.adoc.

import WTGeometry
import CoreGraphics

/// How a fill composites onto what is beneath it.
enum PaintBlend: Hashable, Sendable {
    /// Source over.
    case normal
    /// The multiply blend mode, for overprint preview.
    case multiply
}

/// One polygon fill.
struct PaintFill: Hashable, Sendable {
    var path: FlatPath
    var rule: FillRule
    /// Premultiplied, in the renderer's working space (`ColorManagement`).
    var color: SIMD4<Float>
    var blend: PaintBlend
}

/// Premultiplied RGBA8 pixels, row 0 at the top, in `colorSpace`: the working space for
/// textures the Metal renderer uploads as they are, sRGB for raster effect results.
struct TextureImage: Hashable, Sendable {
    var width: Int
    var height: Int
    var bytes: [UInt8]
    var colorSpace: CGColorSpace = CoreGraphicsRenderer.colorSpace
}

/// One polygon fill whose colour comes from a texture placed at `origin` (device pixels).
struct PaintTexture: Hashable, Sendable {
    var path: FlatPath
    var rule: FillRule
    var image: TextureImage
    var origin: SIMD2<Int32>
    /// A fast-mode group's alpha, applied to the whole texture.
    var alpha: Float
    var blend: PaintBlend
}

/// Children drawn into their own surface, then composited through `clip` at `opacity`.
struct PaintGroup: Hashable, Sendable {
    var operations: [PaintOperation]
    var clip: FlatPath?
    var clipRule: FillRule
    var opacity: Double
}

/// One lowered drawing operation.
indirect enum PaintOperation: Hashable, Sendable {
    case fill(PaintFill)
    case texture(PaintTexture)
    case group(PaintGroup)
}

/// Lowers a display list for one surface (a tile or a view) to paint operations.
struct PaintListBuilder: Sendable {
    private(set) var viewMode: ViewMode
    let overprintPreview: Bool
    let flattener: PathFlattener
    /// Draws paint textures exactly as the reference renderer draws those paints.
    private(set) var reference: CoreGraphicsRenderer
    /// Debug switch for REND-007's self-test: every declared fill rule is swapped (non-zero
    /// for even-odd and back), which must fail exactly the tiles the rule matters in.
    let swapsFillRules: Bool
    /// As `CoreGraphicsRenderer.greekTypeBelow`.
    let greekTypeBelow: Double
    /// The surface in device pixels; geometry is clipped to it (with a margin) before it is
    /// handed to the GPU.
    private let clipBounds: Rect
    private let surface: Rect

    init(
        viewMode: ViewMode,
        overprintPreview: Bool,
        tolerance: FlatteningTolerance,
        surface: Rect,
        swapsFillRules: Bool = false,
        referenceTolerance: FlatteningTolerance = .standard,
        rasterPreview: RasterPreview = .screen,
        rasterEffectsReady: (@Sendable (Rect) -> Void)? = nil,
        greekTypeBelow: Double = 0,
        colorManagement: ColorManagement = .standard,
        imageStore: ImageStore? = nil
    ) {
        self.greekTypeBelow = greekTypeBelow
        self.viewMode = viewMode
        self.overprintPreview = overprintPreview
        flattener = PathFlattener(tolerance: tolerance)
        var reference = CoreGraphicsRenderer(flatteningTolerance: referenceTolerance, viewMode: viewMode, overprintPreview: overprintPreview)
        reference.rasterPreview = rasterPreview
        reference.rasterEffectsReady = rasterEffectsReady
        reference.greekTypeBelow = greekTypeBelow
        reference.colorManagement = colorManagement
        reference.imageStore = imageStore
        self.reference = reference
        self.swapsFillRules = swapsFillRules
        self.surface = surface
        clipBounds = surface.expanded(by: 64)
    }

    /// Inherited down the group tree, as in the Core Graphics renderer.
    private struct State {
        var alpha: Double = 1
        var highlight: Color = .black
        /// The canvas and the item's index path in it (lens backdrops); nil in nested content.
        var canvas: DisplayList?
        var indexPath: [Int] = []
        /// Canvas (pasteboard) space → device pixels.
        var canvasToDevice: AffineTransform = .identity
    }

    /// The operations drawing the items of `displayList` that intersect `cull` (pasteboard),
    /// mapped through `pasteboardTransform` (pasteboard → device pixels).
    func operations(for displayList: DisplayList, pasteboardTransform: AffineTransform, cull: Rect) -> [PaintOperation] {
        var result: [PaintOperation] = []
        for run in displayList.layerRuns(displayList.indices(intersecting: cull)) {
            guard let span = run.span else {
                for index in run.indices {
                    let state = State(canvas: displayList, indexPath: [index], canvasToDevice: pasteboardTransform)
                    lower(displayList.items[index], base: pasteboardTransform, state: state, cull: cull, into: &result)
                }
                continue
            }
            lowerLayer(span.layer, indices: run.indices, of: displayList, pasteboardTransform: pasteboardTransform, cull: cull, into: &result)
        }
        return result
    }

    /// As `CoreGraphicsRenderer.drawLayer`: a keyline layer or guides lowered in Keyline, the
    /// layer highlight inherited, a background layer composited at 50% as one group.
    private func lowerLayer(_ layer: LayerRendering, indices: [Int], of displayList: DisplayList, pasteboardTransform: AffineTransform, cull: Rect, into result: inout [PaintOperation]) {
        var builder = self
        if layer.forcesKeyline && !viewMode.isKeyline {
            let mode: ViewMode = viewMode.isFast ? .fastKeyline : .keyline
            builder.viewMode = mode
            builder.reference.viewMode = mode
        }
        let translucent = layer.opacity < 1
        let layered = translucent && builder.viewMode.drawsTransparencyGroups
        var children: [PaintOperation] = []
        for index in indices {
            var state = State(canvas: displayList, indexPath: [index], canvasToDevice: pasteboardTransform)
            state.highlight = layer.highlight
            if translucent && !layered && !builder.viewMode.isKeyline {
                state.alpha = layer.opacity
            }
            builder.lower(displayList.items[index], base: pasteboardTransform, state: state, cull: cull, into: &children)
        }
        if layered {
            if !children.isEmpty {
                result.append(.group(PaintGroup(operations: children, clip: nil, clipRule: .nonZero, opacity: layer.opacity)))
            }
        } else {
            result.append(contentsOf: children)
        }
    }

    // MARK: Items

    private func lower(_ item: DisplayItem, base: AffineTransform, state: State, cull: Rect, into result: inout [PaintOperation]) {
        if viewMode.isKeyline {
            lowerKeyline(item, base: base, state: state, cull: cull, into: &result)
            return
        }
        switch item {
        case .fill(let fill):
            let transform = fill.transform.concatenating(base)
            addRegions([.fill(fill.path, fill.rule, fill.paint)], path: fill.path, rule: fill.rule, transform: transform, blend: .normal, state: state, cull: cull, into: &result)
        case .stroke(let stroke):
            let transform = stroke.transform.concatenating(base)
            let regions = strokeRegions(StrokePaint(paint: stroke.paint, style: stroke.style), path: stroke.path, transform: transform)
            addRegions(regions, path: stroke.path, rule: .nonZero, transform: transform, blend: .normal, state: state, cull: cull, into: &result)
        case .path(let path):
            if path.hasEffects {
                lowerNodes(EffectPipeline.nodes(for: path), base: base, state: state, cull: cull, into: &result)
            } else {
                lowerPath(path, base: base, state: state, cull: cull, into: &result)
            }
        case .image(let image):
            let transform = image.transform.concatenating(base)
            if viewMode.drawsImagesAsBoxes {
                addImageBox(image, transform: transform, color: Color(white: 0.45), lineWidth: nil, state: state, into: &result)
            } else if reference.imageStore != nil {
                addReferenceTexture(item, region: DisplayPath(rect: image.visibleRect), transform: transform, base: base, state: state, into: &result)
            } else if let fallback = image.fallback {
                // With a store, the reference texture above draws the fallback when the pixels
                // are not there; it lies inside the visible frame.
                lower(fallback.transformed(by: image.transform), base: base, state: state, cull: cull, into: &result)
            } else {
                addFill(DisplayPath(rect: image.visibleRect), transform: transform, rule: .nonZero, color: Color(white: 0.75), state: state, into: &result)
                addImageBox(image, transform: transform, color: Color(white: 0.45), lineWidth: 1, state: state, into: &result)
                // With a store the reference texture carries the glyph (the Core Graphics drawing).
                if image.showsPlayGlyph {
                    let glyph = ImageDrawing.playGlyph(image)
                    addFill(glyph.disc, transform: transform, rule: .nonZero, color: ImageDrawing.playDisc, state: state, into: &result)
                    addFill(glyph.triangle, transform: transform, rule: .nonZero, color: ImageDrawing.playTriangle, state: state, into: &result)
                }
            }
        case .text(let text):
            let transform = text.transform.concatenating(base)
            if shouldGreek(text, base: base) {
                addFill(DisplayPath(rect: text.bounds), transform: transform, rule: .nonZero, color: Color(white: 0.7), state: state, into: &result)
            } else if let run = text.glyphRun {
                addFill(run.outline, transform: transform, rule: .nonZero, color: text.color, blend: blend(text.overprint), declaredRule: false, state: state, into: &result)
            } else {
                addFill(DisplayPath(rect: text.bounds), transform: transform, rule: .nonZero, color: text.color.withAlpha(multipliedBy: 0.15), state: state, into: &result)
                var baseline = DisplayPath()
                baseline.move(to: Point(x: text.bounds.minX, y: text.origin.y))
                baseline.addLine(to: Point(x: text.bounds.maxX, y: text.origin.y))
                addStroke(baseline, style: StrokeStyle(width: 1), transform: transform, color: text.color, state: state, into: &result)
            }
        case .group(let group):
            lowerGroup(group, base: base, state: state, cull: cull, into: &result)
        }
    }

    /// The attribute stack bottom first, each element as the regions it paints.
    private func lowerPath(_ item: PathItem, base: AffineTransform, state: State, cull: Rect, into result: inout [PaintOperation]) {
        let transform = item.transform.concatenating(base)
        for element in item.appearance.items {
            switch element {
            case .fill(let fill):
                addRegions([.fill(item.path, fill.rule, fill.paint)], path: item.path, rule: fill.rule, transform: transform, blend: blend(fill.overprint), state: state, cull: cull, into: &result)
            case .stroke(let stroke):
                addRegions(strokeRegions(stroke, path: item.path, transform: transform), path: item.path, rule: .nonZero, transform: transform, blend: blend(stroke.overprint), state: state, cull: cull, into: &result)
            }
        }
    }

    /// The regions a stroke paints at `transform`'s scale (local → device pixels).
    private func strokeRegions(_ stroke: StrokePaint, path: DisplayPath, transform: AffineTransform) -> [PaintedRegion] {
        StrokeExpansion.regions(
            for: stroke,
            path: path,
            hairlineWidth: PaintListBuilder.hairlineWidth(for: transform),
            tolerance: StrokeExpansion.tolerance(forScale: transform.scaleFactor)
        )
    }

    /// Solid regions as polygon fills, other paints as textures, brush copies as nested items
    /// (drawn in the item's local space, with no lens backdrop).
    private func addRegions(_ regions: [PaintedRegion], path: DisplayPath, rule: FillRule, transform: AffineTransform, blend: PaintBlend, state: State, cull: Rect, into result: inout [PaintOperation]) {
        for region in regions {
            switch region {
            case .fill(let shape, let shapeRule, let paint):
                if let color = paint.color {
                    let declared = shapeRule == rule && shape == path
                    addFill(shape, transform: transform, rule: shapeRule, color: color, blend: blend, declaredRule: declared, state: state, into: &result)
                } else if !paint.isNone {
                    addTexture(paint, region: shape, rule: shapeRule, path: path, pathRule: rule, transform: transform, blend: blend, state: state, into: &result)
                }
            case .items(let items):
                var nested = state
                nested.canvas = nil
                for item in items {
                    lower(item, base: transform, state: nested, cull: cull, into: &result)
                }
            }
        }
    }

    /// `paint` over `region`: the paint drawn by `PaintDrawing` into a bitmap covering the
    /// region's pixels on the surface, composited through Metal's coverage of the region.
    private func addTexture(_ paint: Paint, region: DisplayPath, rule: FillRule, path: DisplayPath, pathRule: FillRule, transform: AffineTransform, blend: PaintBlend, state: State, into result: inout [PaintOperation]) {
        let flat = flattener.flatten(region, transform: transform).clipped(to: clipBounds)
        guard let bounds = flat.bounds?.intersection(surface), !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let minX = Int(bounds.minX.rounded(.down))
        let minY = Int(bounds.minY.rounded(.down))
        let width = Int(bounds.maxX.rounded(.up)) - minX
        let height = Int(bounds.maxY.rounded(.up)) - minY
        guard let bitmap = BitmapSurface(width: width, height: height, colorSpace: reference.colorManagement.colorSpace) else {
            return
        }
        let context = bitmap.context
        // Device pixels (y down, origin at the surface's top-left) → this bitmap's y-up space.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(-minX), y: CGFloat(-minY))
        let deviceToBase = context.ctm
        context.concatenate(transform.cg)
        context.setFlatness(CGFloat(reference.flatteningTolerance.devicePixels))
        let environment = PaintEnvironment(
            renderer: reference,
            canvasToBase: state.canvasToDevice.cg.concatenating(deviceToBase),
            path: path,
            rule: pathRule,
            rasterScale: 1,
            canvas: state.canvas,
            indexPath: state.indexPath,
            lensDepth: 0
        )
        PaintDrawing.fill(paint, in: context, environment: environment)
        let rowBytes = context.bytesPerRow
        let source = context.data!.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<(width * 4) {
                bytes[row * width * 4 + column] = source[row * rowBytes + column]
            }
        }
        let effectiveRule = swapsFillRules && region == path && rule == pathRule ? (rule == .nonZero ? FillRule.evenOdd : .nonZero) : rule
        result.append(.texture(PaintTexture(
            path: flat,
            rule: effectiveRule,
            image: TextureImage(width: width, height: height, bytes: bytes, colorSpace: reference.colorManagement.colorSpace),
            origin: SIMD2(Int32(minX), Int32(minY)),
            alpha: Float(state.alpha),
            blend: blend
        )))
    }

    /// `item` (local → device `transform`, pasteboard → device `base`) drawn by the reference renderer into a bitmap over
    /// `region`'s pixels, composited through Metal's coverage of `region`: placed images, whose
    /// pixels Core Graphics resamples, draw exactly as the reference draws them.
    private func addReferenceTexture(_ item: DisplayItem, region: DisplayPath, transform: AffineTransform, base: AffineTransform, state: State, into result: inout [PaintOperation]) {
        let flat = flattener.flatten(region, transform: transform).clipped(to: clipBounds)
        guard let bounds = flat.bounds?.intersection(surface), !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let minX = Int(bounds.minX.rounded(.down))
        let minY = Int(bounds.minY.rounded(.down))
        let width = Int(bounds.maxX.rounded(.up)) - minX
        let height = Int(bounds.maxY.rounded(.up)) - minY
        guard let bitmap = BitmapSurface(width: width, height: height, colorSpace: reference.colorManagement.colorSpace) else {
            return
        }
        let context = bitmap.context
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(-minX), y: CGFloat(-minY))
        context.concatenate(base.cg)
        reference.drawNested([item], in: context)
        result.append(.texture(PaintTexture(
            path: flat,
            rule: .nonZero,
            image: TextureImage(surface: bitmap),
            origin: SIMD2(Int32(minX), Int32(minY)),
            alpha: Float(state.alpha),
            blend: .normal
        )))
    }

    private func lowerGroup(_ group: GroupItem, base: AffineTransform, state: State, cull: Rect, into result: inout [PaintOperation]) {
        var inner = state
        if let highlight = group.highlightColor {
            inner.highlight = highlight
        }
        let translucent = group.opacity < 1
        let layered = translucent && viewMode.drawsTransparencyGroups
        if layered {
            inner.alpha = 1  // a transparency layer starts at full alpha inside
        } else if translucent && !viewMode.isKeyline {
            inner.alpha = state.alpha * group.opacity
        }
        var children: [PaintOperation] = []
        if group.isDerived {
            var derivedState = inner
            derivedState.canvas = nil
            if viewMode.isKeyline {
                for item in EffectPipeline.derived(group).keylineItems where item.bounds?.intersects(cull) ?? false {
                    lower(item, base: base, state: derivedState, cull: cull, into: &children)
                }
            } else {
                lowerNodes(EffectPipeline.derived(group).nodes, base: base, state: derivedState, cull: cull, into: &children)
            }
        } else {
            for (index, child) in group.children.enumerated() {
                if let bounds = child.bounds, bounds.intersects(cull) {
                    var childState = inner
                    childState.indexPath = state.indexPath + [index]
                    lower(child, base: base, state: childState, cull: cull, into: &children)
                }
            }
        }
        let clip = group.clip.map { flattener.flatten($0, transform: group.transform.concatenating(base)).clipped(to: clipBounds) }
        guard clip != nil || layered else {
            result.append(contentsOf: children)
            return
        }
        result.append(.group(PaintGroup(operations: children, clip: clip, clipRule: group.clipRule, opacity: layered ? group.opacity : 1)))
    }

    // MARK: Effects

    /// Effect nodes (pasteboard space, `base` pasteboard → device pixels): plain items as
    /// usual, transparency layers as groups, raster and masked nodes as the reference
    /// renderer's device layer composited as a texture over its pixel rectangle.
    private func lowerNodes(_ nodes: [EffectNode], base: AffineTransform, state: State, cull: Rect, into result: inout [PaintOperation]) {
        for node in nodes {
            guard let bounds = node.bounds, bounds.intersects(cull) else {
                continue
            }
            switch node {
            case .item(let item):
                lower(item, base: base, state: state, cull: cull, into: &result)
            case .layer(let opacity, let content):
                var inner = state
                if viewMode.drawsTransparencyGroups {
                    inner.alpha = 1
                    var children: [PaintOperation] = []
                    lowerNodes(content, base: base, state: inner, cull: cull, into: &children)
                    if !children.isEmpty {
                        result.append(.group(PaintGroup(operations: children, clip: nil, clipRule: .nonZero, opacity: opacity)))
                    }
                } else {
                    inner.alpha = state.alpha * opacity
                    lowerNodes(content, base: base, state: inner, cull: cull, into: &result)
                }
            case .masked(let mask):
                if viewMode.drawsRasterEffects {
                    addLayer(node, bounds: bounds, base: base, state: state, into: &result)
                } else {
                    lowerNodes(mask.content, base: base, state: state, cull: cull, into: &result)
                }
            case .raster(let raster):
                if !viewMode.drawsRasterEffects {
                    lowerNodes(raster.content, base: base, state: state, cull: cull, into: &result)
                } else if reference.rasterPreview == .off {
                    lowerNodes(raster.content, base: base, state: state, cull: cull, into: &result)
                    if let badge = CoreGraphicsRenderer.badge(for: raster, pixelSize: PaintListBuilder.hairlineWidth(for: base)) {
                        addFill(badge, transform: base, rule: .nonZero, color: CoreGraphicsRenderer.badgeColor, declaredRule: false, state: state, into: &result)
                    }
                } else {
                    addLayer(node, bounds: bounds, base: base, state: state, into: &result)
                }
            }
        }
    }

    /// The node's device layer over the surface pixels it covers.
    private func addLayer(_ node: EffectNode, bounds: Rect, base: AffineTransform, state: State, into result: inout [PaintOperation]) {
        guard let region = PixelRect(covering: bounds.applying(base).intersection(surface)),
              let image = reference.deviceLayerImage(node, pasteboardToPixels: base, region: region)
        else {
            return
        }
        var rect = FlatPath()
        let r = region.rect
        rect.append(contour: [SIMD2(r.minX, r.minY), SIMD2(r.maxX, r.minY), SIMD2(r.maxX, r.maxY), SIMD2(r.minX, r.maxY)])
        result.append(.texture(PaintTexture(path: rect, rule: .nonZero, image: image, origin: SIMD2(Int32(region.minX), Int32(region.minY)), alpha: Float(state.alpha), blend: .normal)))
    }

    // MARK: Keyline

    private func lowerKeyline(_ item: DisplayItem, base: AffineTransform, state: State, cull: Rect, into result: inout [PaintOperation]) {
        switch item {
        case .fill(let fill):
            addHairline(fill.path, transform: fill.transform.concatenating(base), color: state.highlight, into: &result)
        case .stroke(let stroke):
            addHairline(stroke.path, transform: stroke.transform.concatenating(base), color: state.highlight, into: &result)
        case .path(let path):
            let transform = path.transform.concatenating(base)
            addHairline(path.path, transform: transform, color: state.highlight, into: &result)
            for stroke in path.appearance.strokes where stroke.hasArrowheads {
                for head in StrokeGeometry(path: path.path, stroke: stroke).heads {
                    addHairline(head.arrowhead.shape, transform: head.transform.concatenating(transform), color: state.highlight, into: &result)
                }
            }
        case .image(let image):
            addImageBox(image, transform: image.transform.concatenating(base), color: state.highlight, lineWidth: nil, state: State(), into: &result)
        case .text(let text):
            let transform = text.transform.concatenating(base)
            if shouldGreek(text, base: base) {
                addFill(DisplayPath(rect: text.bounds), transform: transform, rule: .nonZero, color: Color(white: 0.7), state: State(), into: &result)
            } else if let run = text.glyphRun {
                addFill(run.outline, transform: transform, rule: .nonZero, color: state.highlight, declaredRule: false, state: State(), into: &result)
            } else {
                var outline = DisplayPath(rect: text.bounds)
                outline.move(to: Point(x: text.bounds.minX, y: text.origin.y))
                outline.addLine(to: Point(x: text.bounds.maxX, y: text.origin.y))
                addHairline(outline, transform: transform, color: state.highlight, into: &result)
            }
        case .group(let group):
            // Text effects never show in Keyline.
            if !group.hiddenInKeyline {
                lowerGroup(group, base: base, state: state, cull: cull, into: &result)
            }
        }
    }

    // MARK: Primitives

    /// As `CoreGraphicsRenderer.shouldGreek`, with `base` the pasteboard → device transform.
    private func shouldGreek(_ item: TextRunItem, base: AffineTransform) -> Bool {
        if viewMode.greeksText && item.bounds.applying(item.transform).height <= ViewMode.greekingThreshold {
            return true
        }
        return greekTypeBelow > 0 && item.greekable && item.pixelSize(under: base) < greekTypeBelow
    }

    private func blend(_ overprint: Bool) -> PaintBlend {
        overprint && overprintPreview ? .multiply : .normal
    }

    /// One device pixel in the local units of `transform` (local → device pixels), as the
    /// Core Graphics renderer sizes hairlines from its CTM.
    static func hairlineWidth(for transform: AffineTransform) -> Double {
        let scale = abs(transform.determinant).squareRoot()
        return scale > 0 ? 1 / scale : 1
    }

    private func addFill(
        _ path: DisplayPath,
        transform: AffineTransform,
        rule: FillRule,
        color: Color,
        blend: PaintBlend = .normal,
        declaredRule: Bool = true,
        state: State,
        into result: inout [PaintOperation]
    ) {
        let flat = flattener.flatten(path, transform: transform)
        let effectiveRule = declaredRule && swapsFillRules ? (rule == .nonZero ? FillRule.evenOdd : .nonZero) : rule
        append(flat, rule: effectiveRule, color: color, blend: blend, state: state, into: &result)
    }

    /// A decoration line (`HairlineOutline`), as the Core Graphics renderer draws it: `style`'s
    /// width, one device pixel for a hairline.
    private func addStroke(
        _ path: DisplayPath,
        style: StrokeStyle,
        transform: AffineTransform,
        color: Color,
        blend: PaintBlend = .normal,
        state: State,
        into result: inout [PaintOperation]
    ) {
        let width = style.isHairline ? PaintListBuilder.hairlineWidth(for: transform) : style.width
        let outline = HairlineOutline.region(path, width: width, tolerance: StrokeExpansion.tolerance(forScale: transform.scaleFactor) * 16)
        append(flattener.flatten(outline, transform: transform), rule: .nonZero, color: color, blend: blend, state: state, into: &result)
    }

    private func addHairline(_ path: DisplayPath, transform: AffineTransform, color: Color, into result: inout [PaintOperation]) {
        addStroke(path, style: StrokeStyle(width: 0), transform: transform, color: color, state: State(), into: &result)
    }

    /// The image's frame and diagonals (`lineWidth` nil: hairlines, frame included) or only its
    /// diagonals at `lineWidth` (the Preview placeholder).
    private func addImageBox(_ item: ImageItem, transform: AffineTransform, color: Color, lineWidth: Double?, state: State, into result: inout [PaintOperation]) {
        let box = ImageDrawing.box(item.visibleRect, framed: lineWidth == nil)
        addStroke(box, style: StrokeStyle(width: lineWidth ?? 0), transform: transform, color: color, state: state, into: &result)
    }

    private func append(_ flat: FlatPath, rule: FillRule, color: Color, blend: PaintBlend, state: State, into result: inout [PaintOperation]) {
        let path = flat.clipped(to: clipBounds)
        guard let bounds = path.bounds, bounds.intersects(surface) else {
            return
        }
        let working = reference.colorManagement.workingComponents(color)
        let alpha = working.w * state.alpha
        let premultiplied = SIMD4<Float>(Float(working.x * alpha), Float(working.y * alpha), Float(working.z * alpha), Float(alpha))
        result.append(.fill(PaintFill(path: path, rule: rule, color: premultiplied, blend: blend)))
    }
}
