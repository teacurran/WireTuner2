// CMYK conversion for print output (EPS *Convert to CMYK*, PDF/X-1a, PDF *Convert to CMYK*): a
// pluggable converter, whose standard implementation converts into a CMYK profile from WTColor's
// `ProfileRegistry` -- the bundled Default CMYK (ColorSync's Generic CMYK) until the export dialog
// passes the document's Working CMYK or a PDF/X destination profile.  That profile is also what
// PDF/X output intents name and embed.  Colours are converted by ColorSync through Core Graphics
// from their tagged `CGColor` (`ColorManagement.taggedCGColor`), the same path images take by
// drawing into the profile's CMYK context: WTColor's `Converter` maps sRGB white to about 11% cyan
// and 8% magenta in Generic CMYK under relative colorimetric -- an absolute-colorimetric result --
// where Core Graphics gives paper white, so it is not used here until that is resolved.

import CoreGraphics
import Foundation
import WTRender

/// Converts colours and images to one CMYK output condition.
public protocol CMYKConverter: Sendable {
    /// The profile's name for reports.
    var name: String { get }
    /// The PDF/X `OutputConditionIdentifier`.
    var outputConditionIdentifier: String { get }
    /// The ICC profile written as the output intent's `DestOutputProfile`.
    var iccProfile: Data { get }
    /// `color` (any space, alpha ignored) as C, M, Y, K in 0 ... 1 (1 = full ink).  A CMYK
    /// colour keeps its inks.
    func cmyk(_ color: Color) -> [Double]
    /// `image` composited over white and converted: 4 bytes per pixel (C, M, Y, K; 255 = full
    /// ink), rows top to bottom.
    func cmykPixels(_ image: CGImage) -> Data
}

/// Conversion into a CMYK profile of the registry.
public struct ProfileCMYKConverter: CMYKConverter {
    public var profile: WTColor.ProfileRef
    public var intent: WTColor.RenderingIntent
    public var registry: WTColor.ProfileRegistry

    /// A converter into `profile` (the bundled Default CMYK when nil, not a CMYK profile, or not
    /// available on this Mac yet).
    public init(profile: WTColor.ProfileRef? = nil, intent: WTColor.RenderingIntent = .relativeColorimetric, registry: WTColor.ProfileRegistry = .shared) {
        let resolved = registry.resolve(profile, default: registry.defaultCMYK)
        self.profile = resolved.pending || resolved.profile.space != .cmyk ? registry.defaultCMYK : resolved.profile
        self.intent = intent
        self.registry = registry
    }

    public var name: String { profile.name }
    public var outputConditionIdentifier: String { profile.name }

    public var iccProfile: Data {
        // The profile resolved to one whose data is available.
        registry.iccData(for: profile)!
    }

    var colorSpace: CGColorSpace {
        registry.colorSpace(for: profile)!
    }

    public func cmyk(_ color: Color) -> [Double] {
        if color.space == .cmyk {
            let c = color.clampedToSpace.components
            return [c.x, c.y, c.z, c.w]
        }
        // The profile is available (resolved at init) and every tagged colour converts into it.
        let tagged = ColorManagement.standard.taggedCGColor(color)
        let converted = tagged.converted(to: colorSpace, intent: intent.cg, options: nil)!
        return converted.components!.prefix(4).map { min(max(Double($0), 0), 1) }
    }

    public func cmykPixels(_ image: CGImage) -> Data {
        let width = image.width, height = image.height
        var bytes = Data(count: width * height * 4)
        let space = colorSpace
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setRenderingIntent(intent.cg)
            context.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 0, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
