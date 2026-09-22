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

    public init(flatteningTolerance: FlatteningTolerance = .standard, background: Color? = nil) {
        self.flatteningTolerance = flatteningTolerance
        self.background = background
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
            draw(displayList.items[index], cull: cull, into: context)
        }
    }

    private func draw(_ item: DisplayItem, cull: Rect, into context: CGContext) {
        switch item {
        case .fill(let fill):
            drawFill(fill, into: context)
        case .stroke(let stroke):
            drawStroke(stroke, into: context)
        case .image(let image):
            drawImagePlaceholder(image, into: context)
        case .text(let text):
            drawTextPlaceholder(text, into: context)
        case .group(let group):
            drawGroup(group, cull: cull, into: context)
        }
    }

    private func drawFill(_ item: FillItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.addPath(item.path.cgPath)
        setFill(item.paint, in: context)
        context.fillPath(using: item.rule.cg)
        context.restoreGState()
    }

    private func drawStroke(_ item: StrokeItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.addPath(item.path.cgPath)
        apply(item.style, to: context)
        setStroke(item.paint, in: context)
        context.strokePath()
        context.restoreGState()
    }

    /// A neutral grey block with a diagonal cross, until the image pipeline lands.
    private func drawImagePlaceholder(_ item: ImageItem, into context: CGContext) {
        context.saveGState()
        context.concatenate(item.transform.cg)
        context.setFillColor(Color(white: 0.75).cg)
        context.fill(item.rect.cg)
        context.setStrokeColor(Color(white: 0.45).cg)
        context.setLineWidth(1)
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

    private func drawGroup(_ group: GroupItem, cull: Rect, into context: CGContext) {
        context.saveGState()
        if let clip = group.clip {
            context.addPath(clip.applying(group.transform).cgPath)
            context.clip(using: group.clipRule.cg)
        }
        let layered = group.opacity < 1
        if layered {
            context.setAlpha(CGFloat(group.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        for child in group.children {
            if let bounds = child.bounds, bounds.intersects(cull) {
                draw(child, cull: cull, into: context)
            }
        }
        if layered {
            context.endTransparencyLayer()
        }
        context.restoreGState()
    }

    private func setFill(_ paint: Paint, in context: CGContext) {
        switch paint {
        case .solid(let color):
            context.setFillColor(color.cg)
        }
    }

    private func setStroke(_ paint: Paint, in context: CGContext) {
        switch paint {
        case .solid(let color):
            context.setStrokeColor(color.cg)
        }
    }

    private func apply(_ style: StrokeStyle, to context: CGContext) {
        context.setLineWidth(CGFloat(style.width))
        context.setLineCap(style.cap.cg)
        context.setLineJoin(style.join.cg)
        context.setMiterLimit(CGFloat(style.miterLimit))
        if !style.dash.isEmpty {
            context.setLineDash(phase: CGFloat(style.dashPhase), lengths: style.dash.map { CGFloat($0) })
        }
    }
}
