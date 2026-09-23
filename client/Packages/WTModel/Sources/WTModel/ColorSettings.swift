import Foundation
import WTCRDT
import WTProto
import WTRender

/// The document's colour settings with the defaults resolved (color-management.adoc, "Data
/// model", "Read-time normalizations"; CMS-004): `SettingsProps.color` on the settings node
/// (0:1) read into WTColor's profile references.
///
/// * An unset profile reads as its default: Working RGB `srgb`, Working CMYK `default-cmyk`,
///   the default image RGB profile as Working RGB, the composite proof profile as Working CMYK.
/// * A profile whose `space` does not fit its field (a CMYK profile as Working RGB) reads as
///   unset.
/// * A custom profile (empty `bundled_id`) whose bytes are not available here renders through
///   the bundled default of its space, and `pending` is set; nothing is written.
/// * Intent `UNSPECIFIED` reads as relative colorimetric; proof target `UNSPECIFIED` as none.
public struct ColorSettings: Hashable, Sendable {
    public enum ProofTarget: Hashable, Sendable {
        case none
        /// Simulate the Working CMYK press.
        case separations
        /// Simulate `compositeProfile`.
        case composite
    }

    /// The profiles as read (defaults resolved, mismatches unset).
    public var rgbProfile: WTColor.ProfileRef
    public var cmykProfile: WTColor.ProfileRef
    public var defaultImageRGBProfile: WTColor.ProfileRef
    public var compositeProfile: WTColor.ProfileRef
    public var intent: WTColor.RenderingIntent
    public var blackPointCompensation: Bool
    /// *Color manage spot colors*.
    public var spotColorManagement: Bool
    public var proofTarget: ProofTarget
    public var compositeSimulatesSeparations: Bool
    public var simulatePaperWhite: Bool
    public var simulateBlackInk: Bool
    /// The profiles that render through a fallback because their bytes have not arrived.
    public var pendingProfiles: [WTColor.ProfileRef]

    /// Whether any profile is waiting for its bytes (the status bar's *profile pending* badge).
    public var pending: Bool { !pendingProfiles.isEmpty }

    /// The settings of `state`.  `isAvailable` says whether a custom profile's bytes (by
    /// SHA-256) are in the blob cache.
    public init(_ state: EngineState, registry: WTColor.ProfileRegistry = .shared, isAvailable: (Data) -> Bool = { _ in true }) {
        self.init(state.props(WellKnown.settings).settings.color, registry: registry, isAvailable: isAvailable)
    }

    /// The settings `stored` holds.
    public init(_ stored: Wiretuner_Doc_V1_ColorSettings, registry: WTColor.ProfileRegistry = .shared, isAvailable: (Data) -> Bool = { _ in true }) {
        var pending: [WTColor.ProfileRef] = []
        func read(_ ref: Wiretuner_Doc_V1_ProfileRef, isSet: Bool, space: WTColor.ProfileSpace, default fallback: WTColor.ProfileRef) -> WTColor.ProfileRef {
            guard isSet, let profile = Self.profile(ref, registry: registry), profile.space == space else { return fallback }
            if !profile.isBundled, !isAvailable(profile.sha256) {
                pending.append(profile)
            }
            return profile
        }
        rgbProfile = read(stored.rgbProfile, isSet: stored.hasRgbProfile, space: .rgb, default: registry.sRGB)
        cmykProfile = read(stored.cmykProfile, isSet: stored.hasCmykProfile, space: .cmyk, default: registry.defaultCMYK)
        defaultImageRGBProfile = read(stored.defaultImageRgbProfile, isSet: stored.hasDefaultImageRgbProfile, space: .rgb, default: rgbProfile)
        compositeProfile = read(stored.proof.compositeProfile, isSet: stored.proof.hasCompositeProfile, space: .cmyk, default: cmykProfile)
        intent = Self.intent(stored.intent)
        blackPointCompensation = !stored.noBlackPointCompensation
        spotColorManagement = !stored.noSpotColorManagement
        switch stored.proof.target {
        case .separations: proofTarget = .separations
        case .composite: proofTarget = .composite
        default: proofTarget = .none
        }
        compositeSimulatesSeparations = stored.proof.compositeSimulatesSeparations
        simulatePaperWhite = stored.proof.simulatePaperWhite
        simulateBlackInk = stored.proof.simulateBlackInk
        var seen: Set<WTColor.ProfileRef> = []
        pendingProfiles = pending.filter { seen.insert($0).inserted }
    }

    /// The stored settings of `state`: the Color Settings sheet's draft starts from these.
    public static func draft(_ state: EngineState) -> Wiretuner_Doc_V1_ColorSettings {
        state.props(WellKnown.settings).settings.color
    }

