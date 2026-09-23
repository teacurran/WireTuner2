import AppKit
import SwiftUI

/// One row of a generated category form: what to draw for a catalog key.  Pure data so the
/// generation is testable without SwiftUI.
struct PreferenceFormRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case toggle
        case number(range: ClosedRange<Double>, step: Double, unit: String, integer: Bool)
        case popup([PreferenceOption])
        case color
        case text(placeholder: String)
        case list
        case chooser(placeholder: String)
    }

    let key: AnyPreferenceKey
    let kind: Kind

    var id: String { key.id }
    var title: String { key.title }
    /// `pref.<id>`, the identifier UI tests and VoiceOver use (BASIC-022).
    var accessibilityIdentifier: String { "pref.\(key.id)" }
    /// Local rows inside a synced category are labelled "This Mac".
    var isLocalInSyncedCategory: Bool { key.scope == .local && key.category.scope == .synced }

    init(key: AnyPreferenceKey) {
        self.key = key
        switch key.control {
        case .toggle: kind = .toggle
        case let .stepper(range, step, unit):
            if case .int = key.defaultValue {
                kind = .number(range: range, step: step, unit: unit, integer: true)
            } else {
                kind = .number(range: range, step: step, unit: unit, integer: false)
            }
        case let .popup(options): kind = .popup(options)
        case .color: kind = .color
        case let .text(placeholder): kind = .text(placeholder: placeholder)
        case .list: kind = .list
        case let .chooser(placeholder): kind = .chooser(placeholder: placeholder)
        }
    }
}

/// Builds category forms from the catalog and converts between control values and stored ones.
enum PreferenceForm {
    static func rows(for category: PreferenceCategory, catalog: [AnyPreferenceKey] = PreferenceCatalog.all) -> [PreferenceFormRow] {
        catalog.filter { $0.category == category }.map(PreferenceFormRow.init(key:))
    }

    /// The stored value for a number typed or stepped to `number`.
    static func numberValue(_ number: Double, integer: Bool) -> PreferenceValue {
        integer ? .int(Int(number.rounded())) : .double(number)
    }

    /// What a chooser shows: the chosen item's name, or the placeholder ("System default").
    static func chooserTitle(_ path: String, placeholder: String) -> String {
        path.isEmpty ? placeholder : FileManager.default.displayName(atPath: path)
    }

    /// A list field's text: items separated by spaces.
    static func listText(_ items: [String]) -> String {
        items.joined(separator: " ")
    }

    /// Items from a list field: split on spaces and commas, empties dropped.
    static func listItems(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0.isNewline }).map(String.init)
    }

    static func color(_ preference: PreferenceColor) -> Color {
        Color(.sRGB, red: preference.red, green: preference.green, blue: preference.blue, opacity: preference.alpha)
    }

    static func preferenceColor(_ color: Color) -> PreferenceColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return PreferenceColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }
}

/// Writes through the store, beeping when the catalog rejects a value (the field then shows
/// the stored value again).
@MainActor
struct PreferenceBindings {
    let store: PreferenceStore
    var beep: @MainActor () -> Void = { NSSound.beep() }
    /// Runs a chooser's open panel (BASIC-022); replaceable in tests.
    var choose: @MainActor (AnyPreferenceKey) -> Void

    init(store: PreferenceStore, beep: @escaping @MainActor () -> Void = { NSSound.beep() }, choose: (@MainActor (AnyPreferenceKey) -> Void)? = nil) {
        self.store = store
        self.beep = beep
        self.choose = choose ?? { key in PreferenceBookmarks(store: store).runChooser(for: key) }
    }

    /// Clears a chooser's pick.
    func clearChoice(_ key: AnyPreferenceKey) {
        PreferenceBookmarks(store: store).clear(key)
    }

    func commit(_ value: PreferenceValue, for key: AnyPreferenceKey) {
        if !store.set(value, for: key) { beep() }
    }

    func bool(_ key: AnyPreferenceKey) -> Binding<Bool> {
        Binding(
            get: { if case let .bool(value) = store.value(for: key) { value } else { false } },
            set: { commit(.bool($0), for: key) }
        )
    }

    func number(_ key: AnyPreferenceKey, integer: Bool) -> Binding<Double> {
        Binding(
            get: { store.value(for: key).number ?? 0 },
            set: { commit(PreferenceForm.numberValue($0, integer: integer), for: key) }
        )
    }

    func option(_ key: AnyPreferenceKey) -> Binding<PreferenceValue> {
        Binding(get: { store.value(for: key) }, set: { commit($0, for: key) })
    }

    func string(_ key: AnyPreferenceKey) -> Binding<String> {
        Binding(
            get: { if case let .string(value) = store.value(for: key) { value } else { "" } },
            set: { commit(.string($0), for: key) }
        )
    }

    func list(_ key: AnyPreferenceKey) -> Binding<String> {
        Binding(
            get: { if case let .list(items) = store.value(for: key) { PreferenceForm.listText(items) } else { "" } },
            set: { commit(.list(PreferenceForm.listItems($0)), for: key) }
        )
    }

    func color(_ key: AnyPreferenceKey) -> Binding<Color> {
        Binding(
            get: {
                if case let .color(value) = store.value(for: key) { PreferenceForm.color(value) } else { .clear }
            },
            set: { commit(.color(PreferenceForm.preferenceColor($0)), for: key) }
        )
    }
}

/// The form for one category, generated from the catalog.  Changes apply immediately.
struct PreferenceCategoryForm: View {
    let category: PreferenceCategory
    let store: PreferenceStore

    var body: some View {
        let bindings = PreferenceBindings(store: store)
        Form {
            Section {
                ForEach(PreferenceForm.rows(for: category)) { row in
                    PreferenceRowView(row: row, bindings: bindings)
                }
            } header: {
                Text(category.scope == .synced ? "Synced with your account" : "This Mac only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("pref-category.\(category.rawValue)")
    }
}

struct PreferenceRowView: View {
    let row: PreferenceFormRow
    let bindings: PreferenceBindings

    var body: some View {
        control
            .help(row.isLocalInSyncedCategory ? "Stored on this Mac only" : "")
            .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    @ViewBuilder private var control: some View {
        switch row.kind {
        case .toggle:
            Toggle(row.title, isOn: bindings.bool(row.key))
        case let .number(range, step, unit, integer):
            LabeledContent(row.title) {
                HStack(spacing: 4) {
                    TextField(row.title, value: bindings.number(row.key, integer: integer), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Stepper(row.title, value: bindings.number(row.key, integer: integer), in: range, step: step)
                        .labelsHidden()
                    Text(unit).foregroundStyle(.secondary)
                }
            }
        case let .popup(options):
            Picker(row.title, selection: bindings.option(row.key)) {
                ForEach(options, id: \.self) { option in
                    Text(option.title).tag(option.value)
                }
            }
        case .color:
            ColorPicker(row.title, selection: bindings.color(row.key), supportsOpacity: false)
        case let .text(placeholder):
            TextField(row.title, text: bindings.string(row.key), prompt: Text(placeholder))
        case .list:
            TextField(row.title, text: bindings.list(row.key))
        case let .chooser(placeholder):
            LabeledContent(row.title) {
                HStack {
                    Text(PreferenceForm.chooserTitle(bindings.string(row.key).wrappedValue, placeholder: placeholder))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { bindings.choose(row.key) }
                        .accessibilityIdentifier("\(row.accessibilityIdentifier).choose")
                    Button("Clear") { bindings.clearChoice(row.key) }
                        .accessibilityIdentifier("\(row.accessibilityIdentifier).clear")
                }
            }
        }
    }
}
