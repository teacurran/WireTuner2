import Foundation
import WTCRDT
import WTProto

// DATA-003: `WTModel.DataCommands` (data-merge.adoc, "Client", "Fields and bindings"): the Data
// panel's field, source, mapping and sample edits and the Object panel's bindings, each one
// labelled change whose undo restores the prior registers (APP-011's inverse path).

/// Why a data command refused to build its change.  Thrown before anything is appended.
public enum DataEditError: Error, Hashable, Sendable {
    /// Not `[A-Za-z_][A-Za-z0-9_]*` or longer than 64 characters.
    case invalidName(String)
    /// Another live field already has this name (compared case-insensitively).
    case duplicateName(String)
    /// The field is not a live field of the document.
    case unknownField(OpID)
    /// The source is not a live source of the document.
    case unknownSource(OpID)
    /// The binding kind does not apply to this node's kind (an image binding on a rectangle).
    case bindingNotAllowed(OpID)
    /// A credential header in a source definition (Authorization, Proxy-Authorization, Cookie,
    /// X-Api-Key): credentials go through `credential_name`.
    case secretHeader(String)
    /// A source URL that is not `https`.
    case invalidURL(String)
    /// No completed `{{name}}` before the caret.
    case noPlaceholder
    /// A value out of range, named.
    case invalidValue(String)
}

/// Shared helpers of the data commands.
enum DataEditing {
    /// The header names a source definition may never carry (data.proto, `HttpHeader.name`).
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "x-api-key"]

    static func model(_ state: EngineState) -> DataModel { DataModel(state) }

    /// Throws unless `name` is a valid name held by no live field but `except`.
    static func checkName(_ name: String, in model: DataModel, except: OpID? = nil) throws {
        guard DataFieldsPaths.isValidName(name) else { throw DataEditError.invalidName(name) }
        if let holder = model.fields.first(where: { $0.name.lowercased() == name.lowercased() && $0.id != except }) {
            throw DataEditError.duplicateName(holder.name)
        }
    }

    static func field(_ id: OpID, in state: EngineState) throws -> DataFieldInfo {
        guard let field = DataModel(state).field(id) else { throw DataEditError.unknownField(id) }
        return field
    }

    static func source(_ id: OpID, in state: EngineState) throws -> DataSourceInfo {
        guard let source = DataModel(state).source(id) else { throw DataEditError.unknownSource(id) }
        return source
    }

    /// Position keys for `count` elements after the last element of `sequence` on the settings
    /// node (tombstones included, so a restored element keeps its place).
    static func appendKeys(_ sequence: RegisterPath, count: Int, in state: EngineState) throws -> [[UInt8]] {
        let last = state.store.elementOrder(WellKnown.settings, sequence).last.flatMap { state.position(WellKnown.settings, sequence, $0) }
        return try PathEditing.keys(between: last, and: nil, count: count)
    }

    /// Throws for a secret header name or a URL that is not `https` (the doc.v1 validation the
    /// server applies on ingest, checked before writing so the panel can say so).
    static func validate(_ http: Wiretuner_Doc_V1_HttpSource) throws {
        if !http.url.isEmpty, !http.url.lowercased().hasPrefix("https://") { throw DataEditError.invalidURL(http.url) }
        for header in http.headers where secretHeaders.contains(header.name.lowercased()) {
            throw DataEditError.secretHeader(header.name)
        }
    }

    /// The ops inserting `source` (its nested sequences -- headers, params and mapping -- as their
    /// own `ElementInsert`s after the element) at `key`; returns the element id.
    @discardableResult
    static func insertSource(_ source: Wiretuner_Doc_V1_DataSource, key: [UInt8], builder: inout ChangeBuilder) -> OpID {
        var element = source
        let headers = element.spec.http.headers
        let params = element.spec.http.params
        let mapping = element.mapping
        element.spec.http.headers = []
        element.spec.http.params = []
        element.mapping = []
        element.clearID()
        let id = builder.append(Ops.elementInsert(WellKnown.settings, DataFieldsPaths.sources, positions: [key],
                                                  values: DataFieldsPaths.values { $0.dataSources = [element] }))
        let http = DataFieldsPaths.spec(id).child(4)
        insertHeaders(headers, at: http.child(3), source: id, builder: &builder)
        insertParams(params, at: http.child(8), source: id, builder: &builder)
        if !mapping.isEmpty {
            let keys = (try? PathEditing.keys(between: nil, and: nil, count: mapping.count)) ?? []
            var copy = element
            copy.mapping = mapping.map { entry in
                var entry = entry
                entry.clearID()
                return entry
            }
            builder.append(Ops.elementInsert(WellKnown.settings, DataFieldsPaths.mapping(id), positions: keys,
                                             values: sourceValues(id: id, copy)))
        }
        return id
    }

    /// Settings values holding one source element `id` (for writes below it).
    static func sourceValues(id: OpID, _ source: Wiretuner_Doc_V1_DataSource) -> Wiretuner_Doc_V1_NodeProps {
        var element = source
        element.id = id.elementID
        return DataFieldsPaths.values { $0.dataSources = [element] }
    }

    static func insertHeaders(_ headers: [Wiretuner_Doc_V1_HttpHeader], at path: RegisterPath, source: OpID, builder: inout ChangeBuilder) {
        guard !headers.isEmpty, let keys = try? PathEditing.keys(between: nil, and: nil, count: headers.count) else { return }
        var element = Wiretuner_Doc_V1_DataSource()
        element.spec.http.headers = headers.map { header in
            var header = header
            header.clearID()
            return header
        }
        builder.append(Ops.elementInsert(WellKnown.settings, path, positions: keys, values: sourceValues(id: source, element)))
    }

    static func insertParams(_ params: [Wiretuner_Doc_V1_HttpParam], at path: RegisterPath, source: OpID, builder: inout ChangeBuilder) {
        guard !params.isEmpty, let keys = try? PathEditing.keys(between: nil, and: nil, count: params.count) else { return }
        var element = Wiretuner_Doc_V1_DataSource()
        element.spec.http.params = params.map { param in
            var param = param
            param.clearID()
            return param
        }
        builder.append(Ops.elementInsert(WellKnown.settings, path, positions: keys, values: sourceValues(id: source, element)))
    }
}

