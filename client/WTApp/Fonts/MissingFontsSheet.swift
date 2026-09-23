import AppKit
import SwiftUI
import WTText

/// The Missing Fonts sheet's view (font-substitution.adoc, "The Missing Fonts sheet"): the list
/// of missing faces with their substitutes and *Keep original name*, the buttons, and the
/// family-and-style picker behind btn:[Substitute…] and btn:[Replace…] (no `NSFontPanel`).
struct MissingFontsSheet: View {
    let model: MissingFontsModel
    /// btn:[Open] (true) or btn:[Cancel] (false).
    let finish: @MainActor (Bool) -> Void

    /// Each button's action (tests call them).
    static func action(_ run: @escaping @MainActor () -> Void) -> () -> Void {
        { run() }
    }

    /// btn:[Open] (true) or btn:[Cancel] (false).
    static func finishing(_ finish: @escaping @MainActor (Bool) -> Void, open: Bool) -> () -> Void {
        { finish(open) }
    }

    /// btn:[Fetch from team library].
    static func fetching(_ model: MissingFontsModel) -> () -> Void {
        { Task { await model.fetch() } }
    }

    /// A row's *Keep original name* toggle.
    static func keepsName(_ model: MissingFontsModel, _ face: FaceName) -> Binding<Bool> {
        Binding(get: { model.rows.first { $0.face == face }?.keepOriginalName ?? true }, set: { model.setKeepOriginalName($0, for: face) })
    }

    /// A row's selection checkbox.
    static func selects(_ model: MissingFontsModel, _ face: FaceName) -> Binding<Bool> {
        Binding(get: { model.selected.contains(face) }, set: { _ in model.toggle(face) })
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            Text("Missing Fonts").font(.headline)
            Text("This document uses fonts that are not on this Mac.  Choose what to show in their place.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach(model.rows) { row in
                    HStack {
                        Toggle(row.face.description, isOn: Self.selects(model, row.face))
                            .accessibilityIdentifier("missing-fonts.row.\(row.face.description)")
                        Spacer()
                        if row.inTeamLibrary { Text("In team library").font(.caption).foregroundStyle(.secondary) }
                        Text(model.caption(for: row)).foregroundStyle(.secondary)
                        Toggle("Keep original name", isOn: Self.keepsName(model, row.face))
                            .accessibilityIdentifier("missing-fonts.keep.\(row.face.description)")
                    }
                }
            }
            .frame(minHeight: 140)
            HStack {
                Button("Select All", action: Self.action(model.selectAll)).accessibilityIdentifier("missing-fonts.selectAll")
                Button("Substitute…", action: Self.action(model.beginSubstitute))
                    .disabled(!model.hasSelection).accessibilityIdentifier("missing-fonts.substitute")
                Button("Replace…", action: Self.action(model.beginReplace))
                    .disabled(!model.hasSelection).accessibilityIdentifier("missing-fonts.replace")
                Toggle("Remember this substitution", isOn: $model.remember).accessibilityIdentifier("missing-fonts.remember")
            }
            if model.picking != nil { FontPickerView(model: model) }
            HStack {
                Button("Fetch from team library", action: Self.fetching(model))
                    .disabled(!model.canFetch)
                    .help(model.fetchHelp ?? "")
                    .accessibilityIdentifier("missing-fonts.fetch")
                if let help = model.fetchHelp ?? model.fetchError { Text(help).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", action: Self.finishing(finish, open: false)).keyboardShortcut(.cancelAction).accessibilityIdentifier("missing-fonts.cancel")
                Button("Open", action: Self.finishing(finish, open: true)).keyboardShortcut(.defaultAction).accessibilityIdentifier("missing-fonts.open")
            }
        }
        .padding(16)
        .frame(width: 620)
    }
}

/// The family and style lists behind btn:[Substitute…] and btn:[Replace…].
struct FontPickerView: View {
    let model: MissingFontsModel

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .bottom) {
            Picker("Family", selection: $model.pickerFamily) {
                Text("Choose a font").tag(String?.none)
                ForEach(model.families, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .accessibilityIdentifier("missing-fonts.picker.family")
            Picker("Style", selection: $model.pickerStyle) {
                Text("Keep each run's style").tag(String?.none)
                ForEach(model.styles, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .accessibilityIdentifier("missing-fonts.picker.style")
            Button("Cancel", action: MissingFontsSheet.action(model.cancelPicking)).accessibilityIdentifier("missing-fonts.picker.cancel")
            Button("OK", action: MissingFontsSheet.action(model.commitPicking))
                .disabled(model.pickerFamily == nil)
                .accessibilityIdentifier("missing-fonts.picker.ok")
        }
    }
}
