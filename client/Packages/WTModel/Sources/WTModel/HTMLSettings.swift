import WTCRDT
import WTInterchange
import WTProto

// WEB-007: named HTML settings in the document model (web/publish-html.adoc, "Data model", "Merge
// semantics"): `SettingsProps.html_settings` (60, SEQUENCE of `HtmlSetting`, each a STRUCT so
// concurrent edits to different options both apply) and the synthesized *Default*.  The two
// `local_only` fields -- `HtmlSetting.location` (3) and `SettingsProps.html_setting_selected` (61)
// -- are never written as registers: nothing strips local-only paths from the outbox yet
// (linking-embedding.adoc records the same deviation for `AssetProps.bookmark`), so the app keeps
// them in the local store's `view` table under `HTMLSettingsLocal`'s keys.

/// Register paths of the HTML settings on the settings node (0:1).
public enum HTMLSettingsFields {
    /// `SettingsProps.html_settings`.
    public static let settings = RegisterPath([SettingsFields.kind, 60])
    /// `SettingsProps.html_setting_selected` (local_only; never written, see above).
    public static let selected = RegisterPath([SettingsFields.kind, 61])

    /// Field `number` of setting element `id`.
    public static func field(_ id: OpID, _ number: UInt32) -> RegisterPath { settings.element(id).child(number) }
    public static func name(_ id: OpID) -> RegisterPath { field(id, 2) }
    /// `HtmlSetting.location` (local_only; never written).
    public static func location(_ id: OpID) -> RegisterPath { field(id, 3) }

    /// The longest name and title.
    public static let maxName = 64
    public static let maxTitle = 256
    /// The Default setting's name.
    public static let defaultName = "Default"

    static func values(_ id: OpID?, _ setting: Wiretuner_Doc_V1_HtmlSetting) -> Wiretuner_Doc_V1_NodeProps {
        var element = setting
        if let id { element.id = id.elementID }
        return SettingsFields.values { $0.htmlSettings = [element] }
    }
}

/// One option of an HTML setting, for `EditHTMLSetting` (its `HtmlSetting` field number).
public enum HTMLSettingOption: UInt32, CaseIterable, Hashable, Sendable {
    case layout = 4
    case pageMode = 5
    case vectorFormat = 6
    case scale = 7
    case imageFormat = 8
    case imageQuality = 9
    case fontMode = 10
    case animationStill = 11
    case svgAnimationPosterOnly = 12
    case background = 13
    case title = 14
    case allowScripts = 15
}

/// One HTML setting as read.
public struct HTMLSettingInfo: Hashable, Sendable {
    /// The sequence element; nil for the synthesized Default of a document that has none.
    public var id: OpID?
    public var name: String
    /// The name shown in the Setup sheet: " (2)", " (3)" ... appended to later settings that
    /// share a name (read-time only).
    public var displayName: String
    public var settings: HTMLPublishSettings

    public init(id: OpID?, name: String, displayName: String? = nil, settings: HTMLPublishSettings) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.settings = settings
    }

    /// The synthesized Default.
    public static let synthesizedDefault = HTMLSettingInfo(id: nil, name: HTMLSettingsFields.defaultName, settings: .defaults)

    /// `stored` with the read-time defaults: unspecified enums read as the first option, a scale
    /// of 0 as 2 and a quality of 0 as 80.
    public static func settings(_ stored: Wiretuner_Doc_V1_HtmlSetting) -> HTMLPublishSettings {
        HTMLPublishSettings(
            layout: stored.layout == .positionedObjects ? .positionedObjects : .wholePages,
            pageMode: stored.pageMode == .separateFiles ? .separateFiles : .stacked,
            vectorFormat: stored.vectorFormat == .png ? .png : .svg,
            scale: (1...3).contains(stored.scale) ? Int(stored.scale) : 2,
            imageFormat: [.png: .png, .webp: .webp][stored.imageFormat] ?? .jpeg,
            imageQuality: (1...100).contains(stored.imageQuality) ? Int(stored.imageQuality) : 80,
            fontMode: [.outlines: .outlines, .system: .system][stored.fontMode] ?? .embed,
            animationStill: stored.animationStill,
            svgAnimationPosterOnly: stored.svgAnimationPosterOnly,
            allowScripts: stored.allowScripts,
            background: [.white: .white, .transparent: .transparent][stored.background] ?? .document,
            title: stored.title
        )
    }

    /// `settings` as the stored message (every option written).
    static func stored(_ settings: HTMLPublishSettings) -> Wiretuner_Doc_V1_HtmlSetting {
        var stored = Wiretuner_Doc_V1_HtmlSetting()
        stored.layout = settings.layout == .positionedObjects ? .positionedObjects : .wholePages
        stored.pageMode = settings.pageMode == .separateFiles ? .separateFiles : .stacked
        stored.vectorFormat = settings.vectorFormat == .png ? .png : .svg
        stored.scale = UInt32(settings.scale)
        stored.imageFormat = [.jpeg: .jpeg, .png: .png, .webp: .webp][settings.imageFormat]!
        stored.imageQuality = UInt32(settings.imageQuality)
        stored.fontMode = [.embed: .embed, .outlines: .outlines, .system: .system][settings.fontMode]!
        stored.animationStill = settings.animationStill
        stored.svgAnimationPosterOnly = settings.svgAnimationPosterOnly
        stored.allowScripts = settings.allowScripts
        stored.background = [.document: .document, .white: .white, .transparent: .transparent][settings.background]!
        stored.title = settings.title
        return stored
    }
}