// MARK: - Fields

/// The Data panel's btn:[+] and *Add Fields from Source*: appends one field per entry, "Add
/// field" / "Add 3 fields".  Names are checked for validity and uniqueness among live fields and
/// among the new ones.
public struct AddFields: Command {
    public struct Field: Hashable, Sendable {
        public var name: String
        public var kind: DataFieldKind
        public var pattern: String
        public var locale: String

        public init(_ name: String, kind: DataFieldKind = .text, pattern: String = "", locale: String = "") {
            self.name = name
            self.kind = kind
            self.pattern = pattern
            self.locale = locale
        }
    }

    public var fields: [Field]
    public var label: String { fields.count == 1 ? "Add field" : "Add \(fields.count) fields" }

    public init(_ fields: [Field]) {
        self.fields = fields
    }

    public init(_ name: String, kind: DataFieldKind = .text, pattern: String = "", locale: String = "") {
        self.init([Field(name, kind: kind, pattern: pattern, locale: locale)])
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let model = DataModel(state)
        var seen: Set<String> = []
        for field in fields {
            try DataEditing.checkName(field.name, in: model)
            guard seen.insert(field.name.lowercased()).inserted else { throw DataEditError.duplicateName(field.name) }
            guard field.pattern.count <= 64, field.locale.count <= 32 else { throw DataEditError.invalidValue("format") }
        }
        guard !fields.isEmpty else { return }
        let keys = try DataEditing.appendKeys(DataFieldsPaths.fields, count: fields.count, in: state)
        let elements = fields.map { field in
            var element = Wiretuner_Doc_V1_DataField()
            element.name = field.name
            element.type = field.kind.stored
            element.format.pattern = field.pattern
            element.format.locale = field.locale
            return element
        }
        builder.append(Ops.elementInsert(WellKnown.settings, DataFieldsPaths.fields, positions: keys,
                                         values: DataFieldsPaths.values { $0.dataFields = elements }))
    }
}

/// Double-click › rename: "Rename field".  Every placeholder and binding holds the element id,
/// so they follow.
public struct RenameField: Command {
    public var field: OpID
    public var name: String
    public var label: String { "Rename field" }

    public init(_ field: OpID, to name: String) {
        self.field = field
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let model = DataModel(state)
        guard model.field(field) != nil else { throw DataEditError.unknownField(field) }
        try DataEditing.checkName(name, in: model, except: field)
        var element = Wiretuner_Doc_V1_DataField()
        element.id = field.elementID
        element.name = name
        builder.append(Ops.set(WellKnown.settings, [DataFieldsPaths.name(field)], values: DataFieldsPaths.values { $0.dataFields = [element] }))
    }
}

/// The field sheet's *Type* pop-up: "Change field type".
public struct SetFieldType: Command {
    public var field: OpID
    public var kind: DataFieldKind
    public var label: String { "Change field type" }

