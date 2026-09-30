// The output colour context (CMS-011; docs/_includes/cms/color-profiles.adoc, "Client"): what
// export and print need to know about a document's colour without knowing how profiles are
// stored -- the working profiles with their ICC bytes, the document intent, each placed image's
// source profile, the proof chain for *Composite simulates separations*, a `CGColorSpace` and an
// ICC stream for every space a `Color` can carry, conversion of a tagged colour into any output
// profile through the CMS-003 converter, and the helpers that embed a profile in bitmap files and
// name one as a PDF output intent.  WTModel resolves the document's `ColorSettings` into a
// `ColorManagement`; `init(colorManagement:)` builds the context from it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WTRender

extension WTColor {
    /// A document's colour, resolved for output.
    public struct OutputContext: Hashable, Sendable {
        /// The three colour models a working profile exists for.
        public enum Model: Hashable, Sendable, CaseIterable {
            case rgb
            case cmyk
            case gray
        }

        /// Working RGB: the space RGB bitmaps are written in, and the profile assumed for RGB
        /// images without one.
        public var rgbProfile: ProfileRef
        /// Working CMYK: the press the document is separated for.
        public var cmykProfile: ProfileRef
        /// The gray working profile.
        public var grayProfile: ProfileRef
        /// The document intent.
        public var intent: RenderingIntent
        public var blackPointCompensation: Bool
        /// The document's proof setup (*Composite simulates separations* is its `separations`).
        public var proof: ProofSetup?
        /// Each placed image's effective source profile, by asset id (images not listed are in
        /// the working profile of their model).
        public var imageProfiles: [String: ProfileRef]
        /// The conversion service; not part of the value's identity.
        public let converter: Converter
        /// The document gamut scan (CMS-015, `WideGamutOutput.swift`): how far the whole
        /// document's colours reach, from the scan WTModel keeps cached (`DocumentGamutScan`).
        /// nil: the exporter scans the exported scene once (`widestSpaceUsed(in:)`).  Every page
        /// of an export follows it.  A fact about the document, not part of the value's identity.
        public var widestSpaceUsed: GamutReach?

        public init(rgbProfile: ProfileRef? = nil, cmykProfile: ProfileRef? = nil, grayProfile: ProfileRef? = nil,
                    intent: RenderingIntent = .relativeColorimetric, blackPointCompensation: Bool = true, proof: ProofSetup? = nil,
                    imageProfiles: [String: ProfileRef] = [:], converter: Converter = .shared) {
            let registry = converter.registry
            self.rgbProfile = Self.usable(rgbProfile, space: .rgb, registry: registry)
            self.cmykProfile = Self.usable(cmykProfile, space: .cmyk, registry: registry)
            self.grayProfile = Self.usable(grayProfile, space: .gray, registry: registry)
            self.intent = intent
            self.blackPointCompensation = blackPointCompensation
            self.proof = proof
            self.imageProfiles = imageProfiles
            self.converter = converter
        }

        /// The context of a renderer's colour state: its Working CMYK, intent, compensation and
        /// proof; Working RGB is `rgbProfile` or, when nil, the renderer's working space.
        public init(colorManagement: ColorManagement, rgbProfile: ProfileRef? = nil, grayProfile: ProfileRef? = nil,
                    imageProfiles: [String: ProfileRef] = [:]) {
            let registry = colorManagement.converter.registry
            let working = colorManagement.workingSpace == .sRGB ? registry.sRGB : registry.displayP3
            self.init(rgbProfile: rgbProfile ?? working, cmykProfile: colorManagement.cmykProfile, grayProfile: grayProfile,
                      intent: colorManagement.intent, blackPointCompensation: colorManagement.blackPointCompensation,
                      proof: colorManagement.proof, imageProfiles: imageProfiles, converter: colorManagement.converter)
        }

        /// sRGB, Default CMYK, generic gray, relative colorimetric with compensation.
        public static let standard = OutputContext()

        /// `ref` when it is a profile of `space` whose data is here, else the bundled default of
        /// the space (a pending custom profile outputs through its fallback, as it renders).
        static func usable(_ ref: ProfileRef?, space: ProfileSpace, registry: ProfileRegistry) -> ProfileRef {
            guard let ref, ref.space == space, registry.colorSpace(for: ref) != nil else { return registry.fallback(for: space) }
            return ref
        }

