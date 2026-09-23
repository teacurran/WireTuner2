// The Core Graphics reference renderer (docs/spec/client.adoc, "Core Graphics reference
// renderer"): the same display list drawn into a PDF context for print and export, into
// bitmap contexts for golden images and the parity test, and into tile bitmaps for the
// `CALayer` fallback canvas.  Core Graphics is the truth the Metal renderer is held to.

import WTGeometry
import CoreGraphics
import Foundation

/// Draws display lists with Core Graphics.
public struct CoreGraphicsRenderer: WTRender {
    /// The space sampled paints and intermediate effect bitmaps evaluate in: sRGB.  Tiles and
    /// bitmaps are rendered in `colorManagement`'s working space.
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// How tagged colours become pixels (CMS-006, CMS-007): the working space tiles and bitmaps
    /// are tagged with, Working CMYK, the intent and the soft proof.  PDF output carries colours
    /// tagged in their own spaces and never proofs.
    public var colorManagement: ColorManagement = .standard

    /// Where placed images' pixels come from (IMG-004); nil draws every image as its
    /// placeholder.  Bitmaps and tiles never wait for a decode (the store calls back when a
    /// level is ready); PDF output decodes inline.
    public var imageStore: ImageStore?

    public let flatteningTolerance: FlatteningTolerance

    /// Painted under the display list when set; nil leaves the context untouched (a
    /// transparent tile, a white PDF page).
    public let background: Color?

    /// The drawing mode (REND-005), applied while drawing: the display list is never rebuilt
    /// for a mode change.
    public var viewMode: ViewMode

    /// menu:View[Overprint Preview]: fills and strokes marked overprint are composited with
    /// the multiply blend mode, which simulates inks printing over one another.
    public var overprintPreview: Bool

    /// Sampled paints (Rectangle, Cone and Contour gradients, noise, textures, lens backdrops)
    /// are rasterized this many times finer than the context's base space.  1 for bitmaps and
    /// tiles, whose base space is device pixels; `renderPDF` uses `pdfRasterScale`.
    public var rasterScale: Double = 1

    /// The raster scale of PDF output: 4 pixels per point, about 300 dpi.
    public static let pdfRasterScale = 4.0

    /// The *Raster effect preview* preference (FX-009): the resolution raster effects render at
    /// in bitmaps and tiles.  PDF output always uses each object's resolution.
    public var rasterPreview: RasterPreview = .screen

    /// When set, raster effects missing from the cache render in the background and this is
    /// called with the pasteboard rectangle to repaint when one is ready; meanwhile the object
    /// draws without them and with a badge.  Nil renders them before returning.
    public var rasterEffectsReady: (@Sendable (Rect) -> Void)?

    /// The *Greek type below* preference (type-specifications, "Font, size and style"): glyph
    /// runs whose type is smaller than this many device pixels draw as grey bars in every mode,
    /// unless the run is not `greekable`.  0 turns it off; PDF output never greeks.
    public var greekTypeBelow: Double = 0

    /// Plate mode (PRINT-007): every colour is mapped onto one plate of a separation before it
    /// reaches Core Graphics, and the sheet starts white.  Nil draws the composite.
    public var plate: PlateContext?

    /// Whether the context is vector output (PDF): raster effects are placed as images at the
    /// objects' own resolution and masks become image soft masks.
    var vectorOutput = false

    /// Where raster effect results are cached.
    var rasterCache = RasterEffectCache.shared

    public init(
        flatteningTolerance: FlatteningTolerance = .standard,
        background: Color? = nil,
        viewMode: ViewMode = .preview,
        overprintPreview: Bool = false
    ) {
        self.flatteningTolerance = flatteningTolerance
        self.background = background
        self.viewMode = viewMode
        self.overprintPreview = overprintPreview
    }

    /// The same renderer in another drawing mode.
    public func with(viewMode: ViewMode) -> CoreGraphicsRenderer {
        var result = self
        result.viewMode = viewMode
        return result
    }

    /// The same renderer with another colour pipeline.
    public func with(colorManagement: ColorManagement) -> CoreGraphicsRenderer {
        var result = self
        result.colorManagement = colorManagement
        return result
    }

