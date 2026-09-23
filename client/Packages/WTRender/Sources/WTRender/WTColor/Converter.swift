// The conversion service (CMS-003; docs/_includes/cms/color-management.adoc, "About rendering
// intent" and "Proofing colors on screen"): ColorSync transforms between profiles, cached by
// (source, destination, intent, black point compensation) and by whole proof chains; scalar
// and batch conversion of tagged `Color`s into any profile; the soft-proof chain; and the
// canonical rounding rule that makes a converted value written to the document identical
// wherever the conversion runs.

@preconcurrency import ColorSync
import CoreGraphics
import Foundation

extension WTColor {
    /// `RenderingIntent`.
    public enum RenderingIntent: Hashable, Sendable, CaseIterable {
        case perceptual
        case relativeColorimetric
        case saturation
        case absoluteColorimetric

        var colorSync: CFString {
            switch self {
            case .perceptual: return kColorSyncRenderingIntentPerceptual.takeUnretainedValue()
            case .relativeColorimetric: return kColorSyncRenderingIntentRelative.takeUnretainedValue()
            case .saturation: return kColorSyncRenderingIntentSaturation.takeUnretainedValue()
            case .absoluteColorimetric: return kColorSyncRenderingIntentAbsolute.takeUnretainedValue()
            }
        }

        /// The Core Graphics equivalent (for image drawing and PDF contexts).
        public var cg: CGColorRenderingIntent {
            switch self {
            case .perceptual: return .perceptual
            case .relativeColorimetric: return .relativeColorimetric
            case .saturation: return .saturation
            case .absoluteColorimetric: return .absoluteColorimetric
            }
        }
    }

    /// One profile in a conversion chain: the colours pass into it with `intent` (and black
    /// point compensation), and out of it into the next.
    public struct ChainStep: Hashable, Sendable {
        /// The profile, or nil for the Generic Lab profile a CIELAB or OKLab source enters by.
        public var profile: ProfileRef?
        public var intent: RenderingIntent
        public var blackPointCompensation: Bool

        public init(profile: ProfileRef?, intent: RenderingIntent = .relativeColorimetric, blackPointCompensation: Bool = false) {
            self.profile = profile
            self.intent = intent
            self.blackPointCompensation = blackPointCompensation
        }

        /// The CIELAB (D50) entry point.
        public static let lab = ChainStep(profile: nil)
    }

    /// A soft proof's settings (`ProofSettings` resolved by WTModel, CMS-007): which device
    /// the screen pretends to be and how the last step to the display is made.
    public struct ProofSetup: Hashable, Sendable {
        /// The device simulated: Working CMYK for *Separations Printer*, the composite
        /// profile for *Composite Printer*.
        public var profile: ProfileRef
        /// *Composite simulates separations*: the separations press is passed through first,
        /// then the composite proofer (nil for a plain proof).
        public var separations: ProfileRef?
        /// The document intent into the proof device.
        public var intent: RenderingIntent
        public var blackPointCompensation: Bool
        /// *Simulate paper white*: the last step to the display is absolute colorimetric.
        public var simulatePaperWhite: Bool
        /// *Simulate black ink*: off substitutes the display's black for the device's darkest
        /// value in the last step (black point compensation on that step).
        public var simulateBlackInk: Bool

        public init(
            profile: ProfileRef,
            separations: ProfileRef? = nil,
            intent: RenderingIntent = .relativeColorimetric,
            blackPointCompensation: Bool = true,
            simulatePaperWhite: Bool = false,
            simulateBlackInk: Bool = false
        ) {
            self.profile = profile
            self.separations = separations
            self.intent = intent
            self.blackPointCompensation = blackPointCompensation
            self.simulatePaperWhite = simulatePaperWhite
            self.simulateBlackInk = simulateBlackInk
        }

