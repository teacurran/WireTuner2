import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import WTCRDT
import WTModel
import WTProto

// The Data panel's sheets for fields and for the file, pasted and script sources (data-merge.adoc,
// "Defining fields", "Connecting a data source"; DATA-017).  Each sheet edits a draft and writes
// on its button: one labelled change per setting that changed.

/// The field sheet: name, type, format and transform, adding a field or editing one.
@MainActor
@Observable
final class FieldSheetModel {
    let field: OpID?
    var name: String
    var kind: DataFieldKind
    var pattern: String
    var locale: String
    var transform: OpID?
    private(set) var error: String?
    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let perform: @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>

    static let numberPatterns = ["#,##0.00", "#,##0", "0", "€#,##0.00", "0%"]
    static let datePatterns = ["Short", "Medium", "Long", "d MMMM yyyy", "MM/dd/yy"]

    init(document: DocumentHandle, field: OpID?, perform: @escaping @MainActor (any WTModel.Command) -> Task<Wiretuner_Doc_V1_Change?, Never>) {
        self.document = document
        self.field = field
        self.perform = perform
        let existing = DataModel(document.state).field(field)
        name = existing?.name ?? ""
        kind = existing?.kind ?? .text
        pattern = existing?.pattern ?? ""
        locale = existing?.locale ?? ""
        transform = existing?.transform
    }

    var title: String { field == nil ? "Add Field" : "Edit Field" }
    var button: String { field == nil ? "Add" : "Save" }
    /// Number and Date fields carry a format.
    var usesFormat: Bool { kind == .number || kind == .date }
    var patterns: [String] { kind == .date ? Self.datePatterns : Self.numberPatterns }
    /// The document's scripts a transform can name.
    var scripts: [DocumentScript] { DocumentScript.list(document.state) }

    /// Checks the name and writes the changes; whether the sheet closes.
    @discardableResult
    func commit() -> Bool {
        let model = DataModel(document.state)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard DataFieldsPaths.isValidName(trimmed) else {
            error = DataEditMessages.text(.invalidName(trimmed))
            return false
        }
        if let holder = model.fields.first(where: { $0.name.lowercased() == trimmed.lowercased() && $0.id != field }) {
            error = DataEditMessages.text(.duplicateName(holder.name))
            return false
        }
        let format = usesFormat ? pattern : ""
        guard let field, let existing = model.field(field) else {
            let transform = self.transform
            let document = document
            let perform = perform
            let added = perform(AddFields([AddFields.Field(trimmed, kind: kind, pattern: format, locale: locale)]))
            if let transform {
                Task {
                    _ = await added.value
                    if let id = DataModel(document.state).field(named: trimmed)?.id { _ = perform(SetFieldTransform(id, script: transform)) }
                }
            }
            return true
        }
        if existing.name != trimmed { _ = perform(WTModel.RenameField(field, to: trimmed)) }
        if existing.kind != kind { _ = perform(SetFieldType(field, to: kind)) }
        if existing.pattern != format || existing.locale != locale {
            _ = perform(SetFieldFormat(field, pattern: existing.pattern != format ? format : nil, locale: existing.locale != locale ? locale : nil))
        }
        if existing.transform != transform { _ = perform(SetFieldTransform(field, script: transform)) }
        return true
    }
}

struct FieldSheet: View {
    @Bindable var model: FieldSheetModel
    let close: @MainActor () -> Void

    static func commit(_ model: FieldSheetModel, _ close: @escaping @MainActor () -> Void) -> () -> Void {
        { if model.commit() { close() } }
    }