    public init(_ field: OpID, to kind: DataFieldKind) {
        self.field = field
        self.kind = kind
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.field(field, in: state)
        var element = Wiretuner_Doc_V1_DataField()
        element.id = field.elementID
        element.type = kind.stored
        builder.append(Ops.set(WellKnown.settings, [DataFieldsPaths.type(field)], values: DataFieldsPaths.values { $0.dataFields = [element] }))
    }
}

/// The field sheet's *Format*: pattern and/or locale (independent registers), "Change field
/// format".
public struct SetFieldFormat: Command {
    public var field: OpID
    public var pattern: String?
    public var locale: String?
    public var label: String { "Change field format" }

    public init(_ field: OpID, pattern: String? = nil, locale: String? = nil) {
        self.field = field
        self.pattern = pattern
        self.locale = locale
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.field(field, in: state)
        if let pattern, pattern.count > 64 { throw DataEditError.invalidValue("pattern") }
        if let locale, locale.count > 32 { throw DataEditError.invalidValue("locale") }
        var element = Wiretuner_Doc_V1_DataField()
        element.id = field.elementID
        var paths: [RegisterPath] = []
        if let pattern {
            element.format.pattern = pattern
            paths.append(DataFieldsPaths.formatPattern(field))
        }
        if let locale {
            element.format.locale = locale
            paths.append(DataFieldsPaths.formatLocale(field))
        }
        guard !paths.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, paths, values: DataFieldsPaths.values { $0.dataFields = [element] }))
    }
}

/// *Transform…*: the `script` node exporting `transform`, or none, "Change transform".
public struct SetFieldTransform: Command {
    public var field: OpID
    public var script: OpID?
    public var label: String { "Change transform" }

    public init(_ field: OpID, script: OpID?) {
        self.field = field
        self.script = script
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.field(field, in: state)
        if let script, !DataModel.isScript(script, in: state) { throw DataEditError.invalidValue("script") }
        var element = Wiretuner_Doc_V1_DataField()
        element.id = field.elementID
        if let script { element.transform.id = script.proto }
        builder.append(Ops.set(WellKnown.settings, [DataFieldsPaths.transform(field)], values: DataFieldsPaths.values { $0.dataFields = [element] }))
    }
}

/// Deleting a field (after the confirmation when it is used): one `ElementDelete`, "Delete
/// field".  Its placeholders read `{{missing}}` and its bindings the *missing* badge until the
/// field is restored or they are removed.
public struct DeleteField: Command {
    public var field: OpID
    public var label: String { "Delete field" }

    public init(_ field: OpID) {
        self.field = field
    }

    /// How many placeholders and bindings use `field`: the count the confirmation names.
    public static func uses(of field: OpID, in state: EngineState) -> Int {
        DataModel(state).uses(in: state)[field] ?? 0
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.field(field, in: state)
        builder.append(Ops.elementDelete(WellKnown.settings, [DataFieldsPaths.fields.element(field)]))
    }
}

/// *Restore field* (the live notice and the review sheet): `deleted = false` on the element, so
/// every dangling reference resolves again, "Restore field".
public struct RestoreField: Command {
    public var field: OpID
    public var label: String { "Restore field" }

    public init(_ field: OpID) {
        self.field = field
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.store.element(WellKnown.settings, DataFieldsPaths.fields.element(field)) != nil else { throw DataEditError.unknownField(field) }
        builder.append(Ops.elementDelete(WellKnown.settings, [DataFieldsPaths.fields.element(field)], deleted: false))
    }
}

// MARK: - Sources

/// *Connect…*: appends a source and makes it the connected one, "Connect source".  The spec's
/// HTTP settings are validated (https, no credential header).
public struct AddSource: Command {
    public var source: Wiretuner_Doc_V1_DataSource
    public var activate: Bool
    public var label: String { "Connect source" }

    public init(_ source: Wiretuner_Doc_V1_DataSource, activate: Bool = true) {
        self.source = source
        self.activate = activate
    }

    /// A source named `name` of `kind` whose spec `build` fills.
    public init(name: String, kind: Wiretuner_Doc_V1_DataSourceKind, activate: Bool = true,
                _ build: (inout Wiretuner_Doc_V1_DataSourceSpec) -> Void = { _ in }) {
        var source = Wiretuner_Doc_V1_DataSource()
        source.name = String(name.prefix(128))
        source.spec.kind = kind
        if kind == .file { source.spec.file.headerRow = true }
        build(&source.spec)
        self.init(source, activate: activate)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try DataEditing.validate(source.spec.http)
        let key = try DataEditing.appendKeys(DataFieldsPaths.sources, count: 1, in: state)[0]
        let id = DataEditing.insertSource(source, key: key, builder: &builder)
        if activate {
            builder.append(Ops.set(WellKnown.settings, [DataFieldsPaths.activeSource], values: DataFieldsPaths.values { $0.dataSourceActive = id.elementID }))
        }
    }
}

