import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Color Settings sheet (color-management.adoc, "Client"; CMS-005): the document's Working
/// RGB and CMYK, default image RGB profile, intent, black point compensation, spot colour
/// management and the proof setup.  It edits a draft; btn:[OK] writes the registers that differ
/// in one change ("Change Color Settings").  Profile menus list only profiles of the field's
/// space (bundled, the document's own, installed, *Other…*); a remote change while the sheet is
/// open updates the current-value labels and keeps the draft.
@MainActor
@Observable
final class ColorSettingsModel {
    enum Field: String, CaseIterable, Identifiable {
        case rgb, cmyk, imageRGB, composite
        var id: String { rawValue }

        var title: String {
            switch self {
            case .rgb: "Working RGB"
            case .cmyk: "Working CMYK"
            case .imageRGB: "Untagged RGB images"
            case .composite: "Composite proofer"
            }
        }

        var space: WTColor.ProfileSpace { self == .cmyk || self == .composite ? .cmyk : .rgb }
    }

    /// A profile menu entry.
    struct Choice: Hashable, Identifiable {
        enum Source: Hashable {
            case profile(WTColor.ProfileRef)
            case file(URL)
        }

        let id: String
        let title: String
        let group: String
        let source: Source
    }

    let workspace: ColorWorkspace
    let registry: WTColor.ProfileRegistry
    /// A setting the sheet edits.
    enum Setting: Hashable, CaseIterable {
        case rgb, cmyk, imageRGB, composite, intent, blackPoint, spot, proofTarget, compositeSimulates, paperWhite, blackInk
    }

    /// The draft the sheet edits.
    private(set) var draft: Wiretuner_Doc_V1_ColorSettings {
        didSet { touched.formUnion(Self.differences(oldValue, draft)) }
    }
    /// The settings the user changed: btn:[OK] writes these over the document as it is then, so a
    /// collaborator's change to another setting while the sheet was open survives.
    private(set) var touched: Set<Setting> = []
    /// Why the last choice was refused ("… is not an RGB profile").
    private(set) var refusal: String?
    /// Installed profiles, read once per sheet.
    @ObservationIgnored private lazy var installed: [WTColor.InstalledProfile] = registry.installedProfiles()
    /// *Other…*'s open panel; replaceable in tests.
    @ObservationIgnored var chooseFile: @MainActor (Field) async -> URL? = ColorSettingsModel.openPanel
    /// Loads a chosen `.icc` file as a document profile: through the shared blob cache, queued for
    /// upload so collaborators get it (CMS-008's `ProfileBlobs.load`, wired by `ProfileBlobGlue`);
    /// nil registers it in this process only.
    @ObservationIgnored var loadFile: (@MainActor (URL) async throws -> WTColor.ProfileRef)?

    static let sheet = "color-settings-sheet"

    init(workspace: ColorWorkspace, registry: WTColor.ProfileRegistry = .shared) {
        self.workspace = workspace
        self.registry = registry
        draft = ColorSettings.draft(workspace.document?.state ?? EngineState())
    }

    /// The settings on which `a` and `b` differ.
    static func differences(_ a: Wiretuner_Doc_V1_ColorSettings, _ b: Wiretuner_Doc_V1_ColorSettings) -> Set<Setting> {
        Set(Setting.allCases.filter { setting in
            var copy = a
            copy.copy(setting, from: b)
            return copy != a
        })
    }

    /// The settings to write: the document's as they are now with the touched ones from the draft.
    var result: Wiretuner_Doc_V1_ColorSettings {
        var result = ColorSettings.draft(workspace.document?.state ?? EngineState())
        for setting in touched { result.copy(setting, from: draft) }
        return result
    }

    /// The document's settings as they are now (the current-value labels follow remote changes).
    var current: ColorSettings { ColorSettings(workspace.document?.state ?? EngineState(), registry: registry) }

    /// The draft as read, with defaults resolved.
    var chosen: ColorSettings { ColorSettings(draft, registry: registry) }

    func profile(_ field: Field, in settings: ColorSettings) -> WTColor.ProfileRef {
        switch field {
        case .rgb: settings.rgbProfile
        case .cmyk: settings.cmykProfile
        case .imageRGB: settings.defaultImageRGBProfile
        case .composite: settings.compositeProfile
        }
    }

    static func id(_ profile: WTColor.ProfileRef) -> String { profile.isBundled ? "bundled:\(profile.bundledID)" : "hash:\(profile.hexHash)" }

    /// The group of the document's own profiles.
    static let documentGroup = "In this document"

