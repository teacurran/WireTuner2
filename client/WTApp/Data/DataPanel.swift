import AppKit
import SwiftUI
import WTCRDT
import WTModel
import WTProto

/// What the Data panel shows for the front window and what its controls do (data-merge.adoc, "The
/// Data panel"): read on every render from the document and the window's session; each control
/// writes one labelled change through the window's object commands, or changes only this window's
/// session (the record navigator, the preview, typed parameters).
@MainActor
struct DataPanelModel {
    let features: DataFeatures
    let window: DocumentWindowController
    let session: DataSession

    var document: DocumentHandle { window.documentHandle }
    var model: DataModel { session.model }
    var source: DataSourceInfo? { model.activeSource }

    @discardableResult
    func perform(_ command: any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never> {
        window.objectEditing.perform(command)
    }

    // MARK: Source

    /// The source's name and kind line.
    var sourceTitle: String {
        guard let source else { return "None" }
        return "\(source.name.isEmpty ? "Untitled" : source.name) (\(Self.kindTitle(source.kind)))"
    }

    static func kindTitle(_ kind: Wiretuner_Doc_V1_DataSourceKind) -> String {
        switch kind {
        case .file: "File"
        case .pasted: "Pasted table"
        case .http: "Web API"
        case .script: "Script"
        default: "Unknown"
        }
    }

    /// The *Connect…* pop-up's items.
    enum Connect: String, CaseIterable, Identifiable {
        case delimited = "CSV or TSV File…"
        case json = "JSON File…"
        case pasted = "Pasted Table"
        case web = "Web API…"
        case script = "Script…"

        var id: String { rawValue }
    }

    func connect(_ kind: Connect) {
        switch kind {
        case .delimited: Task { await features.chooseFile(json: false) }
        case .json: Task { await features.chooseFile(json: true) }
        case .pasted: features.connectPastedTable()
        case .web: features.presentWebSource(editing: source?.kind == .http ? source : nil)
        case .script: features.presentScriptSource()
        }
    }

    /// *Disconnect*: no source connected (its settings stay for switching back).
    func disconnect() {
        if source != nil { perform(SetActiveSource(nil)) }
    }

    func refresh() {
        Task { await session.refresh() }
    }

    /// The API source's parameters, with the typed values over the shared defaults.
    var parameters: [(name: String, value: String, placeholder: String)] {
        guard let source, source.kind == .http else { return [] }
        return source.http.params.map { (name: $0.name, value: session.params[$0.name] ?? "", placeholder: $0.defaultValue) }
    }

    func setParameter(_ name: String, _ value: String) {
        session.params[name] = value
    }

    // MARK: Fields

    struct FieldRow: Identifiable, Equatable {
        let id: OpID
        let name: String
        let kind: DataFieldKind
        let value: String?
        let uses: Int
    }

    var fieldRows: [FieldRow] {
        let uses = model.uses(in: document.state)
        return model.fields.map { field in
            FieldRow(id: field.id, name: field.displayName, kind: field.kind, value: session.value(of: field.id), uses: uses[field.id] ?? 0)
        }
    }

    func addField() { features.presentFieldSheet(editing: nil) }

    func editField(_ id: OpID) { features.presentFieldSheet(editing: id) }

    /// Deletes a field, asking first when something uses it.
    func deleteField(_ id: OpID) {
        guard let field = model.field(id) else { return }
        let uses = DeleteField.uses(of: id, in: document.state)
        if uses > 0 {
            let places = uses == 1 ? "1 place uses it" : "\(uses) places use it"
            guard window.confirm("Delete the field “\(field.displayName)”?", "\(places); they show {{missing}} until you delete or rebind them.") else { return }
        }
        perform(DeleteField(id))
    }

    /// Inserts `{{name}}` at the Text tool's insertion point (or at the end of the one selected
    /// text block).
    func insertField(_ id: OpID) { features.insertField(id, in: window) }

    // MARK: Mapping

    /// The source's columns, when it has records.
    var columns: [String] { session.table?.columns ?? [] }

    /// Whether the *Mapping* table shows: records with columns, and a field not matched by name.
    var showsMapping: Bool {
        guard source != nil, !columns.isEmpty else { return false }
        let available = Set(columns.map { $0.lowercased() })
        return model.fields.contains { !available.contains(model.path(of: $0, in: source).lowercased()) } || !(source?.mapping.isEmpty ?? true)
    }

    /// The column or path a field reads.
    func path(of id: OpID) -> String {
        guard let field = model.field(id) else { return "" }
        return model.path(of: field, in: source)
    }

    /// Pairs a field with a column ("" unpairs: the column of its own name).
    func setMapping(_ id: OpID, _ path: String) {
        guard let source, let field = model.field(id), model.path(of: field, in: source) != path || path.isEmpty else { return }
        perform(SetMapping(source.id, field: id, path: path.isEmpty || path == field.name ? nil : path))
    }

    // MARK: Records

    var recordCount: Int { session.records.count }
    var recordNumber: Int { session.records.isEmpty ? 0 : session.currentIndex + 1 }

    /// The first records as the sample table shows them: the columns, then up to five rows.
    var sampleRows: (columns: [String], rows: [[String]]) {
        guard let table = session.table else { return ([], []) }
        let columns = Array(table.columns.prefix(6))
        return (columns, table.records.prefix(5).map { record in columns.map { record[$0] ?? "" } })
    }

    func merge() { features.presentMerge() }
}

/// The panel body: follows the front window and its session.
struct DataPanelBody: View {
    let state: DataPanelState
    let features: DataFeatures