    static func pattern(_ value: String, _ model: FieldSheetModel) -> () -> Void { { model.pattern = value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Form {
                TextField("Name", text: $model.name).accessibilityIdentifier("field.name")
                Picker("Type", selection: $model.kind) {
                    ForEach(DataFieldKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .accessibilityIdentifier("field.type")
                if model.usesFormat {
                    HStack {
                        TextField("Format", text: $model.pattern, prompt: Text("As is")).accessibilityIdentifier("field.format")
                        Menu("Presets") {
                            ForEach(model.patterns, id: \.self) { Button($0, action: Self.pattern($0, model)) }
                        }
                    }
                    TextField("Locale", text: $model.locale, prompt: Text("Your locale")).accessibilityIdentifier("field.locale")
                }
                Picker("Transform", selection: $model.transform) {
                    Text("None").tag(OpID?.none)
                    ForEach(model.scripts) { Text($0.name.isEmpty ? "Untitled script" : $0.name).tag(OpID?.some($0.id)) }
                }
                .accessibilityIdentifier("field.transform")
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("field.error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button(model.button, action: Self.commit(model, close)).keyboardShortcut(.defaultAction).accessibilityIdentifier("field.commit")
            }
        }
        .padding()
        .frame(width: 380)
    }
}

/// *Insert Field…*: a field to type as a placeholder at the insertion point.
@MainActor
@Observable
final class InsertFieldModel {
    let fields: [DataFieldInfo]
    var chosen: OpID?
    @ObservationIgnored let insert: @MainActor (OpID) -> Void

    init(fields: [DataFieldInfo], insert: @escaping @MainActor (OpID) -> Void) {
        self.fields = fields
        self.insert = insert
        chosen = fields.first?.id
    }

    func commit() {
        if let chosen { insert(chosen) }
    }
}

struct InsertFieldSheet: View {
    @Bindable var model: InsertFieldModel
    let close: @MainActor () -> Void

    static func commit(_ model: InsertFieldModel, _ close: @escaping @MainActor () -> Void) -> () -> Void {
        {
            model.commit()
            close()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert Field").font(.headline)
            if model.fields.isEmpty {
                Text("The document has no fields yet. Add one in the Data panel.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Field", selection: $model.chosen) {
                    ForEach(model.fields) { Text($0.displayName).tag(OpID?.some($0.id)) }
                }
                .accessibilityIdentifier("insertField.field")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Insert", action: Self.commit(model, close)).keyboardShortcut(.defaultAction).disabled(model.chosen == nil)
                    .accessibilityIdentifier("insertField.commit")
            }
        }
        .padding()
        .frame(width: 320)
    }
}

/// The CSV, TSV or JSON file sheet: what was detected (delimiter, encoding, header row, records
/// path), the first rows, and btn:[Connect].
@MainActor
@Observable
final class FileSourceModel {
    let url: URL
    var format: Wiretuner_Doc_V1_FileFormat
    var delimiter: String
    var encoding: String
    var headerRow = true
    var recordsPath = ""
    private(set) var preview: DataTable?
    private(set) var error: String?

    static let delimiters: [(title: String, value: String)] = [("Comma", ","), ("Semicolon", ";"), ("Tab", "\t")]

    init(url: URL, json: Bool) {
        self.url = url
        let format = json ? .json : DataFileOptions.format(forFileName: url.lastPathComponent)
        self.format = format
        let detected = try? DataFileReader.detect(url, format: format)
        delimiter = detected?.delimiter.map(String.init) ?? (format == .tsv ? "\t" : ",")
        encoding = (detected?.encoding ?? .utf8).rawValue
        reread()
    }

    var isJSON: Bool { format == .json }

    var options: DataFileOptions {
        DataFileOptions(format: format, delimiter: isJSON ? "" : delimiter, encoding: encoding, headerRow: headerRow, recordsPath: recordsPath)
    }

    /// Reads the first rows again with the settings as corrected.
    func reread() {
        do {
            preview = try DataFileReader.read(url, options: options, limit: 5).table
            error = nil
        } catch {
            preview = nil
            self.error = String(describing: error)
        }
    }

    /// The source to connect: the settings, the file's name for display and its bookmark.
    func source() throws -> Wiretuner_Doc_V1_DataSource {
        var source = Wiretuner_Doc_V1_DataSource()
        source.name = url.deletingPathExtension().lastPathComponent
        source.spec.kind = .file
        var file = Wiretuner_Doc_V1_FileSource()
        file.format = format
        file.fileName = String(url.lastPathComponent.prefix(256))
        file.delimiter = isJSON ? "" : delimiter
        file.encoding = encoding
        file.headerRow = headerRow
        file.recordsPath = recordsPath
        file.bookmark = try DataFileBookmarks.make(url)
        source.spec.file = file
        return source
    }
}

struct FileSourceSheet: View {
    @Bindable var model: FileSourceModel
    let connect: @MainActor () -> Void
    let close: @MainActor () -> Void

    static func run(_ connect: @escaping @MainActor () -> Void, _ close: @escaping @MainActor () -> Void) -> () -> Void {
        {
            connect()
            close()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.url.lastPathComponent).font(.headline)
            Form {
                if model.isJSON {
                    TextField("Records path", text: $model.recordsPath, prompt: Text("The top level")).onSubmit(model.reread)
                        .accessibilityIdentifier("file.recordsPath")
                } else {
                    Picker("Delimiter", selection: $model.delimiter) {
                        ForEach(FileSourceModel.delimiters, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    .accessibilityIdentifier("file.delimiter")
                    Toggle("First row names the columns", isOn: $model.headerRow).accessibilityIdentifier("file.header")
                }
                Picker("Encoding", selection: $model.encoding) {
                    ForEach(DataTextEncoding.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("file.encoding")
            }
            .onChange(of: model.options) { model.reread() }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("file.error")
            } else if let preview = model.preview {
                Text(preview.columns.joined(separator: " · ")).font(.caption.bold()).lineLimit(2)
                ForEach(preview.records.indices, id: \.self) { index in
                    Text(preview.columns.map { preview.records[index][$0] ?? "" }.joined(separator: " · ")).font(.caption).lineLimit(1)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Connect", action: Self.run(connect, close)).keyboardShortcut(.defaultAction).disabled(model.preview == nil)
                    .accessibilityIdentifier("file.connect")
            }
        }
        .padding()
        .frame(width: 440)
    }
}

/// *Connect… > Script…*: a document script exporting `records`.
@MainActor
@Observable
final class ScriptSourceModel {
    let scripts: [DocumentScript]
    var chosen: OpID?

    init(scripts: [DocumentScript]) {
        self.scripts = scripts
        chosen = scripts.first { $0.source.contains("records") }?.id ?? scripts.first?.id
    }

    var source: Wiretuner_Doc_V1_DataSource? {
        guard let chosen, let script = scripts.first(where: { $0.id == chosen }) else { return nil }
        var source = Wiretuner_Doc_V1_DataSource()
        source.name = script.name
        source.spec.kind = .script
        source.spec.script.script.id = chosen.proto
        return source
    }
}

struct ScriptSourceSheet: View {
    @Bindable var model: ScriptSourceModel
    let connect: @MainActor () -> Void
    let close: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Script Source").font(.headline)
            if model.scripts.isEmpty {
                Text("The document has no scripts. Write one in the Script Editor and choose Save to Document.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Script", selection: $model.chosen) {
                    ForEach(model.scripts) { Text($0.name.isEmpty ? "Untitled script" : $0.name).tag(OpID?.some($0.id)) }
                }
                .accessibilityIdentifier("scriptSource.script")
                Text("The script must export a records(params) function returning an array of objects.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Connect", action: FileSourceSheet.run(connect, close)).keyboardShortcut(.defaultAction).disabled(model.source == nil)
                    .accessibilityIdentifier("scriptSource.connect")
            }
        }
        .padding()
        .frame(width: 380)
    }
}

extension DataFeatures {
    // MARK: Fields

    /// The field sheet: a new field (nil) or `field`.
    @discardableResult
    func presentFieldSheet(editing field: OpID?) -> FieldSheetModel? {
        guard let window = window() else { return nil }
        let model = FieldSheetModel(document: window.documentHandle, field: field) { [weak window] in
            window?.objectEditing.perform($0) ?? Task { nil }
        }
        window.presentSheet("sheet.dataField") { close in FieldSheet(model: model, close: close) }
        return model
    }

    /// *Insert Field…*.
    @discardableResult
    func presentInsertField() -> InsertFieldModel? {
        guard let window = window() else { return nil }
        let model = InsertFieldModel(fields: DataModel(window.documentHandle.state).fields) { [weak self, weak window] field in
            if let window { self?.insertField(field, in: window) }
        }
        window.presentSheet("sheet.insertField") { close in InsertFieldSheet(model: model, close: close) }
        return model
    }

    /// Types `{{name}}` under the field's mark at the Text tool's insertion point, or at the end of
    /// the one selected text block; one change "Insert field".
    @discardableResult
    func insertField(_ field: OpID, in window: DocumentWindowController) -> Bool {
        if let session = window.objectEditing.textSession, session.node != nil {
            session.insertField(field)
            return true
        }
        let state = window.documentHandle.state
        let texts = window.selection.model.selection.ids.map(\.opID).filter { state.nodeKind($0) == .text }
        guard texts.count == 1 else {
            window.canvas.showStatusMessage("Click in a text block with the Text tool, or select one text block, to insert a field.")
            return false
        }
        window.objectEditing.perform(InsertPlaceholder(node: texts[0], at: .end, field: field))
        return true
    }

    // MARK: Sources

    /// *Connect… > CSV or TSV File…* / *JSON File…*: the open panel, then the file sheet.
    func chooseFile(json: Bool) async {
        guard let window = window() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = json ? [.json] : [.commaSeparatedText, .tabSeparatedText, .plainText]
        guard let url = await ModalUI.urls(panel, on: window.window).first else { return }
        presentFileSheet(url, json: json)
    }

    /// The file sheet for `url`.
    @discardableResult
    func presentFileSheet(_ url: URL, json: Bool) -> FileSourceModel? {
        guard let window = window() else { return nil }
        let model = FileSourceModel(url: url, json: json)
        window.presentSheet("sheet.fileSource") { close in
            FileSourceSheet(model: model, connect: { [weak self] in self?.connect(model) }, close: close)
        }
        return model
    }

    /// Connects the file the sheet describes; the records are read at once.
    @discardableResult
    func connect(_ model: FileSourceModel) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let window = window() else { return nil }
        do {
            return window.objectEditing.perform(AddSource(try model.source()))
        } catch {
            ModalUI.alert("The file could not be connected.", String(describing: error), on: window.window)
            return nil
        }
    }

    /// *Connect… > Pasted Table*: the pasteboard's rows as a pasted source stored in the document
    /// (pasting over a pasted source replaces its rows).
    @discardableResult
    func connectPastedTable(from pasteboard: NSPasteboard = .general) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        guard let (window, session) = front else { return nil }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            ModalUI.alert("There is no table to paste.", "Copy rows from Numbers, Excel or any table first.", on: window.window)
            return nil
        }
        let table = DataTable.pasted(text)
        let data = Data(table.csv().utf8)
        var sample = Wiretuner_Doc_V1_EmbeddedRecords()
        sample.blobSha256 = Data(SHA256Digest.of(data))
        sample.mediaType = "text/csv"
        sample.recordCount = UInt32(table.records.count)
        sample.complete = true
        sample.fetchedAtMs = Int64(session.clock().timeIntervalSince1970 * 1000)
        let blobs = self.blobs
        let document = window.documentHandle
        let existing = session.model.activeSource.flatMap { $0.kind == .pasted ? $0 : nil }
        return Task { [weak window] in
            do {
                try await blobs.store([(data: data, mediaType: "text/csv")], for: document)
            } catch {
                return nil
            }
            if let existing { return await window?.objectEditing.perform(SetSample(existing.id, sample)).value }
            var source = Wiretuner_Doc_V1_DataSource()
            source.name = "Pasted table"
            source.spec.kind = .pasted
            source.spec.pasted.pastedAtMs = sample.fetchedAtMs
            source.sample = sample
            return await window?.objectEditing.perform(AddSource(source)).value
        }
    }

    /// *Connect… > Script…*.
    @discardableResult
    func presentScriptSource() -> ScriptSourceModel? {
        guard let window = window() else { return nil }
        let model = ScriptSourceModel(scripts: DocumentScript.list(window.documentHandle.state))
        window.presentSheet("sheet.scriptSource") { close in
            ScriptSourceSheet(model: model, connect: { [weak window] in
                if let source = model.source { window?.objectEditing.perform(AddSource(source)) }
            }, close: close)
        }
        return model
    }
}

/// SHA-256 of blob bytes (a blob is named by its hash).
enum SHA256Digest {
    static func of(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }
}
