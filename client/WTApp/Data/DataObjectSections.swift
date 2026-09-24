import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

// The Object panel's *Data* and *Barcode* sections and the *Insert Barcode…* sheet
// (data-merge.adoc, "Binding an object", "Barcodes and QR codes"; DATA-017, DATA-018's WTApp half).

/// The Object panel sections of data merge.
@MainActor
enum DataSections {
    static func register(into registry: InspectorRegistry) {
        registry.register(InspectorSection(id: "barcode", order: 72, kinds: [.barcode]) { panel in
            BarcodeSectionModel(panel).map { AnyView(BarcodeSectionView(model: $0)) }
        })
        registry.register(InspectorSection(id: "data", order: 90, kinds: nil) { panel in
            DataSectionModel(panel).map { AnyView(DataSectionView(model: $0)) }
        })
    }
}

/// The *Data* section: the selection's binding -- how it applies and to which field -- when the
/// document has fields or something selected is bound.  Choosing writes one change ("Bind to
/// field", "Unbind").
@MainActor
struct DataSectionModel {
    let panel: ObjectPanelModel
    let nodes: [OpID]
    let data: DataModel
    let bindings: [DataBindingInfo?]

    init?(_ panel: ObjectPanelModel) {
        let state = panel.document.state
        let data = DataModel(state)
        let nodes = panel.selection.ids.map(\.opID)
        let bindings = nodes.map { data.binding(of: $0, in: state) }
        guard !nodes.isEmpty, !data.fields.isEmpty || bindings.contains(where: { $0 != nil }) else { return nil }
        self.panel = panel
        self.nodes = nodes
        self.data = data
        self.bindings = bindings
    }

    /// The binding kinds every selected object can take.
    var kinds: [DataBindingKind] {
        let state = panel.document.state
        return DataBindingKind.allCases.filter { kind in nodes.allSatisfy { BindToField.allows(kind, nodeKind: state.store.kind($0)) } }
    }

    /// The kind the selection shares (nil: unbound, or they differ).
    var kind: DataBindingKind? {
        let kinds = Set(bindings.map { $0?.kind })
        return kinds.count == 1 ? kinds.first ?? nil : nil
    }

    /// The field the selection shares.
    var field: OpID? {
        let fields = Set(bindings.map { $0?.field })
        return fields.count == 1 ? fields.first ?? nil : nil
    }

    /// Whether a selected binding's field is missing (the red *missing* note).
    var isMissing: Bool { bindings.contains { $0?.isMissing == true } }

    /// The fields that suit `kind`.
    func fields(for kind: DataBindingKind) -> [DataFieldInfo] { data.fields.filter { kind.accepts($0.kind) } }

    static func title(_ kind: DataBindingKind) -> String {
        switch kind {
        case .image: "Image"
        case .visibility: "Visibility"
        case .link: "Link"
        case .text: "Text"
        }
    }

    /// Binds the selection as `kind` to `field` (the first suitable field when nil); nil unbinds.
    func bind(_ kind: DataBindingKind?, field: OpID? = nil) {
        guard let kind else {
            if bindings.contains(where: { $0 != nil }) { panel.perform(Unbind(nodes)) }
            return
        }
        let suitable = fields(for: kind)
        let current = self.field.flatMap { id in suitable.first { $0.id == id }?.id }
        guard let chosen = field ?? current ?? suitable.first?.id else { return }
        panel.perform(BindToField(nodes, field: chosen, kind: kind))
    }
}

struct DataSectionView: View {
    let model: DataSectionModel

    static let none = "None"

    static func kind(_ model: DataSectionModel) -> Binding<String> {
        Binding(get: { model.kind.map(DataSectionModel.title) ?? none }, set: { title in
            model.bind(DataBindingKind.allCases.first { DataSectionModel.title($0) == title })
        })
    }

    static func field(_ model: DataSectionModel, _ kind: DataBindingKind) -> Binding<OpID?> {
        Binding(get: { model.field }, set: { model.bind(kind, field: $0) })
    }

    var body: some View {
        Form {
            Text("Data").font(.headline)
            Picker("Binding", selection: Self.kind(model)) {
                Text(Self.none).tag(Self.none)
                ForEach(model.kinds, id: \.self) { Text(DataSectionModel.title($0)).tag(DataSectionModel.title($0)) }
            }
            .accessibilityIdentifier("object.data.kind")
            if let kind = model.kind {
                Picker("Field", selection: Self.field(model, kind)) {
                    if model.field == nil || model.isMissing { Text("Missing").tag(OpID?.none) }
                    ForEach(model.fields(for: kind)) { Text($0.displayName).tag(OpID?.some($0.id)) }
                }
                .accessibilityIdentifier("object.data.field")
            }
            if model.isMissing {
                Text("The bound field is missing; the object is treated as unbound.").font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("object.data.missing")
            }
        }
        .padding(.horizontal)
    }
}