        /// The chain from a source step to `display`: source → (separations →) proof device
        /// (document intent) → display (relative, or absolute with paper white).
        public func chain(from source: ChainStep, to display: ProfileRef) -> [ChainStep] {
            var steps = [source]
            if let separations {
                steps.append(ChainStep(profile: separations, intent: intent, blackPointCompensation: blackPointCompensation))
                steps.append(ChainStep(profile: profile, intent: .absoluteColorimetric))
            } else {
                steps.append(ChainStep(profile: profile, intent: intent, blackPointCompensation: blackPointCompensation))
            }
            steps.append(ChainStep(
                profile: display,
                intent: simulatePaperWhite ? .absoluteColorimetric : .relativeColorimetric,
                blackPointCompensation: !simulateBlackInk && !simulatePaperWhite
            ))
            return steps
        }
    }

    /// A built ColorSync transform over a chain.  Converts batches of float pixels.
    public final class Transform: @unchecked Sendable {
        let transform: ColorSyncTransform
        public let inputChannels: Int
        public let outputChannels: Int
        /// The chain enters through Generic Lab: inputs are L (0...100), a, b.
        let labInput: Bool

        init(transform: ColorSyncTransform, inputChannels: Int, outputChannels: Int, labInput: Bool) {
            self.transform = transform
            self.inputChannels = inputChannels
            self.outputChannels = outputChannels
            self.labInput = labInput
        }

        /// Converts `input` (pixels of `inputChannels` values, CIELAB as L, a, b) into pixels of
        /// `outputChannels` values in 0...1.
        public func convert(_ input: [Double]) -> [Double] {
            let count = input.count / inputChannels
            guard count > 0 else {
                return []
            }
            var source = [Float](repeating: 0, count: count * inputChannels)
            for index in source.indices {
                let value = input[index]
                if labInput {
                    source[index] = Float(index % 3 == 0 ? value / 100 : (value + 128) / 256)
                } else {
                    source[index] = Float(value)
                }
            }
            var result = [Float](repeating: 0, count: count * outputChannels)
            let layout = ColorSyncDataLayout(kColorSyncByteOrderDefault)
            let inputRow = count * inputChannels * 4
            let outputRow = count * outputChannels * 4
            _ = source.withUnsafeBytes { sourceBytes in
                result.withUnsafeMutableBytes { resultBytes in
                    ColorSyncTransformConvert(
                        transform, count, 1,
                        resultBytes.baseAddress!, kColorSync32BitFloat, layout, outputRow,
                        sourceBytes.baseAddress!, kColorSync32BitFloat, layout, inputRow,
                        nil
                    )
                }
            }
            return result.map { min(max(Double($0), 0), 1) }
        }

        /// Converts premultiplied RGBA8 pixels in place (images under soft proof).
        public func convertRGBA8(_ pixels: inout [UInt8], width: Int, height: Int, bytesPerRow: Int) {
            let layout = ColorSyncDataLayout(CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            let copy = pixels
            _ = copy.withUnsafeBytes { source in
                pixels.withUnsafeMutableBytes { destination in
                    ColorSyncTransformConvert(
                        transform, width, height,
                        destination.baseAddress!, kColorSync8BitInteger, layout, bytesPerRow,
                        source.baseAddress!, kColorSync8BitInteger, layout, bytesPerRow,
                        nil
                    )
                }
            }
        }
    }

    /// Builds and caches transforms and converts colours.  Thread-safe.
    public final class Converter: @unchecked Sendable {
        public static let shared = Converter()

        public let registry: ProfileRegistry
        private let lock = NSLock()
        private var transforms: [[ChainStep]: Transform] = [:]
        private var colorCache: [ColorKey: [Double]] = [:]
        /// How many transforms have been built (the cache's test hook).
        public private(set) var buildCount = 0

        private struct ColorKey: Hashable {
            var color: Color
            var chain: [ChainStep]
        }

