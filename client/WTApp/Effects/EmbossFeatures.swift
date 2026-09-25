import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTRender

/// The Emboss operation's dialog (path-effects.adoc, "Embossing"; FX-034): menu:Extensions[Create >
/// Emboss] or btn:[Emboss] on the Operations toolbar opens it -- the five style buttons, *Vary*
/// (Contrast or Colors, with the two colour boxes), *Depth* (slider 1 to 20, field 1 to 72),
/// *Angle* (dial and field), *Soft edge* for Emboss and Deboss, btn:[Apply] to preview, btn:[OK]
/// -- and kbd:[Cmd]-click on the toolbar button embosses with the settings last used.  The settings
/// are preferences on this Mac; the facets are WTModel's `EmbossKernel`.
@MainActor
enum EmbossFeatures {
    static let id = "emboss"
    static let noShape = "Select a closed path with a basic, gradient or pattern fill"

    enum Keys {
        static let style = PreferenceKey<String>("tools.emboss.style", "Style", category: .object, default: EmbossStyle.emboss.rawValue,
                                                 control: .popup(EmbossStyle.allCases.map { PreferenceOption(.string($0.rawValue), $0.title) }), help: "path-effects")
        static let vary = PreferenceKey<String>("tools.emboss.vary", "Vary", category: .object, default: "contrast",
                                                control: .popup([PreferenceOption(.string("contrast"), "Contrast"), PreferenceOption(.string("colors"), "Colors")]),
                                                help: "path-effects")
        static let highlight = PreferenceKey<PreferenceColor>("tools.emboss.highlight", "Highlight", category: .object, default: PreferenceColor(red: 1, green: 1, blue: 1),
                                                              control: .color, help: "path-effects")
        static let shadow = PreferenceKey<PreferenceColor>("tools.emboss.shadow", "Shadow", category: .object, default: PreferenceColor(red: 0, green: 0, blue: 0),
                                                           control: .color, help: "path-effects")
        static let depth = PreferenceKey<Double>("tools.emboss.depth", "Depth", category: .object, default: 4, control: .stepper(range: 1...72, step: 1, unit: "pt"),
                                                 help: "path-effects")
        static let angle = PreferenceKey<Double>("tools.emboss.angle", "Angle", category: .object, default: 135, control: .stepper(range: 0...360, step: 1, unit: "°"),
                                                 help: "path-effects")
        static let softEdge = PreferenceKey<Bool>("tools.emboss.softEdge", "Soft edge", category: .object, default: false, control: .toggle, help: "path-effects")
    }

    static func color(_ color: PreferenceColor) -> RenderColor { RenderColor(red: color.red, green: color.green, blue: color.blue) }

    /// The dialog's settings as the preferences hold them.
    static func settings(_ store: PreferenceStore) -> EmbossSettings {
        EmbossSettings(style: EmbossStyle(rawValue: store[Keys.style]) ?? .emboss, varyColors: store[Keys.vary] == "colors",
                       highlight: color(store[Keys.highlight]), shadow: color(store[Keys.shadow]), depth: store[Keys.depth], angle: store[Keys.angle],
                       softEdge: store[Keys.softEdge])
    }

    /// The selected objects Emboss applies to.
    static func eligible(_ editing: ObjectEditing) -> [OpID] {
        let state = editing.document.state
        return editing.selectedNodes.filter { EmbossKernel.isEligible($0, in: state) }
    }

    /// The change for `editing`'s selection with `settings`; nil with nothing to emboss.
    static func command(_ editing: ObjectEditing, settings: EmbossSettings) -> EmbossObjects? {
        let state = editing.document.state
        let objects = eligible(editing).map { node in
            (node, EmbossKernel.facets(EmbossKernel.shape(node, in: state), base: EmbossKernel.baseColor(node, in: state), settings: settings))
        }
        return objects.isEmpty ? nil : EmbossObjects(objects)
    }

    /// The operation in place of its catalog stub: nil parameters open the dialog, any others
    /// (Cmd-click, Repeat) emboss straight away with the stored settings.
    static func descriptor(existing: ExtensionRegistry, store: PreferenceStore, target: @escaping ObjectMenuCommands.Target,
                           present: @escaping @MainActor (EmbossPreview) -> Void) -> ExtensionDescriptor? {
        guard var descriptor = existing.descriptor(for: id) else { return nil }
        descriptor.validate = BlendMenu.validation(target) { eligible($0).isEmpty ? noShape : nil }
        descriptor.run = { parameters in
            let preview = EmbossPreview(target: target) { settings(store) }
            guard parameters != nil else {
                present(preview)
                return ["emboss": "settings"]
            }
            if let editing = target(), let command = command(editing, settings: settings(store)) { editing.perform(command) }
            return parameters
        }
        return descriptor
    }

    static func install(extensions: ExtensionRegistry, store: PreferenceStore, target: @escaping ObjectMenuCommands.Target, presenter: SheetPresenter) {
        let present: @MainActor (EmbossPreview) -> Void = { preview in
            presenter.present(EmbossSheet(store: store, preview: preview) { presenter.dismiss("emboss-sheet") }, title: "Emboss", identifier: "emboss-sheet")
        }
        if let descriptor = descriptor(existing: extensions, store: store, target: target, present: present) { extensions.replace(descriptor) }
    }
}

