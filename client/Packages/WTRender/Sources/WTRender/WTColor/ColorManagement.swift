// The renderer's colour pipeline (CMS-006, CMS-007; docs/_includes/cms/color-management.adoc,
// "Client"): which space tiles are rendered in, how each tagged `Color` reaches it, and the
// soft proof.  Both renderers ask this one value for every colour they draw, so Metal and Core
// Graphics put the same numbers into the same space (REND-007) and print and screen agree.
//
// Tile contexts, bitmaps and the Metal canvas are tagged with the working space (Display P3
// on the app's canvas) and the window server matches them to the display, so a wide-gamut
// colour survives to a P3 screen and is clipped by ColorSync on an sRGB one.  Colours in the
// tile's own space are drawn as they are; sRGB, Display P3, CIELAB and OKLab are converted by
// the exact formulas and clipped per channel; CMYK goes through the Working CMYK profile with
// the document's intent and black point compensation.  With a proof, every colour goes through
// the proof chain instead.  PDF output carries the colours tagged in their own spaces.

import CoreGraphics
import Foundation

/// How a renderer turns tagged colours into pixels.  A value: changing any part of it is a
/// whole-canvas repaint (color-management.adoc, "Invalidation").
public struct ColorManagement: Hashable, Sendable {
    /// The RGB space tile contexts, bitmaps and canvases are rendered in and tagged with.
    public enum WorkingSpace: Hashable, Sendable {
        case sRGB
        case displayP3

        public var colorSpace: CGColorSpace {
            self == .sRGB ? WTColor.Spaces.sRGB : WTColor.Spaces.displayP3
        }

        var space: Color.Space { self == .sRGB ? .sRGB : .displayP3 }
    }

    public var workingSpace: WorkingSpace
    /// Working CMYK: the profile every CMYK colour is interpreted through.
    public var cmykProfile: WTColor.ProfileRef
    /// The document intent.
    public var intent: WTColor.RenderingIntent
    public var blackPointCompensation: Bool
    /// The soft proof (View > Proof Colors on in this window), or nil.
    public var proof: WTColor.ProofSetup?
    /// The conversion service; not part of the value's identity.
    public let converter: WTColor.Converter

    public init(
        workingSpace: WorkingSpace = .sRGB,
        cmykProfile: WTColor.ProfileRef? = nil,
        intent: WTColor.RenderingIntent = .relativeColorimetric,
        blackPointCompensation: Bool = true,
        proof: WTColor.ProofSetup? = nil,
        converter: WTColor.Converter = .shared
    ) {
        self.workingSpace = workingSpace
        self.cmykProfile = cmykProfile ?? converter.registry.defaultCMYK
        self.intent = intent
        self.blackPointCompensation = blackPointCompensation
        self.proof = proof
        self.converter = converter
    }

    /// sRGB tiles, Default CMYK, relative colorimetric with black point compensation, no proof.
    public static let standard = ColorManagement()

    public static func == (lhs: ColorManagement, rhs: ColorManagement) -> Bool {
        lhs.workingSpace == rhs.workingSpace && lhs.cmykProfile == rhs.cmykProfile && lhs.intent == rhs.intent
            && lhs.blackPointCompensation == rhs.blackPointCompensation && lhs.proof == rhs.proof
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(workingSpace)
        hasher.combine(cmykProfile)
        hasher.combine(intent)
        hasher.combine(blackPointCompensation)
        hasher.combine(proof)
    }

    /// The same pipeline with `proof`.
    public func with(proof: WTColor.ProofSetup?) -> ColorManagement {
        var result = self
        result.proof = proof
        return result
    }

    /// The working space's profile.
    var workingProfile: WTColor.ProfileRef {
        workingSpace == .sRGB ? converter.registry.sRGB : converter.registry.displayP3
    }

    /// The working space as a colour space.
    public var colorSpace: CGColorSpace { workingSpace.colorSpace }

    // MARK: Colours

    /// `color` in the working space: gamma-encoded RGB and the colour's alpha.  A colour
    /// already in the working space is used as stored.
    public func workingComponents(_ color: Color) -> SIMD4<Double> {
        let rgb = workingRGB(color)
        return SIMD4(rgb.x, rgb.y, rgb.z, color.alpha)
    }