/// The *Barcode* section: kind, content (a field or text), error correction, quiet zone and
/// *Show text*; each control one change ("Change barcode", "Bind to field", "Unbind").
@MainActor
struct BarcodeSectionModel {
    let panel: ObjectPanelModel
    let nodes: [OpID]
    let props: [Wiretuner_Doc_V1_BarcodeProps]
    let data: DataModel
    let bindings: [DataBindingInfo?]

    init?(_ panel: ObjectPanelModel) {
        let state = panel.document.state
        let nodes = panel.selection.ids.map(\.opID).filter { state.nodeKind($0) == .barcode }
        guard !nodes.isEmpty else { return nil }
        let data = DataModel(state)
        self.panel = panel
        self.nodes = nodes
        props = nodes.map { state.props($0).barcode }
        self.data = data
        bindings = nodes.map { data.binding(of: $0, in: state) }
    }

    private func shared<T: Hashable>(_ values: [T]) -> T? { Set(values).count == 1 ? values.first : nil }

    var symbology: BarcodeSymbology? { shared(props.map { $0.symbology == .code128 ? BarcodeSymbology.code128 : .qr }) }
    var value: String? { shared(props.map(\.value)) }
    var errorCorrection: QRErrorCorrection? {
        shared(props.map { Barcodes.spec($0).errorCorrection })
    }
    var quietZone: Double? { shared(props.map { $0.quietZone > 0 ? $0.quietZone : ($0.symbology == .code128 ? 10 : 4) }) }
    var showText: Bool { props.allSatisfy(\.showText) }
    /// The field every selected barcode takes its content from (a text binding).
    var field: OpID? { shared(bindings.map { $0?.kind == .text ? $0?.field : nil }) ?? nil }
    var isBound: Bool { bindings.contains { $0?.kind == .text } }

    func set(_ values: SetBarcodeFields.Values) { panel.perform(SetBarcodeFields(nodes, values)) }

    /// *Content*: *Field* binds to the first field (or the one chosen); *Text* unbinds.
    func setContent(field: OpID?) {
        guard let chosen = field ?? data.fields.first?.id else { return }
        panel.perform(BindToField(nodes, field: chosen, kind: .text))
    }

    func useText() {
        if isBound { panel.perform(Unbind(nodes)) }
    }

    static let levels: [(QRErrorCorrection, String)] = [(.low, "Low"), (.medium, "Medium"), (.quartile, "Quartile"), (.high, "High")]
}

struct BarcodeSectionView: View {
    let model: BarcodeSectionModel

    static func symbology(_ model: BarcodeSectionModel) -> Binding<BarcodeSymbology?> {
        Binding(get: { model.symbology }, set: { if let value = $0 { model.set(.init(symbology: value)) } })
    }

    static func level(_ model: BarcodeSectionModel) -> Binding<QRErrorCorrection?> {
        Binding(get: { model.errorCorrection }, set: { if let value = $0 { model.set(.init(errorCorrection: value)) } })
    }

    static func showText(_ model: BarcodeSectionModel) -> Binding<Bool> {
        Binding(get: { model.showText }, set: { model.set(.init(showText: $0)) })
    }

    static func content(_ model: BarcodeSectionModel) -> Binding<Bool> {
        Binding(get: { model.isBound }, set: { $0 ? model.setContent(field: nil) : model.useText() })
    }

    static func field(_ model: BarcodeSectionModel) -> Binding<OpID?> {
        Binding(get: { model.field }, set: { model.setContent(field: $0) })
    }

    static func value(_ model: BarcodeSectionModel) -> (String) -> Void { { model.set(.init(value: $0)) } }
    static func quietZone(_ model: BarcodeSectionModel) -> (Double) -> Void { { if $0 >= 0 { model.set(.init(quietZone: $0)) } } }