    /// The same renderer with overprint preview on or off.
    public func with(overprintPreview: Bool) -> CoreGraphicsRenderer {
        var result = self
        result.overprintPreview = overprintPreview
        return result
    }

    // MARK: WTRender

    public func render(_ displayList: DisplayList, viewport: Viewport, into context: CGContext) {
        draw(
            displayList,
            pasteboardTransform: viewport.pasteboardToView,
            cull: viewport.visiblePasteboardBounds,
            surface: viewport.viewBounds,
            into: context
        )
    }

    public func render(_ displayList: DisplayList, tile key: TileKey, geometry: TileGeometry, into context: CGContext) {
        let edge = Double(geometry.tileSize)
        draw(
            displayList,
            pasteboardTransform: geometry.pasteboardToTile(key),
            cull: geometry.pasteboardBounds(of: key),
            surface: Rect(x: 0, y: 0, width: edge, height: edge),
            into: context
        )
    }

    public func renderTile(_ displayList: DisplayList, key: TileKey, geometry: TileGeometry) -> CGImage? {
        guard let surface = BitmapSurface(width: geometry.tileSize, height: geometry.tileSize, colorSpace: colorManagement.colorSpace) else {
            return nil
        }
        render(displayList, tile: key, geometry: geometry, into: surface.context)
        return surface.makeImage()
    }

    // MARK: Whole-view output

    /// The viewport rasterized at `scale` device pixels per view point.
    public func renderBitmap(_ displayList: DisplayList, viewport: Viewport, scale: Double = 1) -> CGImage? {
        let width = Int((viewport.size.width * scale).rounded())
        let height = Int((viewport.size.height * scale).rounded())
        guard let surface = BitmapSurface(width: width, height: height, colorSpace: colorManagement.colorSpace) else {
            return nil
        }
        surface.context.scaleBy(x: scale, y: scale)
        render(displayList, viewport: viewport, into: surface.context)
        return surface.makeImage()
    }