    var body: some View {
        let _ = state.revision
        if let window = state.window(), let session = state.session(window) {
            let _ = session.revision
            let _ = window.documentHandle.model?.revision
            DataPanelContent(model: DataPanelModel(features: features, window: window, session: session), session: session)
        } else {
            Text("No document").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("data.none")
        }
    }
}

struct DataPanelContent: View {
    let model: DataPanelModel
    let session: DataSession

    // The controls' bindings, as values the tests can drive.

    static func parameter(_ name: String, _ model: DataPanelModel) -> Binding<String> {
        Binding(get: { model.session.params[name] ?? "" }, set: { model.setParameter(name, $0) })
    }

    static func preview(_ model: DataPanelModel) -> Binding<Bool> {
        Binding(get: { model.session.preview.showing }, set: { model.session.setPreview($0) })
    }

    static func mapping(_ id: OpID, _ model: DataPanelModel) -> Binding<String> {
        Binding(get: { model.path(of: id) }, set: { model.setMapping(id, $0) })
    }

    static func connect(_ kind: DataPanelModel.Connect, _ model: DataPanelModel) -> () -> Void { { model.connect(kind) } }
    static func edit(_ id: OpID, _ model: DataPanelModel) -> () -> Void { { model.editField(id) } }
    static func delete(_ id: OpID, _ model: DataPanelModel) -> () -> Void { { model.deleteField(id) } }
    static func insert(_ id: OpID, _ model: DataPanelModel) -> () -> Void { { model.insertField(id) } }
    static func go(_ model: DataPanelModel) -> (Double) -> Void { { model.session.go(to: Int($0)) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                sourceSection
                Divider()
                fieldsSection
                if model.showsMapping {
                    Divider()
                    mappingSection
                }
                Divider()
                recordsSection
                Button("Merge…", action: model.merge)
                    .disabled(model.recordCount == 0)
                    .accessibilityIdentifier("data.merge")
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source").font(.headline)
            Text(model.sourceTitle).accessibilityIdentifier("data.source")
            Text(session.status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("data.status")
            if let message = session.message {
                Text(message).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("data.message")
            }
            ForEach(model.parameters, id: \.name) { parameter in
                TextField(parameter.name, text: Self.parameter(parameter.name, model), prompt: Text(parameter.placeholder))
                    .accessibilityIdentifier("data.param.\(parameter.name)")
            }
            HStack {
                Button("Refresh", action: model.refresh)
                    .disabled(model.source == nil || session.isFetching)
                    .accessibilityIdentifier("data.refresh")
                Menu("Connect…") {
                    ForEach(DataPanelModel.Connect.allCases) { kind in
                        Button(kind.rawValue, action: Self.connect(kind, model))
                    }
                    Divider()
                    Button("Disconnect", action: model.disconnect).disabled(model.source == nil)
                }
                .accessibilityIdentifier("data.connect")
            }
        }
    }

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Fields").font(.headline)
                Spacer()
                Button(action: model.addField) { Image(systemName: "plus") }
                    .help("Add a field")
                    .accessibilityIdentifier("data.addField")
            }
            ForEach(model.fieldRows) { row in
                HStack {
                    Text(row.name).fontWeight(.medium)
                    Text(row.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.value ?? "").font(.caption).lineLimit(1)
                    Text("\(row.uses)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("Places that use the field")
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: Self.edit(row.id, model))
                .contextMenu {
                    Button("Insert Field", action: Self.insert(row.id, model))
                    Button("Edit…", action: Self.edit(row.id, model))
                    Button("Delete…", action: Self.delete(row.id, model))
                }
                .accessibilityIdentifier("data.field.\(row.name)")
            }
            if model.fieldRows.isEmpty {
                Text("No fields yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mapping").font(.headline)
            ForEach(model.model.fields) { field in
                Picker(field.displayName, selection: Self.mapping(field.id, model)) {
                    Text("(\(field.name))").tag(field.name)
                    ForEach(model.columns, id: \.self) { Text($0).tag($0) }
                    if !model.columns.contains(model.path(of: field.id)) && model.path(of: field.id) != field.name {
                        Text(model.path(of: field.id)).tag(model.path(of: field.id))
                    }
                }
                .accessibilityIdentifier("data.mapping.\(field.name)")
            }
        }
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Records").font(.headline)
            HStack {
                Button(action: session.previous) { Image(systemName: "chevron.left") }
                    .disabled(model.recordNumber <= 1)
                    .accessibilityIdentifier("data.previous")
                CommitField(title: "Record", value: Double(model.recordNumber), identifier: "data.record", commit: Self.go(model))
                    .frame(width: 90)
                Text("of \(model.recordCount)").font(.caption)
                Button(action: session.next) { Image(systemName: "chevron.right") }
                    .disabled(model.recordNumber >= model.recordCount)
                    .accessibilityIdentifier("data.next")
                Toggle("Preview", isOn: Self.preview(model))
                    .disabled(model.recordCount == 0)
                    .accessibilityIdentifier("data.preview")
            }
            let sample = model.sampleRows
            if !sample.columns.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow { ForEach(sample.columns, id: \.self) { Text($0).font(.caption.bold()).lineLimit(1) } }
                    ForEach(sample.rows.indices, id: \.self) { index in
                        GridRow { ForEach(sample.rows[index].indices, id: \.self) { Text(sample.rows[index][$0]).font(.caption).lineLimit(1) } }
                    }
                }
                .accessibilityIdentifier("data.sample")
            }
        }
    }
}

