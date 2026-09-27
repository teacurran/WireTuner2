import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTInterchange
import WTModel
import WTProto
import WTRender

/// The Object panel's *Overrides* section (library.adoc, "Overriding parts of an instance",
/// "Overrides section"; LIB-027): for the selected instances of one symbol, one row per
/// overridable property of the symbol's artwork (`Symbols.overrideRows`) with its editor -- the
/// text, a fill or stroke colour, *Visible*, btn:[Choose…] for an image -- the value in bold with a
/// reset arrow once it is overridden, then btn:[Reset All Overrides] and btn:[Detach].  Several
/// instances show a value they do not share as "--" and every editor writes all of them; instances
/// of different symbols show an explanation instead.  Each editor is one change (the labels of
/// `SetOverride`, `OverrideTextValue`, `OverrideImage`, `ResetOverrides`, "Detach instance").
@MainActor
struct OverridesSectionModel {
    static let mixed = "--"
    static let differentSymbols = "The selected instances are of different symbols; select instances of one symbol to override its parts."
    static let missingSymbol = "The symbol of this instance is missing."
    static let nothingToOverride = "The symbol has no parts to override."

    let panel: ObjectPanelModel
    /// Asks for a picture file (btn:[Choose…]); replaceable in tests.
    var chooseFile: @MainActor () -> URL? = OverridesSectionModel.openPanel
    /// Stores a picture's bytes for the document before the change that references them (the
    /// import pipeline's blob placement); replaceable in tests.
    var storeBlob: @MainActor (ImportedBlob, DocumentHandle) async throws -> Void = { _, _ in }

    var state: EngineState { panel.document.state }

    /// Every selected instance.
    var instances: [OpID] { panel.objects.map(\.id).filter { state.nodeKind($0) == .instance } }

    /// The one symbol every selected instance draws; nil when they draw several, or none.
    var symbol: OpID? {
        let symbols = Set(instances.map { Symbols.symbol(of: $0, in: state) })
        guard symbols.count == 1, case let symbol?? = symbols.first else { return nil }
        return symbol
    }

    /// Why there are no rows, if there are none.
    var explanation: String? {
        let symbols = Set(instances.map { Symbols.symbol(of: $0, in: state) })
        if symbols.count > 1 { return Self.differentSymbols }
        guard let symbol else { return Self.missingSymbol }
        return Symbols.overrideRows(of: symbol, in: state).isEmpty ? Self.nothingToOverride : nil
    }

    var rows: [OverrideRow] { symbol.map { Symbols.overrideRows(of: $0, in: state) } ?? [] }

    /// What `row` shows: the value the instances share (nil: mixed) and whether any of them
    /// overrides it.
    func value(_ row: OverrideRow) -> (value: OverrideRowValue?, overridden: Bool) {
        let values = instances.map { Symbols.overrideValue(row, of: $0, in: state) }
        let shared = Set(values.map(\.value))
        return (shared.count == 1 ? shared.first : nil, values.contains { $0.overridden })
    }

    /// Whether any selected instance overrides anything (btn:[Reset All Overrides]).
    var hasOverrides: Bool { instances.contains { !Symbols.liveOverrides(of: $0, in: state).isEmpty } }

    /// The row's title: the part's name and the property.
    static func title(_ row: OverrideRow) -> String {
        let property = switch row.property {
        case .text: "Text"
        case .fill: "Fill"
        case .stroke: "Stroke"
        case .image: "Image"
        default: "Visible"
        }
        return "\(row.name) — \(property)"
    }

    /// The text a text row's field shows ("--" never: a mixed value shows an empty field).
    static func text(_ value: OverrideRowValue?) -> String? {
        if case .text(let text)? = value { return text }
        return nil
    }

    /// The colour a colour row's well shows (black when mixed or none).
    func color(_ value: OverrideRowValue?) -> CGColor {
        guard case .color(let ref?)? = value, let color = SwatchList(state).resolver.color(ref) else { return CGColor(gray: 0, alpha: 1) }
        return color.cgColor
    }

    // MARK: Editors

    @discardableResult
    func setText(_ row: OverrideRow, _ text: String) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        panel.perform(OverrideTextValue(instances, master: row.master, text: text))
    }

    @discardableResult
    func setColor(_ row: OverrideRow, _ color: CGColor) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) ?? .black
        let ref = ColorResolver.inline(RenderColor(red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent)))
        return panel.perform(SetOverride(instances, master: row.master, value: row.property == .stroke ? .stroke(ref) : .fill(ref), in: state))
    }

    @discardableResult
    func setVisible(_ row: OverrideRow, _ visible: Bool) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        panel.perform(SetOverride(instances, master: row.master, value: .hidden(!visible), in: state))
    }

    /// btn:[Choose…]: a picture file becomes the image of every selected instance; its bytes are
    /// stored first, the asset is made in the override's change.
    @discardableResult
    func chooseImage(_ row: OverrideRow) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let url = chooseFile(), let data = try? Data(contentsOf: url) else { return nil }
        // An extension the system does not know is plain data (not a dynamic type).
        let type = UTType(filenameExtension: url.pathExtension).flatMap { $0.isDynamic ? nil : $0 } ?? .data
        let blob = ImportedBlob(data: data, uti: type.identifier)
        let document = panel.document
        let command = OverrideImage(instances, master: row.master, blob: blob, name: url.lastPathComponent)
        let store = storeBlob
        return Task { @MainActor in
            guard (try? await store(blob, document)) != nil else { return nil }
            return await document.perform(command).value
        }
    }

    /// The reset arrow.
    @discardableResult
    func reset(_ row: OverrideRow) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        panel.perform(ResetOverrides(instances, key: row.key))
    }

    /// btn:[Reset All Overrides].
    @discardableResult
    func resetAll() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        panel.perform(ResetOverrides(instances))
    }

    /// btn:[Detach]: menu:Modify[Symbol > Release Instance] with the overrides baked in.
    @discardableResult
    func detach() -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        panel.perform(ReleaseInstances(instances, label: "Detach instance"))
    }

    /// The picture-file sheet.
    static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// The section's rows.