        /// The Generic Lab profile a CIELAB source enters by.
        nonisolated(unsafe) private static let labProfile: ColorSyncProfile = ColorSyncProfileCreateWithName(kColorSyncGenericLabProfile.takeUnretainedValue())!.takeRetainedValue()

        public init(registry: ProfileRegistry = .shared) {
            self.registry = registry
        }

        // MARK: Transforms

        /// The transform through `chain` (at least two steps), built once and cached by the
        /// chain -- each step's profile hash, intent and black point compensation.  Nil when a
        /// profile's data is not available or ColorSync refuses the chain.
        public func transform(_ chain: [ChainStep]) -> Transform? {
            if let cached = lock.withLock({ transforms[chain] }) {
                return cached
            }
            guard chain.count >= 2, let built = build(chain) else {
                return nil
            }
            return lock.withLock {
                if let raced = transforms[chain] {
                    return raced
                }
                transforms[chain] = built
                buildCount += 1
                return built
            }
        }

        /// The transform from `source` to `destination`.
        public func transform(from source: ProfileRef, to destination: ProfileRef, intent: RenderingIntent = .relativeColorimetric, blackPointCompensation: Bool = false) -> Transform? {
            transform([
                ChainStep(profile: source, intent: intent, blackPointCompensation: blackPointCompensation),
                ChainStep(profile: destination, intent: intent, blackPointCompensation: blackPointCompensation),
            ])
        }

        private func build(_ chain: [ChainStep]) -> Transform? {
            var sequence: [[String: Any]] = []
            var channels: [Int] = []
            for (index, step) in chain.enumerated() {
                let profile: ColorSyncProfile
                if let ref = step.profile {
                    guard let data = registry.iccData(for: ref),
                          let created = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue()
                    else {
                        return nil
                    }
                    profile = created
                    channels.append(ref.space.channelCount)
                } else {
                    profile = Converter.labProfile
                    channels.append(3)
                }
                // Colours enter a profile (PCS → device) with its step's intent and leave it
                // (device → PCS) with the next step's, so a proof device left with absolute
                // colorimetric shows its paper.
                var halves: [(tag: CFString, step: ChainStep)] = []
                if index > 0 {
                    halves.append((kColorSyncTransformPCSToDevice.takeUnretainedValue(), step))
                }
                if index < chain.count - 1 {
                    halves.append((kColorSyncTransformDeviceToPCS.takeUnretainedValue(), chain[index + 1]))
                }
                for half in halves {
                    sequence.append([
                        kColorSyncProfile.takeUnretainedValue() as String: profile,
                        kColorSyncTransformTag.takeUnretainedValue() as String: half.tag,
                        kColorSyncRenderingIntent.takeUnretainedValue() as String: half.step.intent.colorSync,
                        kColorSyncBlackPointCompensation.takeUnretainedValue() as String: half.step.blackPointCompensation,
                    ])
                }
            }
            guard let transform = ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue() else {
                return nil
            }
            return Transform(transform: transform, inputChannels: channels[0], outputChannels: channels[channels.count - 1], labInput: chain[0].profile == nil)
        }

        // MARK: Colours

        /// The chain step a colour of `color.space` enters by (CMYK through `cmykProfile`), and
        /// the values it enters with (OKLab as CIELAB D50).
        public func entry(for color: Color, cmykProfile: ProfileRef? = nil) -> (step: ChainStep, values: [Double]) {
            let c = color.components
            switch color.space {
            case .sRGB:
                return (ChainStep(profile: registry.sRGB), [c.x, c.y, c.z])
            case .displayP3:
                return (ChainStep(profile: registry.displayP3), [c.x, c.y, c.z])
            case .lab:
                return (.lab, [c.x, c.y, c.z])
            case .oklab:
                let lab = Math.lab(fromXYZD50: Math.xyzD50(color))
                return (.lab, [lab.x, lab.y, lab.z])
            case .cmyk:
                return (ChainStep(profile: cmykProfile ?? registry.defaultCMYK), [c.x, c.y, c.z, c.w])
            }
        }

