// How a placed image's pixels are treated before they are drawn (IMG-004;
// docs/_includes/imported/bitmaps.adoc and importing.adoc, `ImageProps`): the grayscale ramp,
// the tint and *Transparent* of bilevel and grayscale images, and *Display alpha channel*.
//
// The treatment is one deterministic CPU pass over 8-bit pixels (a 256-entry lookup table
// and straight arithmetic) rather than the `CIImage` pipeline the bitmaps page sketches, so
// the same image treats to the same bytes on every Mac and in both renderers.

import CoreGraphics
import Foundation

/// `ColorMode` of a placed image's pixel source.
public enum ImageMode: Hashable, Sendable, CaseIterable {
    case bilevel
    case grayscale
    case indexed
    case rgb
    case cmyk

    /// Whether the ramp, tint and *Transparent* apply (bilevel and grayscale only; the
    /// read-time rule ignores them on every other mode).
    public var isGray: Bool {
        self == .bilevel || self == .grayscale
    }
}

/// `GrayRamp`: a remapping of the gray levels of a bilevel or grayscale image.
public struct GrayRamp: Hashable, Sendable {
    public enum Preset: Hashable, Sendable, CaseIterable {
        case normal
        case inverted
        case lighten
        case darken
        case custom
    }

    public var preset: Preset
    /// -100 ... 100; read by `custom` only.
    public var lightness: Int
    /// -100 ... 100; read by `custom` only.
    public var contrast: Int

    public init(preset: Preset = .normal, lightness: Int = 0, contrast: Int = 0) {
        self.preset = preset
        self.lightness = lightness
        self.contrast = contrast
    }

    public static let normal = GrayRamp()

    /// The preset as read: `custom` with both values 0 reads as `normal` (bitmaps.adoc,
    /// read-time normalizations).
    public var effectivePreset: Preset {
        preset == .custom && lightness == 0 && contrast == 0 ? .normal : preset
    }

    /// Output gray level per input level (0 black ... 255 white).
    ///
    /// * normal: identity.  inverted: `255 - v`.
    /// * lighten: the range compressed into its upper half, `128 + v / 2`.
    /// * darken: the range compressed into its lower half, `v / 2`.
    /// * custom: with `v` in 0...1, contrast `c` and lightness `l` clamped to -100...100,
    ///   `v' = (v - 0.5) * k + 0.5 + l / 100`, where `k = 1 + c / 100` for `c <= 0` (down to a
    ///   flat mid gray at -100) and `k = 1 / (1 - 0.99 * c / 100)` above (up to a 100× slope,
    ///   nearly a threshold, at 100); the result is clamped and rounded to the nearest level.
    public func lut() -> [UInt8] {
        (0...255).map { level in
            switch effectivePreset {
            case .normal: return UInt8(level)
            case .inverted: return UInt8(255 - level)
            case .lighten: return UInt8(128 + level / 2)
            case .darken: return UInt8(level / 2)
            case .custom: return custom(level)
            }
        }
    }

    private func custom(_ level: Int) -> UInt8 {
        let c = Double(min(max(contrast, -100), 100)) / 100
        let l = Double(min(max(lightness, -100), 100)) / 100
        let k = c <= 0 ? 1 + c : 1 / (1 - 0.99 * c)
        let v = (Double(level) / 255 - 0.5) * k + 0.5 + l
        return UInt8((min(max(v, 0), 1) * 255).rounded())
    }
}

/// Everything about an image's settings that changes its treated pixels.  Two images with
/// equal treatments of the same blob share cache entries.
public struct ImageTreatment: Hashable, Sendable {
    public var mode: ImageMode
    public var ramp: GrayRamp
    /// The resolved tint as straight sRGB components 0...1; nil for none (black).
    public var tint: SIMD3<Double>?
    public var transparentBackground: Bool
    /// *Display alpha channel*.
    public var displayAlpha: Bool
    /// Whether the encoded file carries alpha (`PixelSource.has_alpha`).
    public var hasAlpha: Bool

