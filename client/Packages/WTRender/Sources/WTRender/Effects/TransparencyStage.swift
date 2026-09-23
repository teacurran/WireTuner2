// Transparency (FX-015; transparency.adoc, "Client").  Basic is a transparency layer at
// `1 − amount/100` around the object's drawables (object level) or one drawable (fill or stroke
// level), which the pipeline expresses as an `EffectNode.layer` and both renderers draw as they
// draw a translucent group, so the stroke does not show through the fill under object-level Basic
// and does under fill-level Basic.  Gradient Mask multiplies the content by `1 − luminance` of
// the gradient, painted by the gradient fill code in the object's space: per device pixel in a
// device layer on screen, as an image soft mask at the PDF raster scale in PDF.  Feather is a
// raster operation (`Feather`).

import CoreGraphics
import Foundation
import WTGeometry

enum TransparencyStage {
    /// The mask value of a stop colour: Rec. 709 luminance of the sRGB components.
    static func luminance(_ color: Color) -> Double {
        min(max(0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue, 0), 1)
    }

    /// The factor a premultiplied gradient pixel scales content by: `1 − luminance`, weighted by
    /// the gradient's own alpha (a transparent part of the ramp masks nothing).
    static func factor(red: Double, green: Double, blue: Double, alpha: Double) -> Double {
        guard alpha > 0 else {
            return 1
        }
        let straight = Color(red: red / alpha, green: green / alpha, blue: blue / alpha)
        return 1 - luminance(straight) * alpha
    }

    /// The mask's gradient painted over `region` of the pixel space `pasteboardToPixels` maps
    /// into, as RGBA.
    static func paint(_ mask: MaskNode, renderer: CoreGraphicsRenderer, pasteboardToPixels: AffineTransform, region: PixelRect) -> TextureImage? {
        guard let surface = BitmapSurface(width: region.width, height: region.height) else {
            return nil
        }
        let context = surface.context
        context.translateBy(x: 0, y: CGFloat(region.height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(-region.minX), y: CGFloat(-region.minY))
        context.concatenate(pasteboardToPixels.cg)
        let canvasToBase = context.ctm
        context.concatenate(mask.frame.cg)
        // A mask's gradient is transparency, not colour: never converted or proofed.
        let environment = PaintEnvironment(renderer: renderer.with(colorManagement: .standard), canvasToBase: canvasToBase, path: mask.region, rule: mask.rule, rasterScale: 1, canvas: nil, indexPath: [], lensDepth: 0)
        PaintDrawing.fill(.gradient(mask.gradient), in: context, environment: environment)
        return TextureImage(surface: surface)
    }

    /// The per-pixel factors of `region`, row-major.
    static func maskFactors(_ mask: MaskNode, renderer: CoreGraphicsRenderer, pasteboardToPixels: AffineTransform, region: PixelRect) -> [Double] {
        guard let painted = paint(mask, renderer: renderer, pasteboardToPixels: pasteboardToPixels, region: region) else {
            return [Double](repeating: 1, count: region.width * region.height)
        }
        return (0..<(region.width * region.height)).map { index in
            let pixel = painted.bytes[(index * 4)..<(index * 4 + 4)].map { Double($0) / 255 }
            return factor(red: pixel[0], green: pixel[1], blue: pixel[2], alpha: pixel[3])
        }
    }

    /// A soft mask for PDF output: the factors over `bounds` (pasteboard) at `pixelsPerPoint`,
    /// as a grey image and the rectangle it covers.
    static func maskImage(_ mask: MaskNode, renderer: CoreGraphicsRenderer, bounds: Rect, pixelsPerPoint: Double) -> (picture: CGImage, rect: Rect)? {
        let toPixels = AffineTransform.scale(pixelsPerPoint)
        guard let region = PixelRect(covering: bounds.applying(toPixels)), region.width <= 8192, region.height <= 8192 else {
            return nil
        }
        let factors = maskFactors(mask, renderer: renderer, pasteboardToPixels: toPixels, region: region)
        let bytes = factors.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let picture = CGImage(width: region.width, height: region.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: region.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            return nil
        }
        return (picture, region.rect.applying(.scale(1 / pixelsPerPoint)))
    }
}