/// The document's HTML settings as read: the live elements in sequence order, or the synthesized
/// Default when there are none.
public struct HTMLSettings: Hashable, Sendable {
    /// Never empty.
    public var settings: [HTMLSettingInfo]

    public init(_ state: EngineState) {
        let stored = state.props(WellKnown.settings).settings.htmlSettings
        guard !stored.isEmpty else {
            settings = [.synthesizedDefault]
            return
        }
        var seen: [String: Int] = [:]
        settings = stored.map { element in
            let count = seen[element.name, default: 0] + 1
            seen[element.name] = count
            let display = count == 1 ? element.name : "\(element.name) (\(count))"
            return HTMLSettingInfo(id: OpID(counter: element.id.counter, replica: element.id.replica), name: element.name, displayName: display,
                                   settings: HTMLSettingInfo.settings(element))
        }
    }

    /// Whether the list is the synthesized Default alone (nothing stored).
    public var isSynthesized: Bool { settings.count == 1 && settings[0].id == nil }

    /// The setting `id` (nil: the synthesized Default).
    public func setting(_ id: OpID?) -> HTMLSettingInfo? {
        settings.first { $0.id == id }
    }

    /// The setting the Publish sheet selects: the one this Mac remembered
    /// (`HTMLSettingsLocal.selectedKey`) while it exists, else the first.
    public func selected(_ remembered: OpID?) -> HTMLSettingInfo {
        remembered.flatMap(setting) ?? settings[0]
    }
}

/// The keys of the Mac-local HTML setting values in the local store's `view` table: *Location*
/// per setting (the synthesized Default under "default") and the Publish sheet's selection.
public enum HTMLSettingsLocal {
    public static let selectedKey = "html.selected"

    public static func locationKey(_ setting: OpID?) -> String {
        setting.map { "html.location.\($0.counter).\($0.replica)" } ?? "html.location.default"
    }
}

/// Why an HTML setting command refused.
public enum HTMLSettingsError: Error, Hashable, Sendable {
    /// The setting is not a live element of the sequence.
    case unknownSetting(OpID)
    /// The first setting (the Default) cannot be deleted, only edited.
    case cannotDeleteDefault
    case invalidValue(String)
}

enum HTMLSettingsEditing {
    /// The position keys of `count` elements after the last element (tombstones included, so a
    /// restored setting keeps its place).
    static func appendKeys(count: Int, in state: EngineState) throws -> [[UInt8]] {
        let path = HTMLSettingsFields.settings
        let last = state.store.elementOrder(WellKnown.settings, path).last.flatMap { state.position(WellKnown.settings, path, $0) }
        return try PathEditing.keys(between: last, and: nil, count: count)
    }

    static func checkName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.unicodeScalars.count <= HTMLSettingsFields.maxName else {
            throw HTMLSettingsError.invalidValue("name")
        }
    }

    static func check(_ settings: HTMLPublishSettings) throws {
        do { try settings.validate() } catch { throw HTMLSettingsError.invalidValue("settings") }
    }

    static func live(_ id: OpID, in state: EngineState) throws {
        guard state.liveElements(WellKnown.settings, HTMLSettingsFields.settings).contains(id) else { throw HTMLSettingsError.unknownSetting(id) }
    }

    /// Materializes the synthesized Default when the sequence is empty: its element inserted
    /// first (name "Default", `extra` fields of `settings` written), returning its id; nil when
    /// the sequence already holds settings.
    @discardableResult
    static func materializeDefault(_ builder: inout ChangeBuilder, state: EngineState, name: String = HTMLSettingsFields.defaultName,
                                   settings: HTMLPublishSettings = .defaults, options: Set<HTMLSettingOption> = [],
                                   extraKeys: Int = 0) throws -> (id: OpID, keys: [[UInt8]])? {
        guard HTMLSettings(state).isSynthesized else { return nil }
        let keys = try appendKeys(count: 1 + extraKeys, in: state)
        let full = HTMLSettingInfo.stored(settings)
        var element = Wiretuner_Doc_V1_HtmlSetting()
        element.name = name
        for option in options { copy(option, from: full, to: &element) }
        let id = builder.append(Ops.elementInsert(WellKnown.settings, HTMLSettingsFields.settings, positions: [keys[0]],
                                                  values: SettingsFields.values { $0.htmlSettings = [element] }))
        return (id, Array(keys.dropFirst()))
    }

    static func copy(_ option: HTMLSettingOption, from source: Wiretuner_Doc_V1_HtmlSetting, to target: inout Wiretuner_Doc_V1_HtmlSetting) {
        switch option {
        case .layout: target.layout = source.layout
        case .pageMode: target.pageMode = source.pageMode
        case .vectorFormat: target.vectorFormat = source.vectorFormat
        case .scale: target.scale = source.scale
        case .imageFormat: target.imageFormat = source.imageFormat
        case .imageQuality: target.imageQuality = source.imageQuality
        case .fontMode: target.fontMode = source.fontMode
        case .animationStill: target.animationStill = source.animationStill
        case .svgAnimationPosterOnly: target.svgAnimationPosterOnly = source.svgAnimationPosterOnly
        case .background: target.background = source.background
        case .title: target.title = source.title
        case .allowScripts: target.allowScripts = source.allowScripts
        }
    }
}