    /// The viewport as a one-page PDF whose media box is the view in points.
    public func renderPDF(_ displayList: DisplayList, viewport: Viewport) -> Data? {
        let data = NSMutableData()
        var mediaBox = viewport.viewBounds.cg
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            return nil
        }
        context.beginPDFPage(nil)
        var vector = self
        vector.rasterScale = CoreGraphicsRenderer.pdfRasterScale
        vector.vectorOutput = true
        vector.colorManagement.proof = nil
        vector.render(displayList, viewport: viewport, into: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: Drawing

    /// Inherited down the group tree while drawing.
    struct DrawState {
        /// The alpha a fast-mode group applies in place of a transparency layer.
        var alpha: Double = 1
        /// The keyline colour: the nearest enclosing layer's highlight colour.
        var highlight: Color = .black
        /// The canvas being drawn and the item's index path in it, for lens backdrops; nil for
        /// nested content (tiles, brush symbols, snapshots).
        var canvas: DisplayList?
        var indexPath: [Int] = []
        var lensDepth = 0
        /// Canvas space → base space when the canvas began.
        var canvasToBase: CGAffineTransform = .identity
    }

    /// Draws `displayList` through `pasteboardTransform` into `context`, flipping Core
    /// Graphics' y-up user space so `surface` (y-down, in user units) is the painted area.
    private func draw(
        _ displayList: DisplayList,
        pasteboardTransform: AffineTransform,
        cull: Rect,
        surface: Rect,
        into context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFlatness(CGFloat(flatteningTolerance.devicePixels))
        context.translateBy(x: 0, y: CGFloat(surface.height))
        context.scaleBy(x: 1, y: -1)
        if let background = plate == nil ? background : .white {
            context.setFillColor(fillColor(background))
            context.fill(surface.cg)
        }
        context.concatenate(pasteboardTransform.cg)
        let base = DrawState(canvas: displayList, canvasToBase: context.ctm)
        for run in displayList.layerRuns(displayList.indices(intersecting: cull)) {
            guard let span = run.span else {
                for index in run.indices {
                    var state = base
                    state.indexPath = [index]
                    draw(displayList.items[index], state: state, cull: cull, into: context)
                }
                continue
            }
            drawLayer(span.layer, indices: run.indices, of: displayList, base: base, cull: cull, into: context)
        }
    }

    /// The items at `indices` by their layer's rules (LIB-005): outlines in every mode for a
    /// keyline layer or guides, the layer highlight for hairlines, a background layer composited
    /// at 50% as one group (Keyline ignores opacity, as for any group).
    private func drawLayer(_ layer: LayerRendering, indices: [Int], of displayList: DisplayList, base: DrawState, cull: Rect, into context: CGContext) {
        var renderer = self
        if layer.forcesKeyline && !viewMode.isKeyline {
            renderer.viewMode = viewMode.isFast ? .fastKeyline : .keyline
        }
        var state = base
        state.highlight = layer.highlight
        context.saveGState()
        let translucent = layer.opacity < 1
        let layered = translucent && renderer.viewMode.drawsTransparencyGroups
        if layered {
            context.setAlpha(CGFloat(layer.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        } else if translucent && !renderer.viewMode.isKeyline {
            state.alpha = layer.opacity
            context.setAlpha(CGFloat(layer.opacity))
        }
        for index in indices {
            var itemState = state
            itemState.indexPath = [index]
            renderer.draw(displayList.items[index], state: itemState, cull: cull, into: context)
        }
        if layered {
            context.endTransparencyLayer()
        }
        context.restoreGState()
    }

    /// Draws canvas items (a lens's backdrop: a prefix of `canvas`, positions unchanged) with
    /// the context's current user space as canvas space.
    func drawCanvasItems(_ items: [DisplayItem], canvas: DisplayList, in context: CGContext, lensDepth: Int) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFlatness(CGFloat(flatteningTolerance.devicePixels))
        let cull = Rect(context.boundingBoxOfClipPath)
        let base = DrawState(canvas: canvas, lensDepth: lensDepth, canvasToBase: context.ctm)
        for (index, item) in items.enumerated() {
            guard let bounds = item.bounds, bounds.intersects(cull) else { continue }
            var state = base
            state.indexPath = [index]
            draw(item, state: state, cull: cull, into: context)
        }
    }

    /// Draws nested display items (a tile, brush copies, a snapshot) in the context's current
    /// user space; lenses among them render as Basic.
    func drawNested(_ items: [DisplayItem], in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFlatness(CGFloat(flatteningTolerance.devicePixels))
        let state = DrawState(canvasToBase: context.ctm)
        let cull = Rect(context.boundingBoxOfClipPath)
        for item in items {
            draw(item, state: state, cull: cull, into: context)
        }
    }

    func draw(_ item: DisplayItem, state: DrawState, cull: Rect, into context: CGContext) {
        if viewMode.isKeyline {
            drawKeyline(item, state: state, cull: cull, into: context)
            return
        }
        switch item {
        case .fill(let fill):
            context.saveGState()
            context.concatenate(fill.transform.cg)
            drawRegions([.fill(fill.path, fill.rule, fill.paint)], path: fill.path, rule: fill.rule, overprint: false, state: state, into: context)
            context.restoreGState()
        case .stroke(let stroke):
            context.saveGState()
            context.concatenate(stroke.transform.cg)
            let paint = StrokePaint(paint: stroke.paint, style: stroke.style)
            drawRegions(strokeRegions(paint, path: stroke.path, in: context), path: stroke.path, rule: .nonZero, overprint: false, state: state, into: context)
            context.restoreGState()
        case .path(let path):
            if path.hasEffects {
                drawNodes(EffectPipeline.nodes(for: path), state: state, cull: cull, into: context)
            } else {
                drawPath(path, state: state, into: context)
            }
        case .image(let image):
            if viewMode.drawsImagesAsBoxes {
                drawImageBox(image, color: Color(white: 0.45), into: context)
            } else {
                drawImage(image, into: context)
            }
        case .text(let text):
            if shouldGreek(text, in: context) {
                drawGreeked(text, into: context)
            } else if let run = text.glyphRun {
                drawGlyphs(run, transform: text.transform, color: text.color, overprint: text.overprint, into: context)
            } else {
                drawTextPlaceholder(text, into: context)
            }
        case .group(let group):
            drawGroup(group, state: state, cull: cull, into: context)
        }
    }

    /// The regions a stroke paints, at the context's current scale (hairline width and outline
    /// tolerance; PDF output, whose base space is points, outlines at its raster scale).
    private func strokeRegions(_ stroke: StrokePaint, path: DisplayPath, in context: CGContext) -> [PaintedRegion] {
        let ctm = context.ctm
        let scale = abs(ctm.a * ctm.d - ctm.b * ctm.c).squareRoot() * max(rasterScale, 1)
        return StrokeExpansion.regions(for: stroke, path: path, hairlineWidth: Double(hairlineWidth(in: context)), tolerance: StrokeExpansion.tolerance(forScale: scale))
    }

    /// The attribute stack, bottom first, all in the item's local space.
    private func drawPath(_ item: PathItem, state: DrawState, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        for element in item.appearance.items {
            switch element {
            case .fill(let fill):
                drawRegions([.fill(item.path, fill.rule, fill.paint)], path: item.path, rule: fill.rule, overprint: fill.overprint, state: state, into: context)
            case .stroke(let stroke):
                drawRegions(strokeRegions(stroke, path: item.path, in: context), path: item.path, rule: .nonZero, overprint: stroke.overprint, state: state, into: context)
            }
        }
        context.restoreGState()
    }

    /// Fills each region with its paint: solid colours directly, other paints through the
    /// path's clip by `PaintDrawing` (composited as one layer when a fast-mode alpha or the
    /// overprint preview's multiply applies, as the Metal renderer composites their texture).
    /// Brush copies draw as nested items.  `path` and `rule` are the item's own, for paints that
    /// depend on the object's shape.
    private func drawRegions(_ regions: [PaintedRegion], path: DisplayPath, rule: FillRule, overprint: Bool, state: DrawState, into context: CGContext) {
        for region in regions {
            switch region {
            case .fill(let shape, let shapeRule, let composite):
                let paint = plate.map { $0.paint(composite, overprint: overprint) } ?? composite
                if paint.isNone {
                    continue
                }
                if let color = paint.color, !(overprint && overprintPreview) {
                    // The common case needs no saved state: the colour is set for every fill.
                    context.addPath(shape.cgPath)
                    context.setFillColor(fillColor(color))
                    context.fillPath(using: shapeRule.cg)
                    continue
                }
                context.saveGState()
                applyOverprint(overprint, to: context)
                context.addPath(shape.cgPath)
                if let color = paint.color {
                    context.setFillColor(fillColor(color))
                    context.fillPath(using: shapeRule.cg)
                } else {
                    context.clip(using: shapeRule.cg)
                    let layered = state.alpha < 1 || (overprint && overprintPreview)
                    if layered {
                        context.beginTransparencyLayer(auxiliaryInfo: nil)
                    }
                    let environment = PaintEnvironment(
                        renderer: self,
                        canvasToBase: state.canvasToBase,
                        path: path,
                        rule: rule,
                        rasterScale: rasterScale,
                        canvas: state.canvas,
                        indexPath: state.indexPath,
                        lensDepth: state.lensDepth
                    )
                    PaintDrawing.fill(paint, in: context, environment: environment)
                    if layered {
                        context.endTransparencyLayer()
                    }
                }
                context.restoreGState()
            case .items(let items):
                var nested = state
                nested.canvas = nil
                for item in items {
                    draw(item, state: nested, cull: Rect(context.boundingBoxOfClipPath), into: context)
                }
            }
        }
    }

    /// The `CGColor` a solid fill paints with: in the working space for bitmaps (converted and
    /// proofed exactly as the Metal renderer converts it), tagged in its own space for PDF.
    func fillColor(_ color: Color) -> CGColor {
        vectorOutput ? colorManagement.taggedCGColor(color) : colorManagement.cgColor(color)
    }

    /// `color` as it paints: on the plate in plate mode (nil when an overprinting colour covers
    /// nothing there), itself otherwise.
    func ink(_ color: Color, overprint: Bool = false) -> Color? {
        guard let plate else {
            return color
        }
        return plate.plateColor(color, overprint: overprint)
    }

    private func applyOverprint(_ overprint: Bool, to context: CGContext) {
        if overprint && overprintPreview {
            context.setBlendMode(.multiply)
        }
    }

    /// The decoded image (IMG-004) when the renderer has an `imageStore` that holds it, else
    /// the placeholder.
    private func drawImage(_ item: ImageItem, into context: CGContext) {
        guard let imageStore, let image = ImageDrawing.image(for: item, store: imageStore, renderer: self, in: context) else {
            drawImagePlaceholder(item, into: context)
            return
        }
        ImageDrawing.draw(image, item: item, renderer: self, into: context)
    }

    /// A neutral grey block with a diagonal cross over the visible frame; while the blob
    /// downloads, a darker bar along its bottom edge shows the progress.
    private func drawImagePlaceholder(_ item: ImageItem, into context: CGContext) {
        let frame = item.visibleRect
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setFillColor(fillColor(ink(Color(white: 0.75))!))
        context.fill(frame.cg)
        if let bar = ImageDrawing.progressBar(for: item, store: imageStore) {
            context.setFillColor(fillColor(ink(Color(white: 0.45))!))
            context.fill(bar.cg)
        }
        context.restoreGState()
        drawImageBox(item, color: Color(white: 0.45), lineWidth: 1, into: context)
    }

    /// The image's visible frame and diagonals only: the fast modes' and Keyline's crossed box,
    /// as hairlines.  With `lineWidth` (the Preview placeholder) only the diagonals are drawn.
    private func drawImageBox(_ item: ImageItem, color: Color, lineWidth: Double? = nil, into context: CGContext) {
        drawLine(ImageDrawing.box(item.visibleRect, framed: lineWidth == nil), width: lineWidth, transform: item.transform, color: color, into: context)
    }

    /// The run's ink bounds at 15% of the text colour plus its baseline, until `WTText`
    /// supplies glyph runs.
    private func drawTextPlaceholder(_ item: TextRunItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setFillColor(fillColor(ink(item.color.withAlpha(multipliedBy: 0.15))!))
        context.fill(item.bounds.cg)
        context.restoreGState()
        var baseline = DisplayPath()
        baseline.move(to: Point(x: item.bounds.minX, y: item.origin.y))
        baseline.addLine(to: Point(x: item.bounds.maxX, y: item.origin.y))
        drawLine(baseline, width: 1, transform: item.transform, color: item.color, into: context)
    }

    /// A decoration line (`HairlineOutline`): `width` local units, or one device pixel when nil.
    private func drawLine(_ path: DisplayPath, width: Double?, transform: AffineTransform, color composite: Color, into context: CGContext) {
        let color = ink(composite)!
        context.saveGState()
        context.concatenate(transform.cg)
        let ctm = context.ctm
        let scale = abs(ctm.a * ctm.d - ctm.b * ctm.c).squareRoot()
        let outline = HairlineOutline.region(path, width: width ?? Double(hairlineWidth(in: context)), tolerance: StrokeExpansion.tolerance(forScale: scale) * 16)
        context.addPath(outline.cgPath)
        context.setFillColor(fillColor(color))
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    /// Glyph outlines filled non-zero: the same polygons the Metal renderer fills.
    private func drawGlyphs(_ run: GlyphRun, transform: AffineTransform, color: Color, overprint: Bool = false, into context: CGContext) {
        let outline = run.outline
        guard !outline.isEmpty, let color = ink(color, overprint: overprint) else {
            return
        }
        context.saveGState()
        applyOverprint(overprint, to: context)
        context.concatenate(transform.cg)
        context.addPath(outline.cgPath)
        context.setFillColor(fillColor(color))
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    /// Whether `item` draws as a grey bar: in the fast modes, text whose on-page height is at
    /// most `ViewMode.greekingThreshold`; in every mode but PDF output, greekable type smaller
    /// on the device than `greekTypeBelow` pixels.
    private func shouldGreek(_ item: TextRunItem, in context: CGContext) -> Bool {
        if viewMode.greeksText && item.bounds.applying(item.transform).height <= ViewMode.greekingThreshold {
            return true
        }
        guard greekTypeBelow > 0, item.greekable, !vectorOutput else {
            return false
        }
        return item.pixelSize(under: AffineTransform(context.ctm)) < greekTypeBelow
    }

    /// Greeked text: the run's bounds as a flat grey bar.
    private func drawGreeked(_ item: TextRunItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setFillColor(fillColor(ink(Color(white: 0.7))!))
        context.fill(item.bounds.cg)
        context.restoreGState()
    }

    private func drawGroup(_ group: GroupItem, state: DrawState, cull: Rect, into context: CGContext) {
        context.saveGState()
        if let clip = group.clip {
            context.addPath(clip.applying(group.transform).cgPath)
            context.clip(using: group.clipRule.cg)
        }
        var inner = state
        if let highlight = group.highlightColor {
            inner.highlight = highlight
        }
        let translucent = group.opacity < 1
        let layered = translucent && viewMode.drawsTransparencyGroups
        if layered {
            context.setAlpha(CGFloat(group.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        } else if translucent && !viewMode.isKeyline {
            // Fast modes: members straight onto the canvas at the accumulated alpha.
            inner.alpha = state.alpha * group.opacity
            context.setAlpha(CGFloat(inner.alpha))
        }
        if group.isDerived {
            // A derived group draws its entries (Keyline: without the group's own effects);
            // nothing in it is a lens backdrop position of the canvas.
            var derivedState = inner
            derivedState.canvas = nil
            if viewMode.isKeyline {
                for item in EffectPipeline.derived(group).keylineItems where item.bounds?.intersects(cull) ?? false {
                    draw(item, state: derivedState, cull: cull, into: context)
                }
            } else {
                drawNodes(EffectPipeline.derived(group).nodes, state: derivedState, cull: cull, into: context)
            }
        } else {
            for (index, child) in group.children.enumerated() {
                if let bounds = child.bounds, bounds.intersects(cull) {
                    var childState = inner
                    childState.indexPath = state.indexPath + [index]
                    draw(child, state: childState, cull: cull, into: context)
                }
            }
        }
        if layered {
            context.endTransparencyLayer()
        }
        context.restoreGState()
    }

    // MARK: Keyline

    /// Keyline: every path as a one-device-pixel hairline in the
    /// layer highlight colour, no fills; strokes draw their centreline and arrowhead outlines;
    /// images as crossed boxes; text as its bounds and baseline (greeked to a grey bar in Fast
    /// Keyline).  Clips still apply; opacity does not.
    private func drawKeyline(_ item: DisplayItem, state: DrawState, cull: Rect, into context: CGContext) {
        switch item {
        case .fill(let fill):
            strokeHairline(fill.path, transform: fill.transform, color: state.highlight, into: context)
        case .stroke(let stroke):
            strokeHairline(stroke.path, transform: stroke.transform, color: state.highlight, into: context)
        case .path(let path):
            strokeHairline(path.path, transform: path.transform, color: state.highlight, into: context)
            for stroke in path.appearance.strokes where stroke.hasArrowheads {
                for head in StrokeGeometry(path: path.path, stroke: stroke).heads {
                    strokeHairline(head.arrowhead.shape, transform: head.transform.concatenating(path.transform), color: state.highlight, into: context)
                }
            }
        case .image(let image):
            drawImageBox(image, color: state.highlight, into: context)
        case .text(let text):
            if shouldGreek(text, in: context) {
                drawGreeked(text, into: context)
            } else if let run = text.glyphRun {
                // Keyline keeps type legible: glyphs filled in the highlight colour.
                drawGlyphs(run, transform: text.transform, color: state.highlight, into: context)
            } else {
                var outline = DisplayPath(rect: text.bounds)
                outline.move(to: Point(x: text.bounds.minX, y: text.origin.y))
                outline.addLine(to: Point(x: text.bounds.maxX, y: text.origin.y))
                strokeHairline(outline, transform: text.transform, color: state.highlight, into: context)
            }
        case .group(let group):
            // Text effects never show in Keyline.
            if !group.hiddenInKeyline {
                drawGroup(group, state: state, cull: cull, into: context)
            }
        }
    }

    private func strokeHairline(_ path: DisplayPath, transform: AffineTransform, color: Color, into context: CGContext) {
        drawLine(path, width: nil, transform: transform, color: color, into: context)
    }

    /// One device pixel in the context's current user space.  Core Graphics' own line width 0
    /// paints nothing in bitmap contexts, so hairlines are sized from the CTM: device pixels for
    /// bitmaps and tiles, PDF points (one view point) for PDF pages.
    private func hairlineWidth(in context: CGContext) -> CGFloat {
        let ctm = context.ctm
        let scale = abs(ctm.a * ctm.d - ctm.b * ctm.c).squareRoot()
        return scale > 0 ? 1 / scale : 1
    }
}