    /// A stored profile reference as WTColor's: a bundled id the registry knows reads as that
    /// profile; an unknown bundled id or a reference without a space reads as unset (nil).
    static func profile(_ ref: Wiretuner_Doc_V1_ProfileRef, registry: WTColor.ProfileRegistry) -> WTColor.ProfileRef? {
        if !ref.bundledID.isEmpty {
            return registry.bundled(ref.bundledID)
        }
        let space: WTColor.ProfileSpace
        switch ref.space {
        case .rgb: space = .rgb
        case .cmyk: space = .cmyk
        case .gray: space = .gray
        case .lab: space = .lab
        default: return nil
        }
        return WTColor.ProfileRef(name: ref.name, sha256: ref.sha256, space: space)
    }

    /// WTColor's profile reference as stored.
    public static func stored(_ profile: WTColor.ProfileRef) -> Wiretuner_Doc_V1_ProfileRef {
        var ref = Wiretuner_Doc_V1_ProfileRef()
        ref.name = String(profile.name.prefix(256))
        ref.sha256 = profile.sha256
        ref.bundledID = profile.bundledID
        switch profile.space {
        case .rgb: ref.space = .rgb
        case .cmyk: ref.space = .cmyk
        case .gray: ref.space = .gray
        case .lab: ref.space = .lab
        }
        return ref
    }

    static func intent(_ stored: Wiretuner_Doc_V1_RenderingIntent) -> WTColor.RenderingIntent {
        switch stored {
        case .perceptual: return .perceptual
        case .saturation: return .saturation
        case .absoluteColorimetric: return .absoluteColorimetric
        default: return .relativeColorimetric
        }
    }

    public static func stored(_ intent: WTColor.RenderingIntent) -> Wiretuner_Doc_V1_RenderingIntent {
        switch intent {
        case .perceptual: return .perceptual
        case .relativeColorimetric: return .relativeColorimetric
        case .saturation: return .saturation
        case .absoluteColorimetric: return .absoluteColorimetric
        }
    }

    /// The soft proof these settings describe, or nil for no proof.
    public var proof: WTColor.ProofSetup? {
        switch proofTarget {
        case .none:
            return nil
        case .separations:
            return WTColor.ProofSetup(profile: cmykProfile, intent: intent, blackPointCompensation: blackPointCompensation,
                                      simulatePaperWhite: simulatePaperWhite, simulateBlackInk: simulateBlackInk)
        case .composite:
            return WTColor.ProofSetup(profile: compositeProfile, separations: compositeSimulatesSeparations ? cmykProfile : nil, intent: intent,
                                      blackPointCompensation: blackPointCompensation, simulatePaperWhite: simulatePaperWhite,
                                      simulateBlackInk: simulateBlackInk)
        }
    }

    /// The renderer state for a window: Working CMYK, the intent and compensation, and the proof
    /// when *Proof Colors* is on in it.  A pending Working CMYK renders through its fallback.
    public func colorManagement(workingSpace: ColorManagement.WorkingSpace = .displayP3, proofing: Bool = false,
                                registry: WTColor.ProfileRegistry = .shared) -> ColorManagement {
        let cmyk = pendingProfiles.contains(cmykProfile) ? registry.fallback(for: .cmyk) : cmykProfile
        return ColorManagement(workingSpace: workingSpace, cmykProfile: cmyk, intent: intent, blackPointCompensation: blackPointCompensation,
                               proof: proofing ? proof : nil)
    }
}

/// *Color Settings…* OK (color-management.adoc, "Undo"): writes the registers of `SettingsProps
/// .color` where `draft` differs from the document, and nothing else, in one change labelled
/// "Change Color Settings" -- so an undo restores only this user's registers.
public struct ChangeColorSettings: Command {
    public var draft: Wiretuner_Doc_V1_ColorSettings

    public init(_ draft: Wiretuner_Doc_V1_ColorSettings) {
        self.draft = draft
    }

    public var label: String { "Change Color Settings" }

    /// `SettingsProps.color` (settings kind 2, field 50) and its registers.
    static let settingsKind: UInt32 = 2
    static let color: [UInt32] = [2, 50]
    public static let registers: [RegisterPath] = [1, 2, 3, 4, 5, 6].map { RegisterPath(color + [$0]) }
        + [1, 2, 3, 4, 5].map { RegisterPath(color + [7, $0]) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var values = Wiretuner_Doc_V1_NodeProps()
        values.settings.color = draft
        let paths = Self.registers.filter { path in
            state.registerValue(in: values, kind: Self.settingsKind, path: path) != state.store.register(WellKnown.settings, path)?.value
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: values))
    }
}
