import Foundation

/// Where a preference is kept (preferences.adoc, "Synced and local preferences").
enum PreferenceScope: String, Sendable, Codable, CaseIterable {
    /// Stored with the account and applied on every Mac (BASIC-023 syncs it).
    case synced
    /// Describes this Mac; never leaves it.
    case local
}

/// The categories of the Preferences window, in sidebar order.
enum PreferenceCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case general, object, text, document
    case importing = "import"
    case exporting = "export"
    case spelling, colors, panels, redraw, sounds
    case sync, automation, printing, typeface

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .object: "Object"
        case .text: "Text"
        case .document: "Document"
        case .importing: "Import"
        case .exporting: "Export"
        case .spelling: "Spelling"
        case .colors: "Colors"
        case .panels: "Panels"
        case .redraw: "Redraw"
        case .sounds: "Sounds"
        case .sync: "Sync and collaboration"
        case .automation: "Automation"
        case .printing: "Printing"
        case .typeface: "Typeface"
        }
    }

    /// The scope the page's heading gives the category; individual rows may be local
    /// inside a synced category ("synced unless noted").
    var scope: PreferenceScope {
        switch self {
        case .panels, .redraw, .sounds: .local
        default: .synced
        }
    }

    /// SF Symbol for the sidebar.
    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .object: "square.on.circle"
        case .text: "textformat"
        case .document: "doc"
        case .importing: "square.and.arrow.down"
        case .exporting: "square.and.arrow.up"
        case .spelling: "character.book.closed"
        case .colors: "paintpalette"
        case .panels: "sidebar.right"
        case .redraw: "paintbrush"
        case .sounds: "speaker.wave.2"
        case .sync: "person.2"
        case .automation: "gearshape.2"
        case .printing: "printer"
        case .typeface: "textformat.abc"
        }
    }

    /// The categories the sidebar lists.  Typeface is shown only while a typeface document
    /// is open.
    static func visible(typefaceDocumentOpen: Bool) -> [PreferenceCategory] {
        allCases.filter { $0 != .typeface || typefaceDocumentOpen }
    }
}

/// One entry of a pop-up control.
struct PreferenceOption: Hashable, Sendable {
    let value: PreferenceValue
    let title: String

    init(_ value: PreferenceValue, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// What the Preferences window draws for a key.  The form is generated from this; BASIC-022
/// refines individual controls without changing the catalog.
enum PreferenceControl: Hashable, Sendable {
    case toggle
    /// A numeric field with a stepper, limited to `range`, labelled with `unit`.
    case stepper(range: ClosedRange<Double>, step: Double, unit: String)
    case popup([PreferenceOption])
    case color
    case text(placeholder: String)
    /// A list of strings edited as one space-separated field.
    case list
    /// An application, folder or file chosen with `NSOpenPanel` (BASIC-022); a text field
    /// with a disabled Choose button until then.
    case chooser(placeholder: String)

    var range: ClosedRange<Double>? {
        if case let .stepper(range, _, _) = self { return range }
        return nil
    }

    var options: [PreferenceOption]? {
        if case let .popup(options) = self { return options }
        return nil
    }
}

/// A typed preference: the single place it is declared (preferences.adoc, "Client").
/// `Value` fixes the stored type; the store reads and writes through it.
struct PreferenceKey<Value: PreferenceValueConvertible>: Sendable {
    /// Dotted, lower-case, category first (`general.pick_distance`).
    let id: String
    /// The label in the Preferences window.
    let title: String
    let category: PreferenceCategory
    let scope: PreferenceScope
    let defaultValue: Value
    let control: PreferenceControl
    /// The guide page the row links to.
    let helpSlug: String
    /// The row of the preferences page this key implements.  Usually the title; a row that
    /// holds two values (Smart quotes: on/off and style) is shared by two keys.
    let pageRow: String

    init(
        _ id: String, _ title: String, category: PreferenceCategory, scope: PreferenceScope? = nil,
        default defaultValue: Value, control: PreferenceControl, help: String = "preferences", pageRow: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.scope = scope ?? category.scope
        self.defaultValue = defaultValue
        self.control = control
        self.helpSlug = help
        self.pageRow = pageRow ?? title
    }

    var erased: AnyPreferenceKey { AnyPreferenceKey(self) }
}

/// A catalog entry with its type erased, for iteration (the form, reset, completeness).
struct AnyPreferenceKey: Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let category: PreferenceCategory
    let scope: PreferenceScope
    let defaultValue: PreferenceValue
    let control: PreferenceControl
    let helpSlug: String
    let pageRow: String

    init<Value>(_ key: PreferenceKey<Value>) {
        id = key.id
        title = key.title
        category = key.category
        scope = key.scope
        defaultValue = key.defaultValue.preferenceValue
        control = key.control
        helpSlug = key.helpSlug
        pageRow = key.pageRow
    }

    /// The `UserDefaults` key: the id under the `wt.` prefix.
    var defaultsKey: String { PreferenceStore.defaultsPrefix + id }

    /// Whether `value` may be stored: same type as the default, inside the stepper range,
    /// one of the pop-up's options.
    func accepts(_ value: PreferenceValue) -> Bool {
        guard value.hasSameType(as: defaultValue) else { return false }
        switch control {
        case let .stepper(range, _, _):
            guard let number = value.number, number.isFinite else { return false }
            return range.contains(number)
        case let .popup(options):
            return options.contains { $0.value == value }
        case .toggle, .color, .text, .list, .chooser:
            return true
        }
    }

    static func == (lhs: AnyPreferenceKey, rhs: AnyPreferenceKey) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