/// btn:[Apply] previews (undoing the previous preview first); btn:[Cancel] undoes it; btn:[OK] keeps
/// it, or embosses when nothing was previewed.
@MainActor
final class EmbossPreview {
    let target: ObjectMenuCommands.Target
    let settings: @MainActor () -> EmbossSettings
    private(set) var previewed: DocumentHandle?

    init(target: @escaping ObjectMenuCommands.Target, settings: @escaping @MainActor () -> EmbossSettings) {
        self.target = target
        self.settings = settings
    }

    @discardableResult
    func apply() -> Task<Void, Never> {
        let target = target, settings = settings()
        let previous = previewed
        return Task { @MainActor in
            if let previous { _ = await previous.undo().value }
            guard let editing = target(), let command = EmbossFeatures.command(editing, settings: settings) else {
                self.previewed = nil
                return
            }
            _ = await editing.document.perform(command).value
            self.previewed = editing.document
        }
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        guard let previous = previewed else { return nil }
        previewed = nil
        return Task { @MainActor in _ = await previous.undo().value }
    }

    /// btn:[OK].
    @discardableResult
    func ok() -> Task<Void, Never>? {
        guard previewed == nil else {
            previewed = nil
            return nil
        }
        return apply()
    }
}

struct EmbossSheet: View {
    let store: PreferenceStore
    let preview: EmbossPreview
    let dismiss: @MainActor () -> Void

    static func style(_ store: PreferenceStore) -> Binding<String> {
        Binding(get: { store[EmbossFeatures.Keys.style] }, set: { store.set($0, for: EmbossFeatures.Keys.style) })
    }

    /// The slider: 1 to 20 points (the field goes to 72).
    static func depthSlider(_ store: PreferenceStore) -> Binding<Double> {
        Binding(get: { min(store[EmbossFeatures.Keys.depth], 20) }, set: { store.set($0.rounded(), for: EmbossFeatures.Keys.depth) })
    }

    static func setDepth(_ store: PreferenceStore) -> (Double) -> Void { { store.set(min(max($0, 1), 72), for: EmbossFeatures.Keys.depth) } }
    static func setAngle(_ store: PreferenceStore) -> (Double) -> Void { { store.set(EffectEditorModel.normalized($0), for: EmbossFeatures.Keys.angle) } }

    static func cancelling(_ preview: EmbossPreview, dismiss: @escaping @MainActor () -> Void) -> () -> Void {
        {
            preview.cancel()
            dismiss()
        }
    }

    static func confirming(_ preview: EmbossPreview, dismiss: @escaping @MainActor () -> Void) -> () -> Void {
        {
            preview.ok()
            dismiss()
        }
    }

    static func applying(_ preview: EmbossPreview) -> () -> Void { { preview.apply() } }

    var body: some View {
        let bindings = PreferenceBindings(store: store)
        let style = EmbossStyle(rawValue: store[EmbossFeatures.Keys.style]) ?? .emboss
        VStack(alignment: .leading, spacing: 12) {
            Picker("Style", selection: Self.style(store)) {
                ForEach(EmbossStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("emboss.style")
            Form {
                PreferenceRowView(row: PreferenceFormRow(key: EmbossFeatures.Keys.vary.erased), bindings: bindings)
                if store[EmbossFeatures.Keys.vary] == "colors" {
                    PreferenceRowView(row: PreferenceFormRow(key: EmbossFeatures.Keys.highlight.erased), bindings: bindings)
                    PreferenceRowView(row: PreferenceFormRow(key: EmbossFeatures.Keys.shadow.erased), bindings: bindings)
                }
                HStack {
                    Slider(value: Self.depthSlider(store), in: 1...20) { Text("Depth") }.accessibilityIdentifier("emboss.depthSlider")
                    CommitField(title: "pt", value: store[EmbossFeatures.Keys.depth], identifier: "emboss.depth", commit: Self.setDepth(store)).frame(width: 56)
                }
                HStack {
                    PointerDial(angle: store[EmbossFeatures.Keys.angle], identifier: "emboss.dial", commit: Self.setAngle(store)).frame(width: 36, height: 36)
                    CommitField(title: "Angle", value: store[EmbossFeatures.Keys.angle], identifier: "emboss.angle", commit: Self.setAngle(store))
                }
                if style == .emboss || style == .deboss {
                    PreferenceRowView(row: PreferenceFormRow(key: EmbossFeatures.Keys.softEdge.erased), bindings: bindings)
                }
            }
            HStack {
                Button("Apply", action: Self.applying(preview)).accessibilityIdentifier("emboss.apply")
                Spacer()
                Button("Cancel", action: Self.cancelling(preview, dismiss: dismiss)).keyboardShortcut(.cancelAction).accessibilityIdentifier("emboss.cancel")
                Button("OK", action: Self.confirming(preview, dismiss: dismiss)).keyboardShortcut(.defaultAction).accessibilityIdentifier("emboss.ok")
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
