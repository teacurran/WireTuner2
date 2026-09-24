import WTCRDT
import WTModel
import WTProto
import WTRender

/// The review sheet row for an always-listed colour settings change (CMS-009; color-management.adoc,
/// "Review sheet"; reconcile.adoc, "Decision rules"): "Color settings changed by <user>" with each
/// changed setting's old and new value -- profiles by name, with "same name, different data" when
/// only the hash differs -- and *Use mine* / *Use theirs* as ordinary undoable changes.
///
/// The divergence measurement lists the entry (`DocumentSetting.colorSettings`) when a remote change
/// since the previous head wrote under `SettingsProps.color`; this reads what it changed from the
/// states either side reached from that head.
public struct ColorSettingsReview: Sendable, Hashable {
    /// One changed setting.
    public struct FieldChange: Sendable, Hashable {
        /// The setting's name as the Color Settings sheet shows it ("Working CMYK").
        public var field: String
        public var old: String
        public var new: String
        /// A profile whose name stayed the same while its bytes changed.
        public var sameNameDifferentData: Bool

        public init(field: String, old: String, new: String, sameNameDifferentData: Bool = false) {
            self.field = field
            self.old = old
            self.new = new
            self.sameNameDifferentData = sameNameDifferentData
        }

        /// "Working CMYK: Generic CMYK → Coated FOGRA39", with the note when it applies.
        public var line: String {
            "\(field): \(old) → \(new)" + (sameNameDifferentData ? " (same name, different data)" : "")
        }
    }

    /// The names of the people whose changes wrote the colour settings.
    public var authors: [String]
    /// What the remote side changed, in the sheet's order.
    public var changes: [FieldChange]
    /// The colour settings as the local side left them; nil when the local changes did not touch
    /// them (then only *Use theirs* is offered).
    public var mine: Wiretuner_Doc_V1_ColorSettings?
    /// The colour settings as the remote side left them.
    public var theirs: Wiretuner_Doc_V1_ColorSettings

    /// The row for `local` (the unsent local changes) against `remote` (the changes sequenced since
    /// the previous head), both applied to `base`, the state at that head; nil when the remote
    /// side changed no colour setting.
    public init?(base: EngineState, local: [Wiretuner_Doc_V1_Change], remote: [Wiretuner_Doc_V1_Change], authors: [String],
                 registry: WTColor.ProfileRegistry = .shared) {
        var mineState = base
        for change in local { mineState.apply(change) }
        var theirsState = base
        for change in remote { theirsState.apply(change) }
        let changes = Self.changes(from: ColorSettings.draft(base), to: ColorSettings.draft(theirsState), registry: registry)
        guard !changes.isEmpty else { return nil }
        self.authors = authors
        self.changes = changes
        let baseDraft = ColorSettings.draft(base)
        let mineDraft = ColorSettings.draft(mineState)
        mine = mineDraft == baseDraft ? nil : mineDraft
        theirs = ColorSettings.draft(theirsState)
    }

    /// "Color settings changed by Priya" (by "Priya and Tom", by "Priya, Tom and Ana"; an unnamed
    /// author reads as "someone").
    public var title: String {
        var names: [String] = []
        for name in authors.map({ $0.isEmpty ? "someone" : $0 }) where !names.contains(name) {
            names.append(name)
        }
        let who = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? "someone"
        return "Color settings changed by \(who)"
    }

    /// The choices the row offers.
    public var actions: [ReviewAction] { mine == nil ? [.useTheirs] : [.useMine, .useTheirs] }

    /// *Use mine*: the local settings written again over the merge (only the registers that
    /// differ), one undoable change; nil when the local side did not change them.
    public var useMine: ColorSettingsChoice? {
        mine.map { ColorSettingsChoice($0, label: "Use My Color Settings") }
    }

    /// *Use theirs*: the remote settings written again over the merge -- a no-op where the merge
    /// already holds them -- one undoable change.
    public var useTheirs: ColorSettingsChoice {
        ColorSettingsChoice(theirs, label: "Use Their Color Settings")
    }

    // MARK: Reading the changes

    /// The settings `new` changes from `old`, as read (defaults resolved).  A profile that
    /// defaults to another one (the default image RGB profile to Working RGB, the composite proof
    /// profile to Working CMYK) is listed only when either side set it: otherwise the change is
    /// the other profile's, listed once.
    static func changes(from oldStored: Wiretuner_Doc_V1_ColorSettings, to newStored: Wiretuner_Doc_V1_ColorSettings,
                        registry: WTColor.ProfileRegistry = .shared) -> [FieldChange] {
        let old = ColorSettings(oldStored, registry: registry)
        let new = ColorSettings(newStored, registry: registry)
        let imageSet = oldStored.hasDefaultImageRgbProfile || newStored.hasDefaultImageRgbProfile
        let compositeSet = oldStored.proof.hasCompositeProfile || newStored.proof.hasCompositeProfile
        var result: [FieldChange] = []
        func profile(_ field: String, _ a: WTColor.ProfileRef, _ b: WTColor.ProfileRef, set: Bool = true) {
            guard set, a != b else { return }
            result.append(FieldChange(field: field, old: a.name, new: b.name, sameNameDifferentData: a.name == b.name && a.sha256 != b.sha256))
        }
        func value(_ field: String, _ a: String, _ b: String) {
            if a != b { result.append(FieldChange(field: field, old: a, new: b)) }
        }
        profile("Working RGB", old.rgbProfile, new.rgbProfile)
        profile("Working CMYK", old.cmykProfile, new.cmykProfile)
        profile("Default image RGB", old.defaultImageRGBProfile, new.defaultImageRGBProfile, set: imageSet)
        value("Intent", name(old.intent), name(new.intent))
        value("Black point compensation", onOff(old.blackPointCompensation), onOff(new.blackPointCompensation))
        value("Color manage spot colors", onOff(old.spotColorManagement), onOff(new.spotColorManagement))
        value("Proof", name(old.proofTarget), name(new.proofTarget))
        profile("Composite proof profile", old.compositeProfile, new.compositeProfile, set: compositeSet)
        value("Composite simulates separations", onOff(old.compositeSimulatesSeparations), onOff(new.compositeSimulatesSeparations))
        value("Simulate paper white", onOff(old.simulatePaperWhite), onOff(new.simulatePaperWhite))
        value("Simulate black ink", onOff(old.simulateBlackInk), onOff(new.simulateBlackInk))
        return result
    }

    static func onOff(_ value: Bool) -> String { value ? "On" : "Off" }

    static func name(_ intent: WTColor.RenderingIntent) -> String {
        switch intent {
        case .perceptual: "Perceptual"
        case .relativeColorimetric: "Relative Colorimetric"
        case .saturation: "Saturation"
        case .absoluteColorimetric: "Absolute Colorimetric"
        }
    }

    static func name(_ target: ColorSettings.ProofTarget) -> String {
        switch target {
        case .none: "None"
        case .separations: "Separations"
        case .composite: "Composite"
        }
    }
}

/// A review choice on the colour settings row: `ChangeColorSettings` with the row's label.
public struct ColorSettingsChoice: Command {
    public var draft: Wiretuner_Doc_V1_ColorSettings
    public let label: String

    public init(_ draft: Wiretuner_Doc_V1_ColorSettings, label: String) {
        self.draft = draft
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try ChangeColorSettings(draft).execute(&builder, state: state)
    }
}