        public static func == (lhs: OutputContext, rhs: OutputContext) -> Bool {
            lhs.rgbProfile == rhs.rgbProfile && lhs.cmykProfile == rhs.cmykProfile && lhs.grayProfile == rhs.grayProfile && lhs.intent == rhs.intent
                && lhs.blackPointCompensation == rhs.blackPointCompensation && lhs.proof == rhs.proof && lhs.imageProfiles == rhs.imageProfiles
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(rgbProfile)
            hasher.combine(cmykProfile)
            hasher.combine(grayProfile)
            hasher.combine(intent)
            hasher.combine(blackPointCompensation)
            hasher.combine(proof)
            hasher.combine(imageProfiles)
        }

        var registry: ProfileRegistry { converter.registry }

        // MARK: Working profiles

        /// The working profile of `model`.
        public func profile(model: Model) -> ProfileRef {
            switch model {
            case .rgb: rgbProfile
            case .cmyk: cmykProfile
            case .gray: grayProfile
            }
        }

        /// The ICC bytes of the working profile of `model` (always available: `init` falls back
        /// to a bundled profile).
        public func iccData(model: Model) -> Data {
            registry.iccData(for: profile(model: model))!
        }

        /// The colour space of the working profile of `model`.
        public func colorSpace(model: Model) -> CGColorSpace {
            registry.colorSpace(for: profile(model: model))!
        }

        /// The source profile of placed image `assetID` of `model`: its own, else the working
        /// profile of the model.
        public func sourceProfile(forImage assetID: String, model: Model) -> ProfileRef {
            imageProfiles[assetID].flatMap { $0.space == profile(model: model).space ? $0 : nil } ?? profile(model: model)
        }

        // MARK: Colour spaces

        /// The space a colour of `space` is written in: OKLab resolves to Display P3 (no file
        /// format carries OKLab); the others are their own.
        public static func outputSpace(_ space: Color.Space) -> Color.Space {
            space == .oklab ? .displayP3 : space
        }

        /// The colour space a colour of `space` is written in: sRGB, Display P3, CIELAB D50, OKLab
        /// as Display P3, CMYK in Working CMYK.
        public func colorSpace(for space: Color.Space) -> CGColorSpace {
            switch Self.outputSpace(space) {
            case .sRGB: return Spaces.sRGB
            case .displayP3, .oklab: return Spaces.displayP3
            case .lab: return Spaces.lab
            case .cmyk: return colorSpace(model: .cmyk)
            }
        }

        /// The ICC stream of `colorSpace(for:)` (every space above is ICC-based).
        public func iccStream(for space: Color.Space) -> Data {
            Self.outputSpace(space) == .cmyk ? iccData(model: .cmyk) : colorSpace(for: space).copyICCData()! as Data
        }

        /// `color` as components of its output space (OKLab converted to Display P3, clipped),
        /// with its alpha: what a file tags with `colorSpace(for: color.space)`.
        public func outputComponents(_ color: Color) -> [Double] {
            let c = color.components
            switch color.space {
            case .oklab:
                let p3 = Math.clipped(Math.rgb(color, in: .displayP3))
                return [p3.x, p3.y, p3.z, color.alpha]
            case .cmyk:
                return [c.x, c.y, c.z, c.w, color.alpha]
            case .sRGB, .displayP3, .lab:
                return [c.x, c.y, c.z, color.alpha]
            }
        }

        /// `color` tagged in its output space.
        public func cgColor(_ color: Color) -> CGColor {
            CGColor(colorSpace: colorSpace(for: color.space), components: outputComponents(color).map { CGFloat($0) })!
        }

        // MARK: Conversion

        /// `color` converted from its own space into `destination` with the document intent and
        /// compensation (CMYK colours enter through Working CMYK, OKLab through CIELAB): device
        /// components in 0...1; nil when the destination's data is not here.
        public func convert(_ color: Color, to destination: ProfileRef) -> [Double]? {
            converter.convert(color, to: destination, cmykProfile: cmykProfile, intent: intent, blackPointCompensation: blackPointCompensation)
        }

        /// `color` separated to Working CMYK through its own space.
        public func separate(_ color: Color) -> [Double] {
            // Working CMYK is available (`init`), so every colour converts into it.
            convert(color, to: cmykProfile)!
        }

        /// The chain a colour of `source` takes to a composite print `device`: with *Composite
        /// simulates separations* on, through Working CMYK (document intent) and then into the
        /// device absolute colorimetrically, so the device prints what the press would; else
        /// straight into the device with the document intent.
        public func compositeChain(from source: ChainStep, device: ProfileRef) -> [ChainStep] {
            var first = source
            first.intent = intent
            first.blackPointCompensation = blackPointCompensation
            guard proof?.separations != nil else {
                return [first, ChainStep(profile: device, intent: intent, blackPointCompensation: blackPointCompensation)]
            }
            return [first, ChainStep(profile: cmykProfile, intent: intent, blackPointCompensation: blackPointCompensation),
                    ChainStep(profile: device, intent: .absoluteColorimetric)]
        }

