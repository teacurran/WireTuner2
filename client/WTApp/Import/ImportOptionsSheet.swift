import AppKit
import Observation
import SwiftUI
import WTInterchange

/// One format's import options being edited (import-formats.adoc; IMG-008): the sheet renders the
/// importer's schema, so a new format never touches it.  OK saves the values for the format, where
/// they stay until changed -- across launches, since the store is the preferences' defaults.
@MainActor @Observable
final class ImportOptionsModel {
    let format: ImportFormat
    let schema: ImportOptionsSchema
    @ObservationIgnored let store: ImportOptionsStore
    private(set) var values: ImportOptionValues

    init(format: ImportFormat, schema: ImportOptionsSchema, store: ImportOptionsStore) {
        self.format = format
        self.schema = schema
        self.store = store
        values = store.options(for: format, schema: schema)
    }

    var title: String { "\(format.displayName) Options" }

    func bool(_ field: ImportOptionField) -> Bool {
        if case .bool(let value) = field.defaultValue { return values.bool(field.key, default: value) }
        return values.bool(field.key, default: false)
    }

    func string(_ field: ImportOptionField) -> String {
        if case .string(let value) = field.defaultValue { return values.string(field.key, default: value) }
        return values.string(field.key, default: "")
    }

    func set(_ field: ImportOptionField, _ value: ImportOptionValue) {
        values[field.key] = value
    }

    /// Every option back at its default (the sheet's btn:[Defaults]).
    func resetToDefaults() {
        values = schema.defaults
    }

    /// Remembers the values for the format.
    func save() {
        store.save(schema.normalized(values), for: format)
    }

    func binding(bool field: ImportOptionField) -> Binding<Bool> {
        Binding(get: { self.bool(field) }, set: { self.set(field, .bool($0)) })
    }

    func binding(string field: ImportOptionField) -> Binding<String> {
        Binding(get: { self.string(field) }, set: { self.set(field, .string($0)) })
    }
}

/// The btn:[Options…] sheet: one control per schema field, then Defaults, Cancel and OK.
struct ImportOptionsForm: View {
    @Bindable var model: ImportOptionsModel
    let finish: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Form {
                ForEach(model.schema.fields, id: \.key) { field in
                    control(field).help(field.help)
                }
            }
            HStack {
                Button("Defaults", action: model.resetToDefaults).accessibilityIdentifier("import-options.defaults")
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).accessibilityIdentifier("import-options.cancel")
                Button("OK", action: confirm).keyboardShortcut(.defaultAction).accessibilityIdentifier("import-options.ok")
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// btn:[Cancel].
    func cancel() { finish(false) }

    /// btn:[OK].
    func confirm() { finish(true) }

    @ViewBuilder
    func control(_ field: ImportOptionField) -> some View {
        switch field.control {
        case .toggle:
            Toggle(field.label, isOn: model.binding(bool: field)).accessibilityIdentifier("import-options.\(field.key)")
        case .choice(let choices):
            Picker(field.label, selection: model.binding(string: field)) {
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
            }
            .accessibilityIdentifier("import-options.\(field.key)")
        case .text(let placeholder):
            TextField(field.label, text: model.binding(string: field), prompt: Text(placeholder))
                .accessibilityIdentifier("import-options.\(field.key)")
        }
    }
}

/// Shows a format's options sheet on a window (the Import panel or a document window).
@MainActor
enum ImportOptionsSheet {
    static let identifier = NSUserInterfaceItemIdentifier("import-options-sheet")

    /// The sheet's window; `finish` gets whether OK was chosen, after the values are saved.
    static func window(_ model: ImportOptionsModel, finish: @escaping @MainActor (Bool) -> Void) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: ImportOptionsForm(model: model) { ok in
            if ok { model.save() }
            finish(ok)
        }))
        window.identifier = identifier
        window.title = model.title
        return window
    }

    /// Begins the sheet for `model` on `parent`; it ends itself when OK or Cancel is chosen.
    @discardableResult
    static func present(_ model: ImportOptionsModel, on parent: NSWindow, finish: @escaping @MainActor (Bool) -> Void = { _ in }) -> NSWindow {
        let window = window(model) { [weak parent] ok in
            if let parent, let sheet = parent.attachedSheet { parent.endSheet(sheet) }
            finish(ok)
        }
        parent.beginSheet(window)
        return window
    }
}