/// Writes registers of a source's spec: `paths` below `DataSourceSpec` (`[1]` the kind, `[4, 2]`
/// the HTTP URL, `[2, 6]` a JSON file's records path ...), from `spec`; and/or its name.
/// "Change source".  SEQUENCEs (headers, params) are edited by `SetSourceHeaders` and
/// `SetSourceParams`.
public struct EditSource: Command {
    public var source: OpID
    public var name: String?
    public var spec: Wiretuner_Doc_V1_DataSourceSpec
    public var paths: [[UInt32]]
    public var label: String { "Change source" }

    public init(_ source: OpID, name: String? = nil, spec: Wiretuner_Doc_V1_DataSourceSpec = .init(), paths: [[UInt32]] = []) {
        self.source = source
        self.name = name
        self.spec = spec
        self.paths = paths
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.source(source, in: state)
        guard paths.allSatisfy({ !$0.isEmpty && !($0.count >= 2 && $0[0] == 4 && ($0[1] == 3 || $0[1] == 8)) }) else {
            throw DataEditError.invalidValue("paths")
        }
        try DataEditing.validate(spec.http)
        var element = Wiretuner_Doc_V1_DataSource()
        element.spec = spec
        var registers = paths.map { $0.reduce(DataFieldsPaths.spec(source)) { $0.child($1) } }
        if let name {
            element.name = String(name.prefix(128))
            registers.append(DataFieldsPaths.sourceName(source))
        }
        guard !registers.isEmpty else { return }
        builder.append(Ops.set(WellKnown.settings, registers, values: DataEditing.sourceValues(id: source, element)))
    }
}

/// The API sheet's *Headers* table: replaces the live headers with `headers`, "Change headers".
public struct SetSourceHeaders: Command {
    public var source: OpID
    public var headers: [(name: String, value: String)]
    public var label: String { "Change headers" }

    public init(_ source: OpID, _ headers: [(name: String, value: String)]) {
        self.source = source
        self.headers = headers
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.source(source, in: state)
        let stored = headers.map { header in
            var value = Wiretuner_Doc_V1_HttpHeader()
            value.name = String(header.name.prefix(128))
            value.value = String(header.value.prefix(4096))
            return value
        }
        var http = Wiretuner_Doc_V1_HttpSource()
        http.headers = stored
        try DataEditing.validate(http)
        let path = DataFieldsPaths.spec(source).child(4).child(3)
        let live = state.liveElements(WellKnown.settings, path)
        if !live.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, live.map { path.element($0) })) }
        DataEditing.insertHeaders(stored, at: path, source: source, builder: &builder)
    }
}

/// The API sheet's *Parameters*: replaces the live parameters (name and shared default),
/// "Change parameters".
public struct SetSourceParams: Command {
    public var source: OpID
    public var params: [(name: String, defaultValue: String)]
    public var label: String { "Change parameters" }

    public init(_ source: OpID, _ params: [(name: String, defaultValue: String)]) {
        self.source = source
        self.params = params
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.source(source, in: state)
        let path = DataFieldsPaths.spec(source).child(4).child(8)
        let live = state.liveElements(WellKnown.settings, path)
        if !live.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, live.map { path.element($0) })) }
        DataEditing.insertParams(params.map { param in
            var value = Wiretuner_Doc_V1_HttpParam()
            value.name = String(param.name.prefix(64))
            value.defaultValue = String(param.defaultValue.prefix(1024))
            return value
        }, at: path, source: source, builder: &builder)
    }
}

/// Which source is connected (nil disconnects), "Connect source" / "Disconnect source".
public struct SetActiveSource: Command {
    public var source: OpID?
    public var label: String { source == nil ? "Disconnect source" : "Connect source" }

    public init(_ source: OpID?) {
        self.source = source
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if let source { _ = try DataEditing.source(source, in: state) }
        let values = source.map { id in DataFieldsPaths.values { $0.dataSourceActive = id.elementID } } ?? Wiretuner_Doc_V1_NodeProps()
        builder.append(Ops.set(WellKnown.settings, [DataFieldsPaths.activeSource], values: values))
    }
}

/// Removes a source (its settings stay in the tombstone for *Restore*), "Remove source".
public struct RemoveSource: Command {
    public var source: OpID
    public var label: String { "Remove source" }

    public init(_ source: OpID) {
        self.source = source
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.source(source, in: state)
        builder.append(Ops.elementDelete(WellKnown.settings, [DataFieldsPaths.sources.element(source)]))
    }
}