    /// The menu of `field`: profiles of its space only.
    func choices(_ field: Field) -> [Choice] {
        var result: [Choice] = registry.bundledProfiles.filter { $0.space == field.space }.map {
            Choice(id: Self.id($0), title: $0.name, group: "Bundled", source: .profile($0))
        }
        // *In this document*: the profiles the settings name and every profile asset the document
        // carries -- chosen earlier or embedded in images (CMS-010).
        let state = workspace.document?.state ?? EngineState()
        let documentProfiles = Field.allCases.flatMap { [profile($0, in: current), profile($0, in: chosen)] } + ColorSettings.documentProfiles(state)
        for ref in documentProfiles where !ref.isBundled && ref.space == field.space && !result.contains(where: { $0.id == Self.id(ref) }) {
            result.append(Choice(id: Self.id(ref), title: ref.name, group: Self.documentGroup, source: .profile(ref)))
        }
        for profile in installed where profile.space == field.space {
            result.append(Choice(id: "file:\(profile.url.path)", title: profile.name, group: "Installed", source: .file(profile.url)))
        }
        return result
    }

    /// The menu's selection.
    func selection(_ field: Field) -> String { Self.id(profile(field, in: chosen)) }

    /// Chooses `id` from `field`'s menu.
    func choose(_ id: String, for field: Field) {
        guard let choice = choices(field).first(where: { $0.id == id }) else { return }
        switch choice.source {
        case .profile(let ref): set(ref, for: field)
        case .file(let url): loadChosen(url, for: field)
        }
    }

    /// A chosen file: through `loadFile` when there is one, else registered here.
    @discardableResult
    func loadChosen(_ url: URL, for field: Field) -> Task<Void, Never>? {
        guard let loadFile else {
            load(url, for: field)
            return nil
        }
        return Task { @MainActor in
            do {
                self.accept(try await loadFile(url), for: field)
            } catch {
                self.refusal = "\(url.lastPathComponent) is not an ICC profile."
            }
        }
    }

    /// Loads an `.icc` file (an installed profile or *Other…*) and chooses it when its space fits.
    func load(_ url: URL, for field: Field) {
        guard let data = try? Data(contentsOf: url), let ref = registry.register(iccData: data) else {
            refusal = "\(url.lastPathComponent) is not an ICC profile."
            return
        }
        accept(ref, for: field)
    }

    /// Chooses a loaded profile when its space fits the field.
    func accept(_ ref: WTColor.ProfileRef, for field: Field) {
        guard ref.space == field.space else {
            refusal = "\(ref.name) is not \(field.space == .cmyk ? "a CMYK" : "an RGB") profile."
            return
        }
        set(ref, for: field)
    }

    private func set(_ ref: WTColor.ProfileRef, for field: Field) {
        refusal = nil
        let stored = ColorSettings.stored(ref)
        switch field {
        case .rgb: draft.rgbProfile = stored
        case .cmyk: draft.cmykProfile = stored
        case .imageRGB: draft.defaultImageRgbProfile = stored
        case .composite: draft.proof.compositeProfile = stored
        }
    }

    /// *Other…*.
    @discardableResult
    func other(_ field: Field) -> Task<Void, Never> {
        Task { @MainActor in
            if let url = await self.chooseFile(field) { await self.loadChosen(url, for: field)?.value }
        }
    }

    static func openPanel(_ field: Field) async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        panel.message = "Choose \(field.space == .cmyk ? "a CMYK" : "an RGB") profile for \(field.title)"
        return await panel.begin() == .OK ? panel.url : nil
    }

    // MARK: The other settings

    var intent: WTColor.RenderingIntent {
        get { chosen.intent }
        set { draft.intent = ColorSettings.stored(newValue) }
    }

    var blackPointCompensation: Bool {
        get { !draft.noBlackPointCompensation }
        set { draft.noBlackPointCompensation = !newValue }
    }

    var spotColorManagement: Bool {
        get { !draft.noSpotColorManagement }
        set { draft.noSpotColorManagement = !newValue }
    }

    var proofTarget: ColorSettings.ProofTarget {
        get { chosen.proofTarget }
        set {
            switch newValue {
            case .none: draft.proof.target = .none
            case .separations: draft.proof.target = .separations
            case .composite: draft.proof.target = .composite
            }
        }
    }

    var compositeSimulatesSeparations: Bool {
        get { draft.proof.compositeSimulatesSeparations }
        set { draft.proof.compositeSimulatesSeparations = newValue }
    }

    var simulatePaperWhite: Bool {
        get { draft.proof.simulatePaperWhite }
        set { draft.proof.simulatePaperWhite = newValue }
    }

    var simulateBlackInk: Bool {
        get { draft.proof.simulateBlackInk }
        set { draft.proof.simulateBlackInk = newValue }
    }

    static let intents: [(WTColor.RenderingIntent, String)] = [
        (.perceptual, "Perceptual"), (.relativeColorimetric, "Relative Colorimetric"), (.saturation, "Saturation"), (.absoluteColorimetric, "Absolute Colorimetric"),
    ]

    static let proofTargets: [(ColorSettings.ProofTarget, String)] = [(.none, "None"), (.separations, "Separations press"), (.composite, "Composite proofer")]

    // MARK: OK and Cancel

    /// btn:[OK]: the registers that differ, one change.
    @discardableResult
    func ok() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        workspace.dismiss(Self.sheet)
        return workspace.perform(ChangeColorSettings(result))
    }

    func cancel() {
        workspace.dismiss(Self.sheet)
    }
}


