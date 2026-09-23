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
        render(displayList, viewport: viewport, into: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: Drawing

    /// Inherited down the group tree while drawing.
    private struct DrawState {
        /// The alpha a fast-mode group applies in place of a transparency layer.
        var alpha: Double = 1
        /// The keyline colour: the nearest enclosing layer's highlight colour.
        var highlight: Color = .black
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
        for index in displayList.indices(intersecting: cull) {
            draw(displayList.items[index], state: DrawState(), cull: cull, into: context)
        }
    }

    private func draw(_ item: DisplayItem, state: DrawState, cull: Rect, into context: CGContext) {
        if viewMode.isKeyline {
            drawKeyline(item, state: state, cull: cull, into: context)
            return
        }
        switch item {
        case .fill(let fill):
            drawFill(fill, into: context)
        case .stroke(let stroke):
            drawStroke(stroke, into: context)
        case .path(let path):
            drawPath(path, into: context)
        case .image(let image):
            if viewMode.drawsImagesAsBoxes {
                drawImageBox(image, color: Color(white: 0.45), into: context)
            } else {
                drawImagePlaceholder(image, into: context)
            }
        case .text(let text):
            if shouldGreek(text) {
                drawGreeked(text, into: context)
            } else {
                drawTextPlaceholder(text, into: context)
            }
        case .group(let group):
            drawGroup(group, state: state, cull: cull, into: context)
        }
    }

    private func drawFill(_ item: FillItem, into context: CGContext) {
        guard let color = item.paint.color else {
            return
        }
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.addPath(item.path.cgPath)
        context.setFillColor(color.cg)
        context.fillPath(using: item.rule.cg)
        context.restoreGState()
    }

    private func drawStroke(_ item: StrokeItem, into context: CGContext) {
        guard let color = item.paint.color else {
            return
        }
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.addPath(item.path.cgPath)
        apply(item.style, to: context)
        context.setStrokeColor(color.cg)
        context.strokePath()
        context.restoreGState()
    }

    /// The attribute stack, bottom first, all in the item's local space.
    private func drawPath(_ item: PathItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        let path = item.path.cgPath
        for element in item.appearance.items {
            switch element {
            case .fill(let fill):
                guard let color = fill.paint.color else { continue }
                context.saveGState()
                applyOverprint(fill.overprint, to: context)
                context.addPath(path)
                context.setFillColor(color.cg)
                context.fillPath(using: fill.rule.cg)
                context.restoreGState()
            case .stroke(let stroke):
                guard let color = stroke.paint.color else { continue }
                context.saveGState()
                applyOverprint(stroke.overprint, to: context)
                let geometry = StrokeGeometry(path: item.path, stroke: stroke)
                context.addPath(stroke.hasArrowheads ? geometry.body.cgPath : path)
                apply(stroke.style, to: context)
                context.setStrokeColor(color.cg)
                context.strokePath()
                for head in geometry.heads {
                    drawArrowhead(head, style: stroke.style, color: color, into: context)
                }
                context.restoreGState()
            }
        }
        context.restoreGState()
    }

    private func drawArrowhead(_ head: PlacedArrowhead, style: StrokeStyle, color: Color, into context: CGContext) {
        context.saveGState()
        context.concatenate(head.transform.cg)
        context.addPath(head.arrowhead.shape.cgPath)
        if head.arrowhead.filled {
            context.setFillColor(color.cg)
            context.fillPath(using: .winding)
        } else {
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(1)
            context.setLineCap(style.cap.cg)
            context.setLineJoin(style.join.cg)
            context.setMiterLimit(CGFloat(style.miterLimit))
            context.setStrokeColor(color.cg)
            context.strokePath()
        }
        context.restoreGState()
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
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setStrokeColor(color.cg)
        context.setLineWidth(lineWidth.map { CGFloat($0) } ?? hairlineWidth(in: context))
        if lineWidth == nil {
            context.addRect(item.rect.cg)
        }
        context.move(to: CGPoint(x: item.rect.minX, y: item.rect.minY))
        context.addLine(to: CGPoint(x: item.rect.maxX, y: item.rect.maxY))
        context.move(to: CGPoint(x: item.rect.maxX, y: item.rect.minY))
        context.addLine(to: CGPoint(x: item.rect.minX, y: item.rect.maxY))
        context.strokePath()
        context.restoreGState()
    }

    /// The run's ink bounds at 15% of the text colour plus its baseline, until `WTText`
    /// supplies glyph runs.
    private func drawTextPlaceholder(_ item: TextRunItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setFillColor(item.color.withAlpha(multipliedBy: 0.15).cg)
        context.fill(item.bounds.cg)
        context.setStrokeColor(item.color.cg)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: item.bounds.minX, y: item.origin.y))
        context.addLine(to: CGPoint(x: item.bounds.maxX, y: item.origin.y))
        context.strokePath()
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
        for child in group.children {
            if let bounds = child.bounds, bounds.intersects(cull) {
                draw(child, state: inner, cull: cull, into: context)
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
        context.saveGState()
        context.concatenate(transform.cg)
        context.addPath(path.cgPath)
        context.setLineWidth(hairlineWidth(in: context))
        context.setStrokeColor(color.cg)
        context.strokePath()
        context.restoreGState()
    }

    /// One device pixel in the context's current user space.  Core Graphics' own line width 0
    /// paints nothing in bitmap contexts, so hairlines are sized from the CTM: device pixels for
    /// bitmaps and tiles, PDF points (one view point) for PDF pages.
    private func hairlineWidth(in context: CGContext) -> CGFloat {
        let ctm = context.ctm
        let scale = abs(ctm.a * ctm.d - ctm.b * ctm.c).squareRoot()
        return scale > 0 ? 1 / scale : 1
    }

    private func apply(_ style: StrokeStyle, to context: CGContext) {
        context.setLineWidth(style.isHairline ? hairlineWidth(in: context) : CGFloat(style.width))
        context.setLineCap(style.cap.cg)
        context.setLineJoin(style.join.cg)
        context.setMiterLimit(CGFloat(style.miterLimit))
        let dash = style.effectiveDash
        if !dash.isEmpty {
            context.setLineDash(phase: CGFloat(style.dashPhase), lengths: dash.map { CGFloat($0) })
        }
    }
}