    public init(
        mode: ImageMode = .rgb,
        ramp: GrayRamp = .normal,
        tint: SIMD3<Double>? = nil,
        transparentBackground: Bool = false,
        displayAlpha: Bool = true,
        hasAlpha: Bool = false
    ) {
        // The read-time rules: gray treatments exist only on bilevel and grayscale images, so
        // they are dropped here and equal settings on a colour image compare equal.
        let gray = mode.isGray
        self.mode = mode
        self.ramp = gray ? ramp : .normal
        self.tint = gray ? tint : nil
        self.transparentBackground = gray && transparentBackground
        self.displayAlpha = displayAlpha
        self.hasAlpha = hasAlpha
    }

    /// Whether the image's own alpha is shown: *Display alpha channel* on a file with alpha.
    public var usesAlpha: Bool { displayAlpha && hasAlpha }

    /// Whether gray treatment (ramp, tint or *Transparent*) changes the pixels.
    public var treatsGray: Bool {
        mode.isGray && (ramp.effectivePreset != .normal || tint != nil || transparentBackground)
    }

    /// Whether the decoded image can be drawn as it is: nothing to remap and no alpha to drop.
    /// The renderer then draws the decoded `CGImage` in its own colour space.
    public var isIdentity: Bool {
        !treatsGray && (usesAlpha || !hasAlpha)
    }

    /// The treated pixels as a premultiplied RGBA8 image in `space` (sRGB by default), or the
    /// image itself when `isIdentity`; nil only when no bitmap can be allocated.
    ///
    /// Gray treatment reads the image as 8-bit gray (in its own space when it is gray, else in
    /// Generic Gray 2.2), maps each level `v` through the ramp to `g = lut[v] / 255`, and writes
    /// `g · white + (1 − g) · tint` (the tint colours the dark pixels) or, with *Transparent*,
    /// the tint (black when none) at alpha `1 − g`.  The gray level passes into `space`
    /// numerically.  Without alpha shown, the image is composited over white and opaque.
    public func apply(to image: CGImage, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage? {
        if isIdentity {
            return image
        }
        let width = image.width
        let height = image.height
        guard let output = ImageTreatment.rgbaContext(width: width, height: height, space: space) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard treatsGray else {
            // Alpha dropped: the image over white.
            output.setFillColor(CGColor(gray: 1, alpha: 1))
            output.fill(rect)
            output.draw(image, in: rect)
            return output.makeImage()
        }
        let grayLevels = ImageTreatment.grayLevels(of: image)
        let alphaLevels = usesAlpha ? ImageTreatment.alphaLevels(of: image) : nil
        let table = ramp.lut()
        let ink = tint ?? SIMD3(0, 0, 0)
        let data = output.data!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = output.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let g = Double(table[Int(grayLevels[y * width + x])]) / 255
                var alpha = transparentBackground ? 1 - g : 1
                let color = transparentBackground ? ink : SIMD3(repeating: g) + (1 - g) * ink
                if let alphaLevels {
                    alpha *= Double(alphaLevels[y * width + x]) / 255
                }
                let offset = y * rowBytes + x * 4
                data[offset] = ImageTreatment.byte(color.x * alpha)
                data[offset + 1] = ImageTreatment.byte(color.y * alpha)
                data[offset + 2] = ImageTreatment.byte(color.z * alpha)
                data[offset + 3] = ImageTreatment.byte(alpha)
            }
        }
        return output.makeImage()
    }

    static func byte(_ value: Double) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }

    /// A premultiplied RGBA8 context, rows top-down in memory.
    static func rgbaContext(width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }

    /// One gray byte per pixel, row 0 at the top.  Transparent pixels read as the gray they
    /// would show over white, so a gray image with alpha keeps a defined level.
    static func grayLevels(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let space = image.colorSpace.flatMap { $0.model == .monochrome ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        var levels = [UInt8](repeating: 255, count: width * height)
        levels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return levels
    }

    /// One alpha byte per pixel, row 0 at the top.
    static func alphaLevels(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let context = rgbaContext(width: width, height: height, space: CGColorSpace(name: CGColorSpace.sRGB)!)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = context.bytesPerRow
        return (0..<(width * height)).map { data[($0 / width) * rowBytes + ($0 % width) * 4 + 3] }
    }
}