extension DataPanel {
    /// The *Options* menu's panel items (the same commands as menu:File[Data Merge]).
    @MainActor
    static func optionsMenu(_ features: DataFeatures) -> [PanelMenuItem] {
        let session = features.front?.session
        let hasRecords = !(session?.records.isEmpty ?? true)
        let hasWindow = features.front != nil
        return [
            PanelMenuItem(title: "Insert Field…", isEnabled: hasWindow) { features.presentInsertField() },
            PanelMenuItem(title: "Insert Barcode…", isEnabled: hasWindow) { features.presentInsertBarcode() },
            PanelMenuItem(title: "Add Fields from Source", isEnabled: hasRecords) { features.addFieldsFromSource() },
            PanelMenuItem(title: "Embed Sample", isEnabled: hasRecords) { Task { await session?.embed(all: false) } },
            PanelMenuItem(title: "Embed All Records", isEnabled: hasRecords) { Task { await session?.embed(all: true) } },
            PanelMenuItem(title: "Export Data…", isEnabled: hasRecords) { Task { await features.exportData() } },
            PanelMenuItem(title: "Credentials…", isEnabled: hasWindow) { features.presentCredentials() },
            PanelMenuItem(title: "Show Hosts", isEnabled: hasWindow) { features.presentHosts() },
        ]
    }
}

/// menu:Window[Data].
enum DataPanel {
    @MainActor
    static func descriptor(state: DataPanelState, features: DataFeatures) -> PanelDescriptor {
        PanelDescriptor(id: "data", title: "Data", icon: "tablecells", defaultGroup: DataFeatures.panelGroup, menuOrder: 85, helpSlug: "data-merge",
                        optionsMenu: { optionsMenu(features) }) {
            DataPanelBody(state: state, features: features)
        }
    }
}