// MARK: - Commands

/// The Setup sheet's btn:[+]: appends a setting named `name` with `settings` (every option
/// written).  On a document holding only the synthesized Default, the Default is materialized
/// first in the same change, so adding a setting never makes the Default disappear.  "Add HTML
/// setting".
public struct AddHTMLSetting: Command {
    public var name: String
    public var settings: HTMLPublishSettings
    public var label: String { "Add HTML setting" }

    public init(name: String, settings: HTMLPublishSettings = .defaults) {
        self.name = name
        self.settings = settings
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try HTMLSettingsEditing.checkName(name)
        try HTMLSettingsEditing.check(settings)
        let keys = try HTMLSettingsEditing.materializeDefault(&builder, state: state, extraKeys: 1)?.keys
            ?? HTMLSettingsEditing.appendKeys(count: 1, in: state)
        var element = HTMLSettingInfo.stored(settings)
        element.name = name
        builder.append(Ops.elementInsert(WellKnown.settings, HTMLSettingsFields.settings, positions: keys,
                                         values: SettingsFields.values { $0.htmlSettings = [element] }))
    }
}

/// Renames a setting (nil: the synthesized Default, materialized with the new name).  "Rename HTML
/// setting".
public struct RenameHTMLSetting: Command {
    public var setting: OpID?
    public var name: String
    public var label: String { "Rename HTML setting" }

    public init(_ setting: OpID?, to name: String) {
        self.setting = setting
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try HTMLSettingsEditing.checkName(name)
        guard let setting else {
            try HTMLSettingsEditing.materializeDefault(&builder, state: state, name: name)
            return
        }
        try HTMLSettingsEditing.live(setting, in: state)
        var element = Wiretuner_Doc_V1_HtmlSetting()
        element.name = name
        builder.append(Ops.set(WellKnown.settings, [HTMLSettingsFields.name(setting)], values: HTMLSettingsFields.values(setting, element)))
    }
}

/// Writes the options `options` of a setting from `settings` -- one register each, so a
/// collaborator's edit of another option survives (nil: the synthesized Default, materialized
/// with the edited options and defaults for the rest).  One change per field commit, "Change HTML
/// setting".
public struct EditHTMLSetting: Command {
    public var setting: OpID?
    public var settings: HTMLPublishSettings
    public var options: Set<HTMLSettingOption>
    public var label: String { "Change HTML setting" }

    public init(_ setting: OpID?, settings: HTMLPublishSettings, options: Set<HTMLSettingOption>) {
        self.setting = setting
        self.settings = settings
        self.options = options
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !options.isEmpty else { return }
        try HTMLSettingsEditing.check(settings)
        guard let setting else {
            try HTMLSettingsEditing.materializeDefault(&builder, state: state, settings: settings, options: options)
            return
        }
        try HTMLSettingsEditing.live(setting, in: state)
        let full = HTMLSettingInfo.stored(settings)
        var element = Wiretuner_Doc_V1_HtmlSetting()
        for option in options { HTMLSettingsEditing.copy(option, from: full, to: &element) }
        let paths = options.sorted { $0.rawValue < $1.rawValue }.map { HTMLSettingsFields.field(setting, $0.rawValue) }
        builder.append(Ops.set(WellKnown.settings, paths, values: HTMLSettingsFields.values(setting, element)))
    }
}

/// The Setup sheet's btn:[--]: deletes a setting (a tombstone, so a concurrent edit is kept and
/// comes back with *Restore*).  The first setting -- the Default -- cannot be deleted.  "Delete
/// HTML setting".
public struct DeleteHTMLSetting: Command {
    public var setting: OpID
    public var label: String { "Delete HTML setting" }

    public init(_ setting: OpID) {
        self.setting = setting
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try HTMLSettingsEditing.live(setting, in: state)
        guard HTMLSettings(state).settings.first?.id != setting else { throw HTMLSettingsError.cannotDeleteDefault }
        builder.append(Ops.elementDelete(WellKnown.settings, [HTMLSettingsFields.settings.element(setting)]))
    }
}
