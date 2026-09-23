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

    /// A built conversion over a chain: one ColorSync transform, or -- where a step asks for
    /// black point compensation under relative colorimetric -- ColorSync transforms through
    /// Generic Lab with the black point scaling applied between them.  Converts batches of
    /// float pixels.
    public final class Transform: @unchecked Sendable {
        enum Stage {
            /// Values in the ColorSync float encoding; Lab ends are real L, a, b outside.
            case colorSync(ColorSyncTransform, input: Int, output: Int, labInput: Bool, labOutput: Bool)
            /// Black point compensation in XYZ (D50): `source` black maps to `destination`
            /// black, the white point stays.  Lab in, Lab out.
            case blackPoint(source: SIMD3<Double>, destination: SIMD3<Double>)
        }

        let stages: [Stage]
        public let inputChannels: Int
        public let outputChannels: Int

        init(stages: [Stage], inputChannels: Int, outputChannels: Int) {
            self.stages = stages
            self.inputChannels = inputChannels
            self.outputChannels = outputChannels
        }

        convenience init(transform: ColorSyncTransform, inputChannels: Int, outputChannels: Int, labInput: Bool, labOutput: Bool = false) {
            self.init(stages: [.colorSync(transform, input: inputChannels, output: outputChannels, labInput: labInput, labOutput: labOutput)], inputChannels: inputChannels, outputChannels: outputChannels)
        }

        /// Converts `input` (pixels of `inputChannels` values, CIELAB as L, a, b) into pixels of
        /// `outputChannels` values in 0...1.
        public func convert(_ input: [Double]) -> [Double] {
            var values = input
            for stage in stages {
                switch stage {
                case .colorSync(let transform, let inputs, let outputs, let labInput, let labOutput):
                    values = Transform.run(transform, values, inputs: inputs, outputs: outputs, labInput: labInput, labOutput: labOutput)
                case .blackPoint(let source, let destination):
                    values = Transform.compensate(values, source: source, destination: destination)
                }
            }
            return values
        }

        private static func run(_ transform: ColorSyncTransform, _ input: [Double], inputs: Int, outputs: Int, labInput: Bool, labOutput: Bool) -> [Double] {
            let count = input.count / inputs
            guard count > 0 else {
                return []
            }
            var source = [Float](repeating: 0, count: count * inputs)
            for index in source.indices {
                let value = input[index]
                if labInput {
                    source[index] = Float(index % 3 == 0 ? value / 100 : (value + 128) / 256)
                } else {
                    source[index] = Float(value)
                }
            }
            var result = [Float](repeating: 0, count: count * outputs)
            let layout = ColorSyncDataLayout(kColorSyncByteOrderDefault)
            let inputRow = count * inputs * 4
            let outputRow = count * outputs * 4
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
            return result.enumerated().map { index, raw in
                let value = min(max(Double(raw), 0), 1)
                guard labOutput else { return value }
                return index % 3 == 0 ? value * 100 : value * 256 - 128
            }
        }

        /// Lab triples with `source` black (XYZ) moved to `destination` black, linearly per
        /// XYZ channel, D50 white fixed.
        static func compensate(_ lab: [Double], source: SIMD3<Double>, destination: SIMD3<Double>) -> [Double] {
            let white = Math.d50White
            let scale = (white - destination) / (white - source)
            var result = lab
            for start in stride(from: 0, to: lab.count - 2, by: 3) {
                let xyz = Math.xyz(fromLab: SIMD3(lab[start], lab[start + 1], lab[start + 2]))
                let moved = Math.lab(fromXYZD50: destination + (xyz - source) * scale)
                result[start] = moved.x
                result[start + 1] = moved.y
                result[start + 2] = moved.z
            }
            return result
        }

        /// Converts premultiplied RGBA8 pixels in place (images under soft proof).
        public func convertRGBA8(_ pixels: inout [UInt8], width: Int, height: Int, bytesPerRow: Int) {
            if stages.count == 1, case .colorSync(let transform, _, _, _, _) = stages[0] {
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
                return
            }
            // A staged chain converts straight colour in floats.
            var straight: [Double] = []
            straight.reserveCapacity(width * height * 3)
            for row in 0..<height {
                for column in 0..<width {
                    let offset = row * bytesPerRow + column * 4
                    let alpha = Double(pixels[offset + 3])
                    for channel in 0..<3 {
                        straight.append(alpha > 0 ? min(Double(pixels[offset + channel]) / alpha, 1) : 0)
                    }
                }
            }
            let converted = convert(straight)
            for row in 0..<height {
                for column in 0..<width {
                    let offset = row * bytesPerRow + column * 4
                    let alpha = Double(pixels[offset + 3])
                    let index = (row * width + column) * outputChannels
                    for channel in 0..<3 {
                        pixels[offset + channel] = UInt8((converted[index + channel] * alpha).rounded())
                    }
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
        /// Each profile's black point (XYZ, D50), for black point compensation.
        private var blackPoints: [ProfileRef: SIMD3<Double>] = [:]
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

        /// The chain as stages: ColorSync over each run of steps, split through Generic Lab at
        /// every step that asks for black point compensation under relative colorimetric, where
        /// the black points are matched in XYZ.  ColorSync's own compensation is not used: it
        /// moves the white point of some pairs (sRGB white into Generic CMYK came out as
        /// C 11% M 8%, as `CGColor.converted` with its black point option also gives).
        private func build(_ chain: [ChainStep]) -> Transform? {
            var stages: [Transform.Stage] = []
            var segment: [ChainStep] = [chain[0]]
            for step in chain.dropFirst() {
                guard step.blackPointCompensation, step.intent == .relativeColorimetric, let previous = segment.last else {
                    segment.append(step)
                    continue
                }
                guard let source = blackPoint(previous), let destination = blackPoint(step) else {
                    return nil
                }
                // Equal black points need no compensation; ColorSync keeps the run whole.
                let gap = source - destination
                if max(abs(gap.x), abs(gap.y), abs(gap.z)) < 1e-6 {
                    segment.append(step)
                    continue
                }
                let lab = ChainStep(profile: nil, intent: step.intent)
                if segment.count > 1 || previous.profile != nil {
                    guard let built = colorSync(segment + [lab]) else { return nil }
                    stages.append(built)
                }
                stages.append(.blackPoint(source: source, destination: destination))
                segment = [lab, step]
            }
            if segment.count > 1 {
                guard let built = colorSync(segment) else { return nil }
                stages.append(built)
            }
            let first = chain[0].profile?.space.channelCount ?? 3
            let last = chain[chain.count - 1].profile?.space.channelCount ?? 3
            return Transform(stages: stages, inputChannels: first, outputChannels: last)
        }

        /// The black point of `step`'s profile in XYZ (D50): Lab black taken into the device
        /// and back, relative colorimetric; Lab's own black for the Generic Lab step.
        private func blackPoint(_ step: ChainStep) -> SIMD3<Double>? {
            guard let profile = step.profile else {
                return .zero
            }
            if let cached = lock.withLock({ blackPoints[profile] }) {
                return cached
            }
            let plain = ChainStep(profile: profile, intent: .relativeColorimetric)
            let lab = ChainStep(profile: nil, intent: .relativeColorimetric)
            guard let into = colorSync([lab, plain]), let back = colorSync([plain, lab]) else {
                return nil
            }
            let black = Transform(stages: [into, back], inputChannels: 3, outputChannels: 3).convert([0, 0, 0])
            let point = Math.xyz(fromLab: SIMD3(black[0], black[1], black[2]))
            lock.withLock { blackPoints[profile] = point }
            return point
        }

        /// One ColorSync transform over `chain` (at least two steps), without black point
        /// compensation.
        private func colorSync(_ chain: [ChainStep]) -> Transform.Stage? {
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
                        kColorSyncBlackPointCompensation.takeUnretainedValue() as String: false,
                    ])
                }
            }
            guard let transform = ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue() else {
                return nil
            }
            return .colorSync(transform, input: channels[0], output: channels[channels.count - 1], labInput: chain[0].profile == nil, labOutput: chain[chain.count - 1].profile == nil)
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