struct OverridesSectionView: View {
    let model: OverridesSectionModel

    static func committing(_ row: OverrideRow, _ model: OverridesSectionModel) -> (String) -> Void {
        { model.setText(row, $0) }
    }

    static func color(_ row: OverrideRow, _ model: OverridesSectionModel, value: OverrideRowValue?) -> Binding<CGColor> {
        // The colour panel streams changes while its colour is dragged: previewed, written once it
        // settles (D-076).
        Binding(get: { model.color(value) }, set: { color in ContinuousInput.settle { model.setColor(row, color) } })
    }

    static func visible(_ row: OverrideRow, _ model: OverridesSectionModel, value: OverrideRowValue?) -> Binding<Bool> {
        Binding(get: { if case .visible(let on)? = value { on } else { true } }, set: { model.setVisible(row, $0) })
    }

    static func action(_ body: @escaping @MainActor () -> Task<Wiretuner_Doc_V1_Change?, Never>?) -> () -> Void {
        { _ = body() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Overrides").font(.headline)
            if let explanation = model.explanation {
                Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("object.overrides.explanation")
            }
            ForEach(model.rows, id: \.self) { row in
                OverrideRowView(row: row, model: model)
            }
            HStack {
                Button("Reset All Overrides", action: Self.action(model.resetAll)).disabled(!model.hasOverrides)
                    .accessibilityIdentifier("object.overrides.resetAll")
                Button("Detach", action: Self.action(model.detach)).accessibilityIdentifier("object.overrides.detach")
            }
        }
        .padding(.horizontal)
    }
}

/// One row: the title, the editor, the reset arrow.
struct OverrideRowView: View {
    let row: OverrideRow
    let model: OverridesSectionModel

    static func choosing(_ row: OverrideRow, _ model: OverridesSectionModel) -> () -> Void {
        { _ = model.chooseImage(row) }
    }

    static func resetting(_ row: OverrideRow, _ model: OverridesSectionModel) -> () -> Void {
        { _ = model.reset(row) }
    }

    var body: some View {
        let shown = model.value(row)
        HStack(spacing: 6) {
            Text(OverridesSectionModel.title(row)).font(shown.overridden ? .body.bold() : .body).padding(.leading, Double(row.depth) * 10)
                .accessibilityIdentifier("object.overrides.row.\(row.master).\(row.property.rawValue)")
            Spacer()
            switch row.property {
            case .text:
                CommitTextField(title: "", value: OverridesSectionModel.text(shown.value), identifier: "object.overrides.text.\(row.master)",
                                commit: OverridesSectionView.committing(row, model))
                    .fontWeight(shown.overridden ? .bold : .regular)
            case .fill, .stroke:
                if shown.value == nil { Text(OverridesSectionModel.mixed).foregroundStyle(.secondary) }
                ColorPicker("", selection: OverridesSectionView.color(row, model, value: shown.value), supportsOpacity: false)
                    .labelsHidden().accessibilityIdentifier("object.overrides.color.\(row.master).\(row.property.rawValue)")
            case .image:
                Button("Choose…", action: Self.choosing(row, model)).accessibilityIdentifier("object.overrides.image.\(row.master)")
            default:
                if shown.value == nil { Text(OverridesSectionModel.mixed).foregroundStyle(.secondary) }
                Toggle("", isOn: OverridesSectionView.visible(row, model, value: shown.value)).labelsHidden()
                    .accessibilityIdentifier("object.overrides.visible.\(row.master)")
            }
            if shown.overridden {
                Button(action: Self.resetting(row, model)) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Reset override").accessibilityIdentifier("object.overrides.reset.\(row.master).\(row.property.rawValue)")
            }
        }
    }
}

enum OverridesSection {
    /// The section, storing chosen pictures' bytes through `storeBlob`.
    static func section(storeBlob: @escaping @MainActor (ImportedBlob, DocumentHandle) async throws -> Void) -> InspectorSection {
        InspectorSection(id: "overrides", order: 80, kinds: [.instance]) { panel in
            var model = OverridesSectionModel(panel: panel)
            model.storeBlob = storeBlob
            return model.instances.isEmpty ? nil : AnyView(OverridesSectionView(model: model))
        }
    }
}
