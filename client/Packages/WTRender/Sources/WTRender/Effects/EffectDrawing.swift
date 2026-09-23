// Drawing effect nodes with Core Graphics (FX-006, FX-009, FX-015).  Plain items take the
// renderer's usual routes and transparency layers are Core Graphics transparency layers.  Raster
// and masked nodes are drawn into a *device layer*: a bitmap aligned with the destination's
// pixels covering the node, in which raster images are resampled per pixel and masks multiplied
// per pixel, then copied pixel for pixel into the destination.  The Metal renderer composites the
// same bitmap as a texture (`PaintListBuilder`), so both agree on every pixel by construction --
// the per-item Core Graphics texture fallback of the ATTR paints (docs/spec/client.adoc).  PDF
// output embeds each raster image at the object's resolution and masks through an image soft
// mask instead.

import CoreGraphics
import Foundation
import WTGeometry

extension AffineTransform {
    init(_ transform: CGAffineTransform) {
        self.init(a: Double(transform.a), b: Double(transform.b), c: Double(transform.c), d: Double(transform.d), tx: Double(transform.tx), ty: Double(transform.ty))
    }
}

/// A rectangle of whole pixels.
struct PixelRect: Hashable, Sendable {
    var minX: Int
    var minY: Int
    var width: Int
    var height: Int

    /// The pixels `rect` touches.
    init?(covering rect: Rect) {
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              max(abs(rect.minX), abs(rect.minY), abs(rect.maxX), abs(rect.maxY)) < 1e7
        else {
            return nil
        }
        minX = Int(rect.minX.rounded(.down))
        minY = Int(rect.minY.rounded(.down))
        width = Int(rect.maxX.rounded(.up)) - minX
        height = Int(rect.maxY.rounded(.up)) - minY
        guard width > 0, height > 0 else {
            return nil
        }
    }

    var rect: Rect { Rect(x: Double(minX), y: Double(minY), width: Double(width), height: Double(height)) }
}

extension CoreGraphicsRenderer {
    /// Effect nodes, bottom first, in the context's current user space (pasteboard points).
    func drawNodes(_ nodes: [EffectNode], state: DrawState, cull: Rect, into context: CGContext) {
        for node in nodes {
            guard let bounds = node.bounds, bounds.intersects(cull) else {
                continue
            }
            switch node {
            case .item(let item):
                draw(item, state: state, cull: cull, into: context)
            case .layer(let opacity, let content):
                context.saveGState()
                var inner = state
                if viewMode.drawsTransparencyGroups {
                    context.setAlpha(CGFloat(opacity))
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                    inner.alpha = 1
                    drawNodes(content, state: inner, cull: cull, into: context)
                    context.endTransparencyLayer()
                } else {
                    inner.alpha = state.alpha * opacity
                    context.setAlpha(CGFloat(inner.alpha))
                    drawNodes(content, state: inner, cull: cull, into: context)
                }
                context.restoreGState()
            case .masked(let mask):
                if !viewMode.drawsRasterEffects {
                    drawNodes(mask.content, state: state, cull: cull, into: context)
                } else if vectorOutput {
                    drawMaskForPDF(mask, state: state, cull: cull, into: context)
                } else {
                    drawDeviceLayer(node, into: context)
                }
            case .raster(let raster):
                if !viewMode.drawsRasterEffects {
                    drawNodes(raster.content, state: state, cull: cull, into: context)
                } else if rasterPreview == .off && !vectorOutput {
                    drawNodes(raster.content, state: state, cull: cull, into: context)
                    drawBadge(for: raster, into: context)
                } else if vectorOutput {
                    drawRasterForPDF(raster, state: state, cull: cull, into: context)
                } else {
                    drawDeviceLayer(node, into: context)
                }
            }
        }
    }

    // MARK: Device layers

