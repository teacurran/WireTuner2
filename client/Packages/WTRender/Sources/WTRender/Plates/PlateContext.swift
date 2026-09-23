// Plate mode (PRINT-007; docs/_includes/printing/output-devices.adoc, "Plate mode in WTRender").
// The composite display list is drawn once per plate by the Core Graphics reference renderer
// with a `PlateContext`, which maps every colour before it reaches Core Graphics: a colour
// resolves to ink coverages -- process colours directly, spot colours as their tint of their
// own ink (or as their process alternate with *Print spot colors as process*), RGB, Lab and
// OKLab through Working CMYK -- and paints gray `1 - coverage` on the plate.  Coverage 0
// paints white (knockout) unless the paint overprints, when it paints nothing.  The sheet
// starts white; registration colour is black on every plate.
//
// Gray is written as a neutral sRGB colour on an sRGB surface, so the plate's 8-bit gray is
// the colour's own value with no conversion; blending and transparency groups composite
// `1 - coverage` exactly as they composite ink coverage.

import CoreGraphics
import Foundation
import WTGeometry

/// Maps colours, paints and images onto one plate.
public struct PlateContext: Hashable, Sendable {
    public var plate: Ink
    /// *Print spot colors as process*: spot colours resolve to their process alternate.
    public var spotAsProcess: Bool
    /// Working CMYK, the intent and black point compensation RGB and Lab colours separate
    /// through.  The working space and proof play no part.
    public var colorManagement: ColorManagement

    /// Stops inserted between two gradient stops so the plate ramp is linear in coverage (the
    /// renderer interpolates ramps in OKLab; between close grays that is linear within 1/255).
    public static let gradientSubdivisions = 128

    public init(plate: Ink, spotAsProcess: Bool = false, colorManagement: ColorManagement = .standard) {
        self.plate = plate
        self.spotAsProcess = spotAsProcess
        self.colorManagement = colorManagement
    }

    // MARK: Coverage

    /// Every ink `color` prints with.
    public func inks(of color: Color) -> InkCoverage {
        if let spot = color.spot {
            switch spot.identity {
            case .registration:
                return InkCoverage(registration: spot.tint)
            case .swatch(let id) where !spotAsProcess:
                return InkCoverage(spots: [id: spot.tint])
            case .swatch:
                break
            }
        }
        let cmyk = processComponents(of: color)
        return InkCoverage(cyan: cmyk.x, magenta: cmyk.y, yellow: cmyk.z, black: cmyk.w)
    }

    /// The coverage of this context's plate by `color`, 0...1.
    public func coverage(of color: Color) -> Double {
        inks(of: color)[plate]
    }