    var body: some View {
        Form {
            Text("Barcode").font(.headline)
            Picker("Kind", selection: Self.symbology(model)) {
                Text("QR code").tag(BarcodeSymbology?.some(.qr))
                Text("Code 128").tag(BarcodeSymbology?.some(.code128))
            }
            .accessibilityIdentifier("object.barcode.kind")
            Picker("Content", selection: Self.content(model)) {
                Text("Text").tag(false)
                Text("Field").tag(true).disabled(model.data.fields.isEmpty)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("object.barcode.content")
            if model.isBound {
                Picker("Field", selection: Self.field(model)) {
                    ForEach(model.data.fields) { Text($0.displayName).tag(OpID?.some($0.id)) }
                }
                .accessibilityIdentifier("object.barcode.field")
            } else {
                CommitTextField(title: "Text", value: model.value, identifier: "object.barcode.value", commit: Self.value(model))
            }
            if model.symbology == .qr {
                Picker("Error correction", selection: Self.level(model)) {
                    ForEach(BarcodeSectionModel.levels, id: \.0) { Text($0.1).tag(QRErrorCorrection?.some($0.0)) }
                }
                .accessibilityIdentifier("object.barcode.level")
            }
            CommitField(title: model.symbology == .code128 ? "Quiet zone (pt)" : "Quiet zone (modules)", value: model.quietZone,
                        identifier: "object.barcode.quiet", commit: Self.quietZone(model))
            if model.symbology == .code128 {
                Toggle("Show text", isOn: Self.showText(model)).accessibilityIdentifier("object.barcode.showText")
            }
        }
        .padding(.horizontal)
    }
}

/// Inserting a barcode, bound to a field or holding fixed text, as one change "Insert Barcode".
struct InsertBoundBarcode: WTModel.Command {
    let insert: InsertBarcode
    let field: OpID?
    var label: String { insert.label }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let before = builder.ops.count
        var counter = builder.nextCounter
        try insert.execute(&builder, state: state)
        guard let field else { return }
        for op in builder.ops[before...] {
            if case .create(let create)? = op.op, case .barcode? = create.props.kind {
                var props = Wiretuner_Doc_V1_NodeProps()
                props.barcode.common.dataBinding.field = field.elementID
                props.barcode.common.dataBinding.kind = .text
                builder.append(Ops.set(OpID(counter: counter, replica: builder.replica), [DataBindings.path(kind: NodeKind.barcode.rawValue)], values: props))
                return
            }
            counter &+= EngineState.counters(op)
        }
    }
}

/// *Insert Barcode…*: kind, and a field or text for the content.
@MainActor
@Observable
final class InsertBarcodeModel {
    var symbology: BarcodeSymbology = .qr
    var usesField: Bool
    var field: OpID?
    var text = ""
    let fields: [DataFieldInfo]

    init(fields: [DataFieldInfo]) {
        self.fields = fields
        usesField = !fields.isEmpty
        field = fields.first?.id
    }

    var canInsert: Bool { usesField ? field != nil : !text.isEmpty }

    /// The command placing the barcode centred on `center`.
    func command(center: Point, layer: OpID?) -> InsertBoundBarcode {
        let size = symbology == .qr ? 29.0 : 60.0
        let origin = Point(x: center.x - size / 2, y: center.y - size / 2)
        return InsertBoundBarcode(insert: InsertBarcode(usesField ? "" : text, symbology: symbology, at: origin, layer: layer), field: usesField ? field : nil)
    }
}

struct InsertBarcodeSheet: View {
    @Bindable var model: InsertBarcodeModel
    let insert: @MainActor () -> Void
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Barcode").font(.headline)
            Form {
                Picker("Kind", selection: $model.symbology) {
                    Text("QR code").tag(BarcodeSymbology.qr)
                    Text("Code 128").tag(BarcodeSymbology.code128)
                }
                .accessibilityIdentifier("insertBarcode.kind")
                Picker("Content", selection: $model.usesField) {
                    Text("Field").tag(true).disabled(model.fields.isEmpty)
                    Text("Text").tag(false)
                }
                .pickerStyle(.segmented)
                if model.usesField {
                    Picker("Field", selection: $model.field) {
                        ForEach(model.fields) { Text($0.displayName).tag(OpID?.some($0.id)) }
                    }
                    .accessibilityIdentifier("insertBarcode.field")
                } else {
                    TextField("Text", text: $model.text).accessibilityIdentifier("insertBarcode.text")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Insert", action: FileSourceSheet.run(insert, close)).keyboardShortcut(.defaultAction).disabled(!model.canInsert)
                    .accessibilityIdentifier("insertBarcode.commit")
            }
        }
        .padding()
        .frame(width: 360)
    }
}

extension DataFeatures {
    /// *Insert Barcode…*: the sheet; the barcode is placed at the centre of the view.
    @discardableResult
    func presentInsertBarcode() -> InsertBarcodeModel? {
        guard let window = window() else { return nil }
        let model = InsertBarcodeModel(fields: DataModel(window.documentHandle.state).fields)
        window.presentSheet("sheet.insertBarcode") { close in
            InsertBarcodeSheet(model: model, insert: { [weak window] in
                guard let window else { return }
                let center = window.viewport.toPasteboard(window.viewport.viewCenter)
                window.objectEditing.perform(model.command(center: center, layer: window.objectEditing.activeLayer))
            }, close: close)
        }
        return model
    }
}