    /// Pasteboard (the context's user space) → the bitmap's pixels, y down, row 0 at the top;
    /// nil for a context that is not a bitmap.
    static func pixelTransform(of context: CGContext) -> AffineTransform? {
        let height = context.height
        guard height > 0 else {
            return nil
        }
        return AffineTransform(context.ctm).concatenating(AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: Double(height)))
    }

    /// `node` through a device layer into the bitmap context `context`.
    private func drawDeviceLayer(_ node: EffectNode, into context: CGContext) {
        guard let toPixels = CoreGraphicsRenderer.pixelTransform(of: context), let bounds = node.bounds else {
            return
        }
        let clip = Rect(context.boundingBoxOfClipPath).applying(toPixels)
        let surface = Rect(x: 0, y: 0, width: Double(context.width), height: Double(context.height))
        guard let region = PixelRect(covering: bounds.applying(toPixels).intersection(clip).intersection(surface)),
              let image = deviceLayerImage(node, pasteboardToPixels: toPixels, region: region)
        else {
            return
        }
        CoreGraphicsRenderer.blit(image, at: region, into: context)
    }

    /// Copies premultiplied `image` onto `region` of the bitmap context, pixel for pixel,
    /// composited source-over (with the context's alpha).
    static func blit(_ image: TextureImage, at region: PixelRect, into context: CGContext) {
        guard let cgImage = image.cgImage else {
            return
        }
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: region.minX, y: context.height - region.minY - region.height, width: region.width, height: region.height))
        context.restoreGState()
    }

    /// `node` drawn into a bitmap covering `region` (pixels of the space `pasteboardToPixels`
    /// maps into), as premultiplied RGBA.  Every pixel depends on its position alone, so any two
    /// regions agree where they overlap.
    func deviceLayerImage(_ node: EffectNode, pasteboardToPixels: AffineTransform, region: PixelRect) -> TextureImage? {
        guard let surface = BitmapSurface(width: region.width, height: region.height) else {
            return nil
        }
        let context = surface.context
        context.translateBy(x: 0, y: CGFloat(region.height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(-region.minX), y: CGFloat(-region.minY))
        context.concatenate(pasteboardToPixels.cg)
        context.setFlatness(CGFloat(flatteningTolerance.devicePixels))
        drawLayerContent(node, pasteboardToPixels: pasteboardToPixels, region: region, into: context)
        return TextureImage(surface: surface)
    }

    private func drawLayerContent(_ node: EffectNode, pasteboardToPixels: AffineTransform, region: PixelRect, into context: CGContext) {
        let state = DrawState(canvasToBase: context.ctm)
        let cull = region.rect.applying(pasteboardToPixels.invertedOrIdentity)
        switch node {
        case .masked(let mask):
            guard let content = deviceLayerImage(.layer(opacity: 1, content: mask.content), pasteboardToPixels: pasteboardToPixels, region: region) else { return }
            let factors = TransparencyStage.maskFactors(mask, renderer: self, pasteboardToPixels: pasteboardToPixels, region: region)
            var bytes = content.bytes
            for index in 0..<(region.width * region.height) {
                let factor = factors[index]
                for channel in 0..<4 {
                    bytes[index * 4 + channel] = UInt8((Double(bytes[index * 4 + channel]) * factor).rounded())
                }
            }
            CoreGraphicsRenderer.blit(TextureImage(width: region.width, height: region.height, bytes: bytes), at: PixelRect(origin: region), into: context)
        case .raster(let raster):
            let resolution = rasterPreview.resolution(for: raster.settings, deviceScale: pasteboardToPixels.scaleFactor)
            guard let result = rasterResult(raster, resolution: resolution) else {
                drawNodes(raster.content, state: state, cull: cull, into: context)
                drawBadge(for: raster, into: context)
                return
            }
            for image in result.below {
                CoreGraphicsRenderer.blit(CoreGraphicsRenderer.resample(image, pasteboardToPixels: pasteboardToPixels, region: region), at: PixelRect(origin: region), into: context)
            }
            if let replaced = result.replaced {
                CoreGraphicsRenderer.blit(CoreGraphicsRenderer.resample(replaced, pasteboardToPixels: pasteboardToPixels, region: region), at: PixelRect(origin: region), into: context)
            } else {
                drawNodes(raster.content, state: state, cull: cull, into: context)
            }
            for image in result.above {
                CoreGraphicsRenderer.blit(CoreGraphicsRenderer.resample(image, pasteboardToPixels: pasteboardToPixels, region: region), at: PixelRect(origin: region), into: context)
            }
        case .item, .layer:
            drawNodes([node], state: state, cull: cull, into: context)
        }
    }

    /// `image` sampled at the centre of every pixel of `region`.
    static func resample(_ image: RasterImage, pasteboardToPixels: AffineTransform, region: PixelRect) -> TextureImage {
        let toPasteboard = pasteboardToPixels.invertedOrIdentity
        var bytes = [UInt8](repeating: 0, count: region.width * region.height * 4)
        for row in 0..<region.height {
            for column in 0..<region.width {
                let point = toPasteboard.apply(Point(x: Double(region.minX + column) + 0.5, y: Double(region.minY + row) + 0.5))
                let color = image.sample(point)
                let offset = (row * region.width + column) * 4
                for channel in 0..<4 {
                    bytes[offset + channel] = UInt8(min(max(color[channel], 0), 255).rounded())
                }
            }
        }
        return TextureImage(width: region.width, height: region.height, bytes: bytes)
    }

    /// The node's raster images at `resolution`: cached, rendered now or, with a progressive
    /// renderer, in the background (nil until ready).
    func rasterResult(_ raster: RasterNode, resolution: Double) -> RasterResult? {
        let key = RasterEffectCache.Key(node: raster, resolution: resolution)
        let renderer = self.forRasterContent
        let render: @Sendable () -> RasterResult? = {
            RasterEffectStage.render(raster, resolution: resolution) { context in
                renderer.drawNodes(raster.content, state: DrawState(canvasToBase: context.ctm), cull: Rect(context.boundingBoxOfClipPath), into: context)
            }
        }
        if let ready = rasterEffectsReady {
            let area = EffectNode.raster(raster).bounds ?? .null
            return rasterCache.progressiveResult(for: key, area: area, ready: ready, render: render)
        }
        return rasterCache.result(for: key, render: render)
    }

    /// The renderer raster content is drawn with: Preview, synchronous, into a bitmap.
    var forRasterContent: CoreGraphicsRenderer {
        var result = CoreGraphicsRenderer(flatteningTolerance: flatteningTolerance, viewMode: .preview)
        result.rasterPreview = .document
        result.rasterCache = rasterCache
        return result
    }

    /// The "rendering" badge: a small grey disc at the top-right corner of the content, six
    /// device pixels across.
    func drawBadge(for raster: RasterNode, into context: CGContext) {
        guard let badge = CoreGraphicsRenderer.badge(for: raster, pixelSize: Double(hairlineUnit(in: context))) else {
            return
        }
        context.saveGState()
        context.addPath(badge.cgPath)
        context.setFillColor(CoreGraphicsRenderer.badgeColor.cg)
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    static let badgeColor = Color(white: 0.45, alpha: 0.85)

    /// The badge's disc in pasteboard space for a device pixel of `pixelSize` points.
    static func badge(for raster: RasterNode, pixelSize: Double) -> DisplayPath? {
        guard let bounds = EffectNode.union(raster.content), pixelSize.isFinite, pixelSize > 0 else {
            return nil
        }
        let edge = 6 * pixelSize
        return DisplayPath(ellipseIn: Rect(x: bounds.maxX - edge, y: bounds.minY, width: edge, height: edge))
    }

    /// One device pixel in the context's user space.
    func hairlineUnit(in context: CGContext) -> CGFloat {
        let ctm = context.ctm
        let scale = abs(ctm.a * ctm.d - ctm.b * ctm.c).squareRoot()
        return 1 / max(scale, 1e-12)
    }

    // MARK: PDF

    /// Raster images placed at their pasteboard rectangles, the content vector unless replaced.
    private func drawRasterForPDF(_ raster: RasterNode, state: DrawState, cull: Rect, into context: CGContext) {
        guard let result = rasterResult(raster, resolution: raster.settings.effectiveResolution) else {
            drawNodes(raster.content, state: state, cull: cull, into: context)
            return
        }
        for image in result.below {
            CoreGraphicsRenderer.place(image, into: context)
        }
        if let replaced = result.replaced {
            CoreGraphicsRenderer.place(replaced, into: context)
        } else {
            drawNodes(raster.content, state: state, cull: cull, into: context)
        }
        for image in result.above {
            CoreGraphicsRenderer.place(image, into: context)
        }
    }

    /// Draws `image` over its pasteboard rectangle in the (y-down) user space.
    static func place(_ image: RasterImage, into context: CGContext) {
        guard let picture = image.cgImage else {
            return
        }
        let rect = image.rect
        context.saveGState()
        // Core Graphics draws row 0 at the rectangle's largest y; the image's row 0 is its top.
        context.translateBy(x: 0, y: CGFloat(rect.minY + rect.maxY))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .default
        context.draw(picture, in: rect.cg)
        context.restoreGState()
    }

    /// The content clipped through a soft mask of the gradient's inverse luminance, sampled at
    /// the PDF raster scale.
    private func drawMaskForPDF(_ mask: MaskNode, state: DrawState, cull: Rect, into context: CGContext) {
        guard let bounds = EffectNode.union(mask.content),
              let image = TransparencyStage.maskImage(mask, renderer: self, bounds: bounds, pixelsPerPoint: max(rasterScale, 1))
        else {
            drawNodes(mask.content, state: state, cull: cull, into: context)
            return
        }
        context.saveGState()
        let flip = CGAffineTransform(translationX: 0, y: CGFloat(image.rect.minY + image.rect.maxY)).scaledBy(x: 1, y: -1)
        context.concatenate(flip)
        context.clip(to: image.rect.cg, mask: image.picture)
        context.concatenate(flip.inverted())
        drawNodes(mask.content, state: state, cull: cull, into: context)
        context.restoreGState()
    }
}

extension PixelRect {
    /// A region of the same size at a layer's own origin: where a layer's bitmap sits in itself.
    init(origin region: PixelRect) {
        minX = 0
        minY = 0
        width = region.width
        height = region.height
    }
}

extension TextureImage {
    /// The surface's pixels, rows without padding.
    init(surface: BitmapSurface) {
        let rowBytes = surface.context.bytesPerRow
        let source = surface.context.data!.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: surface.width * surface.height * 4)
        for row in 0..<surface.height {
            for column in 0..<(surface.width * 4) {
                bytes[row * surface.width * 4 + column] = source[row * rowBytes + column]
            }
        }
        self.init(width: surface.width, height: surface.height, bytes: bytes)
    }

    /// As a Core Graphics image; nil for an empty one.
    var cgImage: CGImage? {
        guard let surface = BitmapSurface(width: width, height: height) else {
            return nil
        }
        let data = surface.context.data!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.context.bytesPerRow
        for row in 0..<height {
            for column in 0..<(width * 4) {
                data[row * rowBytes + column] = bytes[row * width * 4 + column]
            }
        }
        return surface.makeImage()
    }
}