    func workingRGB(_ color: Color) -> SIMD3<Double> {
        if let proof {
            let chain = proof.chain(from: WTColor.ChainStep(profile: nil, intent: proof.intent, blackPointCompensation: proof.blackPointCompensation), to: workingProfile)
            if let values = converter.convert(color, through: chain, cmykProfile: cmykProfile) {
                return SIMD3(values[0], values[1], values[2])
            }
        }
        switch color.space {
        case workingSpace.space:
            return SIMD3(color.components.x, color.components.y, color.components.z)
        case .cmyk:
            // The bundled profiles are always available, so only a missing custom Working
            // CMYK (a pending blob) falls back to the bundled Default CMYK.
            let profile = converter.registry.colorSpace(for: cmykProfile) == nil ? converter.registry.defaultCMYK : cmykProfile
            let values = converter.convert(color, to: workingProfile, cmykProfile: profile, intent: intent, blackPointCompensation: blackPointCompensation)!
            return SIMD3(values[0], values[1], values[2])
        default:
            return WTColor.Math.clipped(WTColor.Math.rgb(color, in: workingSpace.space))
        }
    }

    /// The colour a bitmap surface fills with: `workingComponents` in the working space (an
    /// sRGB colour on sRGB tiles is the plain sRGB `CGColor`, bit for bit what it always was).
    public func cgColor(_ color: Color) -> CGColor {
        if proof == nil, color.space == workingSpace.space {
            return workingSpace == .sRGB
                ? CGColor(srgbRed: color.components.x, green: color.components.y, blue: color.components.z, alpha: color.alpha)
                : CGColor(colorSpace: colorSpace, components: [color.components.x, color.components.y, color.components.z, color.alpha])!
        }
        let rgb = workingRGB(color)
        return CGColor(colorSpace: colorSpace, components: [rgb.x, rgb.y, rgb.z, color.alpha])!
    }

    /// The colour vector output (PDF) carries: tagged in its own space, CMYK in Working CMYK.
    public func taggedCGColor(_ color: Color) -> CGColor {
        guard color.space == .cmyk, let space = converter.registry.colorSpace(for: cmykProfile) else {
            return color.cgColor
        }
        let c = color.components
        return CGColor(colorSpace: space, components: [c.x, c.y, c.z, c.w, color.alpha])!
    }

    /// A colour for the sampled paints' sRGB evaluation: CMYK through Working CMYK, and with a
    /// proof the proofed colour, as an sRGB colour (clipped); others unchanged.
    public func sampledColor(_ color: Color) -> Color {
        guard proof != nil || color.space == .cmyk else {
            return color
        }
        let target = ColorManagement(workingSpace: .sRGB, cmykProfile: cmykProfile, intent: intent, blackPointCompensation: blackPointCompensation, proof: proof, converter: converter)
        let rgb = target.workingRGB(color)
        return Color(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: color.alpha)
    }

    /// `paint` with every colour it samples passed through `sampledColor`; solid paints are
    /// the renderers' own business and a Tiled fill's tile draws through the renderer.
    func sampledPaint(_ paint: Paint) -> Paint {
        switch paint {
        case .gradient(var gradient):
            gradient.stops = gradient.stops.map { stop in
                var stop = stop
                stop.color = sampledColor(stop.color)
                return stop
            }
            return .gradient(gradient)
        case .pattern(var pattern):
            pattern.color = sampledColor(pattern.color)
            return .pattern(pattern)
        case .custom(var custom):
            custom.color = sampledColor(custom.color)
            custom.color2 = sampledColor(custom.color2)
            return .custom(custom)
        case .textured(var textured):
            textured.color = sampledColor(textured.color)
            return .textured(textured)
        case .lens(var lens):
            lens.color = sampledColor(lens.color)
            return .lens(lens)
        case .none, .solid, .tiled:
            return paint
        }
    }

    // MARK: Images

    /// The transform a decoded image in `source` (its effective profile) goes through under
    /// the proof into the working space, or nil without a proof (Core Graphics then matches the
    /// image's own colour space into the tile context).
    public func proofTransform(forImageIn source: WTColor.ProfileRef, intent imageIntent: WTColor.RenderingIntent? = nil) -> WTColor.Transform? {
        guard var proof else {
            return nil
        }
        if let imageIntent {
            proof.intent = imageIntent
        }
        return converter.transform(proof.chain(from: WTColor.ChainStep(profile: source, intent: proof.intent, blackPointCompensation: proof.blackPointCompensation), to: workingProfile))
    }
}
