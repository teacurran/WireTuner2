// The Core Graphics reference renderer (docs/spec/client.adoc, "Core Graphics reference
// renderer"): the same display list drawn into a PDF context for print and export, into
// bitmap contexts for golden images and the parity test, and into tile bitmaps for the
// `CALayer` fallback canvas.  Core Graphics is the truth the Metal renderer is held to.

import WTGeometry
import CoreGraphics
import Foundation

/// Draws display lists with Core Graphics.
public struct CoreGraphicsRenderer: WTRender {
    /// The working colour space: sRGB, until the CMS epic supplies document profiles.
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

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
        guard let surface = BitmapSurface(width: geometry.tileSize, height: geometry.tileSize) else {
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
        guard let surface = BitmapSurface(width: width, height: height) else {
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
        if let background {
            context.setFillColor(background.cg)
            context.fill(surface.cg)
        }
        context.concatenate(pasteboardTransform.cg)
        let base = DrawState(canvas: displayList, canvasToBase: context.ctm)
        for index in displayList.indices(intersecting: cull) {
            var state = base
            state.indexPath = [index]
            draw(displayList.items[index], state: state, cull: cull, into: context)
        }
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

    private func draw(_ item: DisplayItem, state: DrawState, cull: Rect, into context: CGContext) {
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
            drawPath(path, state: state, into: context)
        case .image(let image):
            if viewMode.drawsImagesAsBoxes {
                drawImageBox(image, color: Color(white: 0.45), into: context)
            } else {
                drawImagePlaceholder(image, into: context)
            }
        case .text(let text):
            if shouldGreek(text) {
                drawGreeked(text, into: context)
            } else if let run = text.glyphRun {
                drawGlyphs(run, transform: text.transform, color: text.color, into: context)
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
            case .fill(let shape, let shapeRule, let paint):
                if paint.isNone {
                    continue
                }
                if let color = paint.color, !(overprint && overprintPreview) {
                    // The common case needs no saved state: the colour is set for every fill.
                    context.addPath(shape.cgPath)
                    context.setFillColor(color.cg)
                    context.fillPath(using: shapeRule.cg)
                    continue
                }
                context.saveGState()
                applyOverprint(overprint, to: context)
                context.addPath(shape.cgPath)
                if let color = paint.color {
                    context.setFillColor(color.cg)
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

    private func applyOverprint(_ overprint: Bool, to context: CGContext) {
        if overprint && overprintPreview {
            context.setBlendMode(.multiply)
        }
    }

    /// A neutral grey block with a diagonal cross, until the image pipeline lands.
    private func drawImagePlaceholder(_ item: ImageItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setFillColor(Color(white: 0.75).cg)
        context.fill(item.rect.cg)
        context.restoreGState()
        drawImageBox(item, color: Color(white: 0.45), lineWidth: 1, into: context)
    }

    /// The image's frame and diagonals only: the fast modes' and Keyline's crossed box, as
    /// hairlines.  With `lineWidth` (the Preview placeholder) only the diagonals are drawn.
    private func drawImageBox(_ item: ImageItem, color: Color, lineWidth: Double? = nil, into context: CGContext) {
        var box = lineWidth == nil ? DisplayPath(rect: item.rect) : DisplayPath()
        box.move(to: Point(x: item.rect.minX, y: item.rect.minY))
        box.addLine(to: Point(x: item.rect.maxX, y: item.rect.maxY))
        box.move(to: Point(x: item.rect.maxX, y: item.rect.minY))
        box.addLine(to: Point(x: item.rect.minX, y: item.rect.maxY))
        drawLine(box, width: lineWidth, transform: item.transform, color: color, into: context)
    }

    /// The run's ink bounds at 15% of the text colour plus its baseline, until `WTText`
    /// supplies glyph runs.
    private func drawTextPlaceholder(_ item: TextRunItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setFillColor(item.color.withAlpha(multipliedBy: 0.15).cg)
        context.fill(item.bounds.cg)
        context.restoreGState()
        var baseline = DisplayPath()
        baseline.move(to: Point(x: item.bounds.minX, y: item.origin.y))
        baseline.addLine(to: Point(x: item.bounds.maxX, y: item.origin.y))
        drawLine(baseline, width: 1, transform: item.transform, color: item.color, into: context)
    }

    /// A decoration line (`HairlineOutline`): `width` local units, or one device pixel when nil.
    private func drawLine(_ path: DisplayPath, width: Double?, transform: AffineTransform, color: Color, into context: CGContext) {
        context.saveGState()
        context.concatenate(transform.cg)
        let ctm = context.ctm
        let scale = abs(ctm.a * ctm.d - ctm.b * ctm.c).squareRoot()
        let outline = HairlineOutline.region(path, width: width ?? Double(hairlineWidth(in: context)), tolerance: StrokeExpansion.tolerance(forScale: scale) * 16)
        context.addPath(outline.cgPath)
        context.setFillColor(color.cg)
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    /// Glyph outlines filled non-zero: the same polygons the Metal renderer fills.
    private func drawGlyphs(_ run: GlyphRun, transform: AffineTransform, color: Color, into context: CGContext) {
        let outline = run.outline
        guard !outline.isEmpty else {
            return
        }
        context.saveGState()
        context.concatenate(transform.cg)
        context.addPath(outline.cgPath)
        context.setFillColor(color.cg)
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    /// Whether the fast modes draw `item` as a grey bar: text whose on-page height is at most
    /// `ViewMode.greekingThreshold`.
    private func shouldGreek(_ item: TextRunItem) -> Bool {
        viewMode.greeksText && item.bounds.applying(item.transform).height <= ViewMode.greekingThreshold
    }

    /// Greeked text: the run's bounds as a flat grey bar.
    private func drawGreeked(_ item: TextRunItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setFillColor(Color(white: 0.7).cg)
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
        for (index, child) in group.children.enumerated() {
            if let bounds = child.bounds, bounds.intersects(cull) {
                var childState = inner
                childState.indexPath = state.indexPath + [index]
                draw(child, state: childState, cull: cull, into: context)
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
            if shouldGreek(text) {
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
            drawGroup(group, state: state, cull: cull, into: context)
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
