// The working buffer of a raster stage and its Core Image bridge (FX-009).  Pixels are
// premultiplied RGBA floats, row 0 at the top.  Core Image runs the blur, morphology and
// compositing graphs; the distance fields, lighting and threshold arithmetic Core Image has no
// filter for are plain loops over the same buffer.

import CoreGraphics
import CoreImage
import Foundation

struct RasterPixels: Sendable {
    let width: Int
    let height: Int
    /// Premultiplied RGBA, 0 ... 1, row-major from the top.
    var data: [Float]

    init(width: Int, height: Int, data: [Float]? = nil) {
        self.width = width
        self.height = height
        self.data = data ?? [Float](repeating: 0, count: width * height * 4)
    }

    var count: Int { width * height }

    func alpha(_ index: Int) -> Float { data[index * 4 + 3] }

    /// Every pixel's alpha.
    var alphas: [Float] {
        (0..<count).map { data[$0 * 4 + 3] }
    }

    /// Source-over `top` onto this buffer.
    mutating func composite(over top: RasterPixels) {
        for index in 0..<count {
            let a = top.data[index * 4 + 3]
            for channel in 0..<4 {
                data[index * 4 + channel] = top.data[index * 4 + channel] + data[index * 4 + channel] * (1 - a)
            }
        }
    }

    /// Eight-bit premultiplied RGBA, rounded.
    var bytes: [UInt8] {
        data.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
    }

    init(bytes: [UInt8], width: Int, height: Int) {
        self.init(width: width, height: height, data: bytes.map { Float($0) / 255 })
    }
}

/// The Core Image side: one context for colour-managed work, one for Optimal CMYK (no colour
/// management, as the setting's description says).
enum RasterCore {
    static let colorSpace = CoreGraphicsRenderer.colorSpace

    static let managed = CIContext(options: [
        .workingColorSpace: CoreGraphicsRenderer.colorSpace,
        .outputColorSpace: CoreGraphicsRenderer.colorSpace,
        .cacheIntermediates: false,
    ])

    static let unmanaged = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])

    static func context(optimalCMYK: Bool) -> CIContext {
        optimalCMYK ? unmanaged : managed
    }

    static func image(_ pixels: RasterPixels) -> CIImage {
        let data = pixels.data.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: pixels.width * 16, size: CGSize(width: pixels.width, height: pixels.height), format: .RGBAf, colorSpace: colorSpace)
    }

    /// `image` over the buffer's extent (0, 0, width, height), transparent where it has nothing.
    static func render(_ image: CIImage, width: Int, height: Int, context: CIContext) -> RasterPixels {
        var data = [Float](repeating: 0, count: width * height * 4)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let bounded = image.cropped(to: extent).composited(over: clear)
        data.withUnsafeMutableBytes { buffer in
            context.render(bounded, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: colorSpace)
        }
        return RasterPixels(width: width, height: height, data: data)
    }

    static func filter(_ name: String, _ parameters: [String: Any]) -> CIImage {
        // Every filter used here exists on every supported macOS; a missing one is a bug.
        let filter = CIFilter(name: name, parameters: parameters)!
        return filter.outputImage!
    }

    /// A flat colour (premultiplied by `opacity`) everywhere.
    static func color(_ color: Color, opacity: Double) -> CIImage {
        let alpha = min(max(color.alpha * opacity, 0), 1)
        return CIImage(color: CIColor(red: color.red * alpha, green: color.green * alpha, blue: color.blue * alpha, alpha: alpha, colorSpace: colorSpace)!)
    }

    static func gaussian(_ image: CIImage, sigma: Double) -> CIImage {
        guard sigma > 0 else { return image }
        return filter("CIGaussianBlur", [kCIInputImageKey: image, kCIInputRadiusKey: sigma])
    }

    static func box(_ image: CIImage, radius: Double) -> CIImage {
        guard radius > 0 else { return image }
        return filter("CIBoxBlur", [kCIInputImageKey: image, kCIInputRadiusKey: radius])
    }

    static func dilate(_ image: CIImage, radius: Double) -> CIImage {
        guard radius > 0 else { return image }
        return filter("CIMorphologyMaximum", [kCIInputImageKey: image, kCIInputRadiusKey: radius])
    }

    /// `source` where `mask` has alpha.
    static func sourceIn(_ source: CIImage, _ mask: CIImage) -> CIImage {
        filter("CISourceInCompositing", [kCIInputImageKey: source, kCIInputBackgroundImageKey: mask])
    }

    /// `source` where `mask` has none.
    static func sourceOut(_ source: CIImage, _ mask: CIImage) -> CIImage {
        filter("CISourceOutCompositing", [kCIInputImageKey: source, kCIInputBackgroundImageKey: mask])
    }
}