/// The sheet's body.
struct ColorSettingsSheet: View {
    @Bindable var model: ColorSettingsModel

    static func profileBinding(_ field: ColorSettingsModel.Field, _ model: ColorSettingsModel) -> Binding<String> {
        Binding(get: { model.selection(field) }, set: { model.choose($0, for: field) })
    }

    static func other(_ field: ColorSettingsModel.Field, _ model: ColorSettingsModel) -> () -> Void {
        { model.other(field) }
    }

    /// btn:[Profiles…]: the document's profiles (`ProfilesSheet`, CMS-010); the app sets it at launch.
    static var showProfiles: @MainActor (DocumentHandle) -> Void = { _ in }

    static func profiles(_ model: ColorSettingsModel) -> () -> Void {
        { if let document = model.workspace.document { showProfiles(document) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color Settings").font(.headline)
            Form {
                ForEach(ColorSettingsModel.Field.allCases) { field in
                    HStack {
                        Picker(field.title, selection: Self.profileBinding(field, model)) {
                            ForEach(model.choices(field)) { choice in Text("\(choice.title) (\(choice.group))").tag(choice.id) }
                        }
                        .accessibilityIdentifier("color-settings.\(field.rawValue)")
                        Button("Other…", action: Self.other(field, model)).accessibilityIdentifier("color-settings.\(field.rawValue).other")
                    }
                    Text("Now: \(model.profile(field, in: model.current).name)").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("color-settings.\(field.rawValue).current")
                }
                Picker("Intent", selection: $model.intent) {
                    ForEach(ColorSettingsModel.intents, id: \.0) { Text($0.1).tag($0.0) }
                }
                .accessibilityIdentifier("color-settings.intent")
                Toggle("Black point compensation", isOn: $model.blackPointCompensation).accessibilityIdentifier("color-settings.bpc")
                Toggle("Color manage spot colors", isOn: $model.spotColorManagement).accessibilityIdentifier("color-settings.spot")
                Picker("Proof", selection: $model.proofTarget) {
                    ForEach(ColorSettingsModel.proofTargets, id: \.0) { Text($0.1).tag($0.0) }
                }
                .accessibilityIdentifier("color-settings.proof")
                Toggle("Composite simulates separations", isOn: $model.compositeSimulatesSeparations)
                Toggle("Simulate paper white", isOn: $model.simulatePaperWhite)
                Toggle("Simulate black ink", isOn: $model.simulateBlackInk)
            }
            if let refusal = model.refusal { Text(refusal).font(.caption).foregroundStyle(.red).accessibilityIdentifier("color-settings.refusal") }
            HStack {
                Button("Profiles…", action: Self.profiles(model)).disabled(model.workspace.document == nil).accessibilityIdentifier("color-settings.profiles")
                Spacer()
                Button("Cancel", action: model.cancel).keyboardShortcut(.cancelAction)
                Button("OK", action: ColorAction.run(model.ok)).keyboardShortcut(.defaultAction).accessibilityIdentifier("color-settings.ok")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

extension Wiretuner_Doc_V1_ColorSettings {
    /// Copies one setting of the Color Settings sheet from `other`, writing nothing when the two
    /// already agree (so an untouched message stays unset).
    mutating func copy(_ setting: ColorSettingsModel.Setting, from other: Self) {
        switch setting {
        case .rgb:
            guard (hasRgbProfile, rgbProfile) != (other.hasRgbProfile, other.rgbProfile) else { return }
            rgbProfile = other.rgbProfile
        case .cmyk:
            guard (hasCmykProfile, cmykProfile) != (other.hasCmykProfile, other.cmykProfile) else { return }
            cmykProfile = other.cmykProfile
        case .imageRGB:
            guard (hasDefaultImageRgbProfile, defaultImageRgbProfile) != (other.hasDefaultImageRgbProfile, other.defaultImageRgbProfile) else { return }
            defaultImageRgbProfile = other.defaultImageRgbProfile
        case .composite:
            guard (proof.hasCompositeProfile, proof.compositeProfile) != (other.proof.hasCompositeProfile, other.proof.compositeProfile) else { return }
            proof.compositeProfile = other.proof.compositeProfile
        case .intent:
            intent = other.intent
        case .blackPoint:
            noBlackPointCompensation = other.noBlackPointCompensation
        case .spot:
            noSpotColorManagement = other.noSpotColorManagement
        case .proofTarget:
            guard proof.target != other.proof.target else { return }
            proof.target = other.proof.target
        case .compositeSimulates:
            guard proof.compositeSimulatesSeparations != other.proof.compositeSimulatesSeparations else { return }
            proof.compositeSimulatesSeparations = other.proof.compositeSimulatesSeparations
        case .paperWhite:
            guard proof.simulatePaperWhite != other.proof.simulatePaperWhite else { return }
            proof.simulatePaperWhite = other.proof.simulatePaperWhite
        case .blackInk:
            guard proof.simulateBlackInk != other.proof.simulateBlackInk else { return }
            proof.simulateBlackInk = other.proof.simulateBlackInk
        }
    }
}