/// The *Mapping* table: pairs `field` with the column or path `path` in `source` (nil unpairs,
/// so the field reads the column of its own name), "Change mapping".  Earlier entries for the
/// field are removed in the same change.
public struct SetMapping: Command {
    public var source: OpID
    public var field: OpID
    public var path: String?
    public var label: String { "Change mapping" }

    public init(_ source: OpID, field: OpID, path: String?) {
        self.source = source
        self.field = field
        self.path = path
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let info = try DataEditing.source(source, in: state)
        _ = try DataEditing.field(field, in: state)
        if let path, path.count > 512 { throw DataEditError.invalidValue("path") }
        let sequence = DataFieldsPaths.mapping(source)
        let stale = info.mapping.filter { $0.field == field }.map { sequence.element($0.id) }
        if !stale.isEmpty { builder.append(Ops.elementDelete(WellKnown.settings, stale)) }
        guard let path else { return }
        let last = state.store.elementOrder(WellKnown.settings, sequence).last.flatMap { state.position(WellKnown.settings, sequence, $0) }
        let keys = try PathEditing.keys(between: last, and: nil, count: 1)
        var element = Wiretuner_Doc_V1_DataSource()
        var entry = Wiretuner_Doc_V1_FieldMapping()
        entry.field = field.elementID
        entry.path = path
        element.mapping = [entry]
        builder.append(Ops.elementInsert(WellKnown.settings, sequence, positions: keys, values: DataEditing.sourceValues(id: source, element)))
    }
}

/// *Embed Sample*, *Embed All Records*, a pasted table: the source's `sample` (ATOMIC; nil
/// clears it), "Embed sample" / "Remove sample".
public struct SetSample: Command {
    public var source: OpID
    public var sample: Wiretuner_Doc_V1_EmbeddedRecords?
    public var label: String { sample == nil ? "Remove sample" : "Embed sample" }

    public init(_ source: OpID, _ sample: Wiretuner_Doc_V1_EmbeddedRecords?) {
        self.source = source
        self.sample = sample
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.source(source, in: state)
        if let sample, sample.blobSha256.count != 32 || !["text/csv", "application/json"].contains(sample.mediaType) {
            throw DataEditError.invalidValue("sample")
        }
        var element = Wiretuner_Doc_V1_DataSource()
        if let sample { element.sample = sample }
        builder.append(Ops.set(WellKnown.settings, [DataFieldsPaths.sample(source)], values: DataEditing.sourceValues(id: source, element)))
    }
}

// MARK: - Bindings

/// The Object panel's *Data* section: binds each node to `field` as `kind` (ATOMIC: field and
/// kind together), "Bind to field".  An image binding takes image nodes only; a text binding
/// text and barcode nodes; visibility and link any object.
public struct BindToField: Command {
    public var nodes: [OpID]
    public var field: OpID
    public var kind: DataBindingKind
    public var label: String { "Bind to field" }

    public init(_ nodes: [OpID], field: OpID, kind: DataBindingKind) {
        self.nodes = nodes
        self.field = field
        self.kind = kind
    }

    /// Whether a node of stored kind `nodeKind` can take a binding of `kind`.
    public static func allows(_ kind: DataBindingKind, nodeKind: UInt32) -> Bool {
        switch kind {
        case .image: nodeKind == ImageKind.kind
        case .text: nodeKind == TextFields.kind || nodeKind == NodeKind.barcode.rawValue
        case .visibility, .link: DataBindings.values(kind: nodeKind, nil) != nil && nodeKind != NodeKind.layer.rawValue
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try DataEditing.field(field, in: state)
        var binding = Wiretuner_Doc_V1_DataBinding()
        binding.field = field.elementID
        binding.kind = kind.stored
        for node in nodes {
            let nodeKind = state.store.kind(node)
            guard state.isLive(node), Self.allows(kind, nodeKind: nodeKind), let values = DataBindings.values(kind: nodeKind, binding) else {
                throw DataEditError.bindingNotAllowed(node)
            }
            builder.append(Ops.set(node, [DataBindings.path(kind: nodeKind)], values: values))
        }
    }
}

/// *Data* › *None*: clears the binding of each bound node, "Unbind".
public struct Unbind: Command {
    public var nodes: [OpID]
    public var label: String { "Unbind" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in nodes where state.isLive(node) && DataBindings.stored(state.props(node)) != nil {
            let kind = state.store.kind(node)
            if let values = DataBindings.values(kind: kind, nil) {
                builder.append(Ops.set(node, [DataBindings.path(kind: kind)], values: values))
            }
        }
    }
}