    /// The colour's process inks: its own components for CMYK, otherwise converted into Working
    /// CMYK with the document's intent and black point compensation.
    func processComponents(of color: Color) -> SIMD4<Double> {
        if color.space == .cmyk {
            return color.components.clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 1))
        }
        let values = colorManagement.converter.convert(color, to: workingCMYK, intent: colorManagement.intent, blackPointCompensation: colorManagement.blackPointCompensation)!
        return SIMD4(values[0], values[1], values[2], values[3])
    }

    /// Working CMYK, or the bundled Default CMYK while a custom profile's blob is not local.
    var workingCMYK: WTColor.ProfileRef {
        let registry = colorManagement.converter.registry
        return registry.colorSpace(for: colorManagement.cmykProfile) == nil ? registry.defaultCMYK : colorManagement.cmykProfile
    }

    /// The gray `color` paints on the plate (`1 - coverage`, keeping its alpha), or nil when it
    /// paints nothing: an overprinting paint with no coverage on this plate.
    public func plateColor(_ color: Color, overprint: Bool = false) -> Color? {
        let coverage = coverage(of: color)
        if coverage <= 0 && overprint {
            return nil
        }
        return Color(white: 1 - coverage, alpha: color.alpha)
    }

    // MARK: Paints

    /// `paint` as it paints on the plate: solid colours and every sampled paint's colours
    /// mapped (a gradient's stops, subdivided so the plate ramp is linear in coverage), a Tiled
    /// fill unchanged (its tile is drawn through the renderer, which maps it).  An overprinting
    /// paint that covers nothing on the plate becomes None.
    func paint(_ paint: Paint, overprint: Bool) -> Paint {
        func mapped(_ color: Color) -> Color {
            Color(white: 1 - coverage(of: color), alpha: color.alpha)
        }
        switch paint {
        case .none, .tiled:
            return paint
        case .solid(let color):
            return plateColor(color, overprint: overprint).map(Paint.solid) ?? .none
        case .gradient(var gradient):
            let stops = gradient.sortedStops
            if overprint, stops.allSatisfy({ coverage(of: $0.color) <= 0 }) {
                return .none
            }
            gradient.stops = PlateContext.linearStops(stops.map { Gradient.Stop(offset: $0.offset, color: mapped($0.color)) })
            return .gradient(gradient)
        case .pattern(var pattern):
            guard let color = plateColor(pattern.color, overprint: overprint) else { return .none }
            pattern.color = color
            return .pattern(pattern)
        case .custom(var custom):
            custom.color = mapped(custom.color)
            custom.color2 = mapped(custom.color2)
            return .custom(custom)
        case .textured(var textured):
            guard let color = plateColor(textured.color, overprint: overprint) else { return .none }
            textured.color = color
            return .textured(textured)
        case .lens(var lens):
            lens.color = mapped(lens.color)
            return .lens(lens)
        }
    }

    /// Mapped gray stops with `gradientSubdivisions - 1` stops inserted between each pair,
    /// interpolated linearly in gray value and alpha.
    static func linearStops(_ stops: [Gradient.Stop]) -> [Gradient.Stop] {
        guard stops.count > 1 else {
            return stops
        }
        var result: [Gradient.Stop] = [stops[0]]
        for (lower, upper) in zip(stops, stops.dropFirst()) {
            for step in 1...gradientSubdivisions {
                let t = Double(step) / Double(gradientSubdivisions)
                let gray = lower.color.red + (upper.color.red - lower.color.red) * t
                let alpha = lower.color.alpha + (upper.color.alpha - lower.color.alpha) * t
                result.append(Gradient.Stop(offset: lower.offset + (upper.offset - lower.offset) * t, color: Color(white: gray, alpha: alpha)))
            }
        }
        return result
    }

    // MARK: Images

    /// A decoded image's channel for this plate: the image separated into Working CMYK (a CMYK
    /// image contributes its own channel) and the plate's ink written as `1 - coverage` gray
    /// with the image's alpha, cached per image and plate.  Spot plates are white under the
    /// image (it knocks out).
    func channelImage(_ image: CGImage) -> CGImage {
        PlateImageCache.shared.channel(of: image, context: self)
    }

    /// The separation of `image` without the cache: a CMYK image's own channel (drawn into
    /// Working CMYK, which leaves an image already in it unchanged); any other image drawn into
    /// sRGB and converted pixel by pixel through the same ColorSync chain as solid colours.
    func separate(_ image: CGImage) -> CGImage {
        let width = image.width, height = image.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let channel: Int?
        switch plate {
        case .cyan: channel = 0
        case .magenta: channel = 1
        case .yellow: channel = 2
        case .black: channel = 3
        case .spot: channel = nil
        }
        // A decoded level always has a size Core Graphics can allocate.
        let alphaContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        alphaContext.draw(image, in: rect)
        let alpha = alphaContext.data!.assumingMemoryBound(to: UInt8.self)
        // Straight ink coverage, 0...255, per pixel.
        var ink = [UInt8](repeating: 0, count: width * height)
        if let channel {
            if image.colorSpace?.model == .cmyk {
                cmykChannel(image, channel: channel, into: &ink)
            } else {
                rgbChannel(image, channel: channel, alpha: alpha, alphaRow: alphaContext.bytesPerRow, into: &ink)
            }
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column
                let a = Int(alpha[row * alphaContext.bytesPerRow + column])
                let gray = UInt8((255 - Int(ink[index])) * a / 255)
                pixels[index * 4] = gray
                pixels[index * 4 + 1] = gray
                pixels[index * 4 + 2] = gray
                pixels[index * 4 + 3] = UInt8(a)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CoreGraphicsRenderer.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    private func cmykChannel(_ image: CGImage, channel: Int, into ink: inout [UInt8]) {
        let converter = colorManagement.converter
        let space = converter.registry.colorSpace(for: workingCMYK)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setRenderingIntent(colorManagement.intent.cg)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for index in ink.indices {
            ink[index] = data[index * 4 + channel]
        }
    }

    private func rgbChannel(_ image: CGImage, channel: Int, alpha: UnsafeMutablePointer<UInt8>, alphaRow: Int, into ink: inout [UInt8]) {
        let converter = colorManagement.converter
        let width = image.width, height = image.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CoreGraphicsRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        let profile = workingCMYK
        let step = { (ref: WTColor.ProfileRef) in WTColor.ChainStep(profile: ref, intent: colorManagement.intent, blackPointCompensation: colorManagement.blackPointCompensation) }
        let transform = converter.transform([step(converter.registry.sRGB), step(profile)])!
        var input = [Double](repeating: 0, count: width * height * 3)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column
                let a = Double(alpha[row * alphaRow + column])
                guard a > 0 else { continue }
                for component in 0..<3 {
                    input[index * 3 + component] = min(Double(data[index * 4 + component]) / a, 1)
                }
            }
        }
        let output = transform.convert(input)
        for index in ink.indices {
            ink[index] = UInt8((output[index * 4 + channel] * 255).rounded())
        }
    }
}

/// Separated image channels, keyed by the image object and the plate context (images are
/// separated per level, not per frame or tile).
final class PlateImageCache: @unchecked Sendable {
    static let shared = PlateImageCache()
    static let capacity = 64

    private let lock = NSLock()
    /// Entries hold their source image, so an identifier is never reused while cached.
    private var entries: [Key: (source: CGImage, result: CGImage)] = [:]
    private var order: [Key] = []

    private struct Key: Hashable {
        var image: ObjectIdentifier
        var context: PlateContext
    }

    /// How many separations have been computed (the cache's test hook).
    private(set) var separations = 0

    func channel(of image: CGImage, context: PlateContext) -> CGImage {
        let key = Key(image: ObjectIdentifier(image), context: context)
        if let cached = lock.withLock({ entries[key] }) {
            return cached.result
        }
        let result = context.separate(image)
        lock.withLock {
            separations += 1
            if entries[key] == nil {
                order.append(key)
            }
            entries[key] = (image, result)
            while order.count > PlateImageCache.capacity {
                entries[order.removeFirst()] = nil
            }
        }
        return result
    }
}