        /// `color` converted from its own space into `destination` with `intent` and black point
        /// compensation: the device components in 0...1, or nil when a profile is missing.
        /// Cached per distinct colour and chain (the space tag is part of the key, so equal
        /// components in two spaces never share an entry).
        public func convert(_ color: Color, to destination: ProfileRef, cmykProfile: ProfileRef? = nil, intent: RenderingIntent = .relativeColorimetric, blackPointCompensation: Bool = true) -> [Double]? {
            let entry = entry(for: color, cmykProfile: cmykProfile)
            var first = entry.step
            first.intent = intent
            first.blackPointCompensation = blackPointCompensation
            let chain = [first, ChainStep(profile: destination, intent: intent, blackPointCompensation: blackPointCompensation)]
            return convert(color, entry: entry.values, chain: chain)
        }

        /// `color` through a whole chain whose first step is replaced by the colour's own entry
        /// (keeping that step's intent): the soft-proof path.
        public func convert(_ color: Color, through chain: [ChainStep], cmykProfile: ProfileRef? = nil) -> [Double]? {
            let entry = entry(for: color, cmykProfile: cmykProfile)
            var steps = chain
            var first = entry.step
            first.intent = chain[0].intent
            first.blackPointCompensation = chain[0].blackPointCompensation
            steps[0] = first
            return convert(color, entry: entry.values, chain: steps)
        }

        private func convert(_ color: Color, entry: [Double], chain: [ChainStep]) -> [Double]? {
            let key = ColorKey(color: Color(space: color.space, components: color.components, alpha: 1), chain: chain)
            if let cached = lock.withLock({ colorCache[key] }) {
                return cached
            }
            guard let transform = transform(chain) else {
                return nil
            }
            let result = transform.convert(entry)
            lock.withLock { colorCache[key] = result }
            return result
        }

        /// A batch of colours of one space into `destination` through one cached transform
        /// (the 100,000-colour path); values are the colours' components in their space.
        public func convert(_ values: [SIMD4<Double>], space: Color.Space, to destination: ProfileRef, cmykProfile: ProfileRef? = nil, intent: RenderingIntent = .relativeColorimetric, blackPointCompensation: Bool = true) -> [[Double]]? {
            let probe = entry(for: Color(space: space, components: .zero), cmykProfile: cmykProfile)
            var first = probe.step
            first.intent = intent
            first.blackPointCompensation = blackPointCompensation
            guard let transform = transform([first, ChainStep(profile: destination, intent: intent, blackPointCompensation: blackPointCompensation)]) else {
                return nil
            }
            var flat: [Double] = []
            flat.reserveCapacity(values.count * transform.inputChannels)
            for value in values {
                if space == .oklab {
                    let lab = Math.lab(fromXYZD50: Math.xyzD50(Color(space: .oklab, components: value)))
                    flat.append(contentsOf: [lab.x, lab.y, lab.z])
                } else {
                    for channel in 0..<transform.inputChannels {
                        flat.append(value[channel])
                    }
                }
            }
            let converted = transform.convert(flat)
            let width = transform.outputChannels
            return stride(from: 0, to: converted.count, by: width).map { Array(converted[$0..<($0 + width)]) }
        }

        /// Drops every cached colour (a display or settings change); transforms stay, as they
        /// are keyed by the profiles they were built from.
        public func removeCachedColors() {
            lock.withLock { colorCache.removeAll() }
        }

        // MARK: Canonical rounding

        /// `value` rounded half away from zero to a multiple of `step`: 1/255 for display
        /// values, 1/10000 for values written to the document, so a converted value is
        /// bit-identical wherever the conversion was made (CMS-003).
        public static func canonical(_ value: Double, step: Double) -> Double {
            (value / step).rounded(.toNearestOrAwayFromZero) * step
        }

        public static let displayStep = 1.0 / 255
        public static let storedStep = 1.0 / 10_000
    }
}