        /// `color` for a composite print `device` through `compositeChain`.
        public func compositeColor(_ color: Color, device: ProfileRef) -> [Double]? {
            let entry = converter.entry(for: color, cmykProfile: cmykProfile)
            return converter.convert(color, through: compositeChain(from: entry.step, device: device), cmykProfile: cmykProfile)
        }

        /// The renderer state a composite print to `device` draws with: with *Composite
        /// simulates separations* on, every colour is proofed through Working CMYK and the
        /// device, so the pixels handed to the device already carry the press's gamut.
        public func compositePrintColorManagement(device: ProfileRef, workingSpace: ColorManagement.WorkingSpace = .sRGB) -> ColorManagement {
            let simulated = proof?.separations != nil
                ? ProofSetup(profile: device, separations: cmykProfile, intent: intent, blackPointCompensation: blackPointCompensation, simulatePaperWhite: false, simulateBlackInk: true)
                : nil
            return ColorManagement(workingSpace: workingSpace, cmykProfile: cmykProfile, intent: intent, blackPointCompensation: blackPointCompensation,
                                   proof: simulated, converter: converter)
        }

        /// A CMYK converter into Working CMYK with the document intent (PDF/X, EPS, *Convert to
        /// CMYK*).
        public var cmykConverter: ProfileCMYKConverter {
            ProfileCMYKConverter(profile: cmykProfile, intent: intent, registry: registry)
        }

        // MARK: Files

        /// `image` tagged with the working profile of `model` (its pixels untouched); nil when
        /// the image's channel count does not match the model.
        public func tagged(_ image: CGImage, model: Model) -> CGImage? {
            image.copy(colorSpace: colorSpace(model: model))
        }

        /// `image` written as `type` (TIFF, PNG, JPEG, ...) with the working profile of `model`
        /// embedded; nil when the image does not match the model or ImageIO cannot write the type.
        public func encode(_ image: CGImage, type: UTType, model: Model, properties: [CFString: Any] = [:]) -> Data? {
            guard let tagged = tagged(image, model: model) else { return nil }
            return ImageEncoding.encode(tagged, type: type, properties: properties)
        }

        /// The profile embedded in an image file, as a ref (nil when it has none).
        public static func embeddedProfile(in data: Data, registry: ProfileRegistry = .shared) -> ProfileRef? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let icc = image.colorSpace?.copyICCData() as Data?
            else {
                return nil
            }
            return registry.register(iccData: icc)
        }

        /// The ICC bytes a PSD's image resource 0x040F carries for `model`.
        public func psdProfile(for model: Model) -> Data {
            iccData(model: model)
        }

        /// A PDF output intent naming `profile` (Working CMYK when nil) with subtype `subtype`
        /// (`GTS_PDFX`, `GTS_PDFA1`).
        public func outputIntent(_ profile: ProfileRef? = nil, subtype: String = "GTS_PDFX") -> PDFOutputIntent {
            let profile = profile.map { Self.usable($0, space: $0.space, registry: registry) } ?? cmykProfile
            return PDFOutputIntent(subtype: subtype, identifier: profile.name, condition: profile.name, profile: registry.iccData(for: profile)!,
                                   components: profile.space.channelCount)
        }
    }
}

/// A PDF `/OutputIntent` dictionary's contents: written by `PDFObjects` as the dictionary and its
/// `DestOutputProfile` stream.
public struct PDFOutputIntent: Hashable, Sendable {
    /// `S`: `GTS_PDFX`, `GTS_PDFA1`.
    public var subtype: String
    /// `OutputConditionIdentifier`.
    public var identifier: String
    /// `OutputCondition` and `Info`.
    public var condition: String
    /// The ICC bytes of `DestOutputProfile`.
    public var profile: Data
    /// The profile's channel count (`N` of the stream).
    public var components: Int

    public init(subtype: String, identifier: String, condition: String, profile: Data, components: Int) {
        self.subtype = subtype
        self.identifier = identifier
        self.condition = condition
        self.profile = profile
        self.components = components
    }

    /// The dictionary, its profile stream added to `objects`.
    func value(objects: PDFObjects) -> PDFValue {
        .dictionary([
            ("Type", .name("OutputIntent")),
            ("S", .name(subtype)),
            ("OutputConditionIdentifier", .string(identifier)),
            ("OutputCondition", .string(condition)),
            ("Info", .string(condition)),
            ("DestOutputProfile", .reference(objects.addStream([("N", .int(components))], data: profile))),
        ])
    }
}
