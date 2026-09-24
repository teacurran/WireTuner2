import Foundation
import WTCRDT
import WTProto

// DATA-003: the data-merge block of the settings node read as the Data panel, the record
// resolver and the merge see it (automation/data-merge.adoc, "Data model", "Merge semantics").
// Everything here is read-time: duplicate names, dangling mappings, bindings whose field is gone
// or of the wrong type are interpreted, never repaired.

/// Register paths of the data block of `SettingsProps` (80-83) and of the elements under it.
public enum DataFieldsPaths {
    /// `SettingsProps.data_fields` (SEQUENCE of `DataField`).
    public static let fields = RegisterPath([SettingsFields.kind, 80])
    /// `SettingsProps.data_sources` (SEQUENCE of `DataSource`).
    public static let sources = RegisterPath([SettingsFields.kind, 81])
    /// `SettingsProps.data_source_active` (ATOMIC `ElementId`).
    public static let activeSource = RegisterPath([SettingsFields.kind, 82])

    /// `DataField.name` of field element `field`.
    public static func name(_ field: OpID) -> RegisterPath { fields.element(field).child(2) }
    /// `DataField.type`.
    public static func type(_ field: OpID) -> RegisterPath { fields.element(field).child(3) }
    /// `DataField.format.pattern`.
    public static func formatPattern(_ field: OpID) -> RegisterPath { fields.element(field).child(4).child(1) }
    /// `DataField.format.locale`.
    public static func formatLocale(_ field: OpID) -> RegisterPath { fields.element(field).child(4).child(2) }
    /// `DataField.transform` (a `NodeRef`, written whole as references are).
    public static func transform(_ field: OpID) -> RegisterPath { fields.element(field).child(5) }

    /// `DataSource.name` of source element `source`.
    public static func sourceName(_ source: OpID) -> RegisterPath { sources.element(source).child(2) }
    /// `DataSource.spec` (the VARIANT).
    public static func spec(_ source: OpID) -> RegisterPath { sources.element(source).child(3) }
    /// `DataSource.spec.kind` (the variant's case).
    public static func kind(_ source: OpID) -> RegisterPath { spec(source).child(1) }
    /// `DataSource.mapping` (SEQUENCE of `FieldMapping`).
    public static func mapping(_ source: OpID) -> RegisterPath { sources.element(source).child(4) }
    /// `DataSource.sample` (ATOMIC `EmbeddedRecords`).
    public static func sample(_ source: OpID) -> RegisterPath { sources.element(source).child(5) }

    /// A sparse `NodeProps` holding the settings values `build` sets.
    public static func values(_ build: (inout Wiretuner_Doc_V1_SettingsProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        SettingsFields.values(build)
    }

    /// The longest field name, and its pattern (`DataField.name`).
    public static let maxName = 64

    /// Whether `name` is a valid field name: `[A-Za-z_][A-Za-z0-9_]*`, at most 64 characters.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.unicodeScalars.count <= maxName else { return false }
        func letter(_ scalar: Unicode.Scalar) -> Bool { scalar.isASCII && (CharacterSet.letters.contains(scalar) || scalar == "_") }
        return letter(first) && name.unicodeScalars.allSatisfy { letter($0) || ($0.isASCII && CharacterSet.decimalDigits.contains($0)) }
    }
}

/// A field's value type as the panel and the resolver read it (unspecified reads as text).
public enum DataFieldKind: String, Hashable, Sendable, CaseIterable {
    case text, number, date, boolean, image, link

    public init(_ stored: Wiretuner_Doc_V1_DataFieldType) {
        switch stored {
        case .number: self = .number
        case .date: self = .date
        case .boolean: self = .boolean
        case .image: self = .image
        case .link: self = .link
        default: self = .text
        }
    }

    public var stored: Wiretuner_Doc_V1_DataFieldType {
        switch self {
        case .text: .text
        case .number: .number
        case .date: .date
        case .boolean: .boolean
        case .image: .image
        case .link: .link
        }
    }
}

/// One live field as read.
public struct DataFieldInfo: Identifiable, Hashable, Sendable {
    public let id: OpID
    /// The stored name ("" when never written).
    public let name: String
    /// What the panel shows: the stored name, with ` (2)`, ` (3)` ... on the later of equal
    /// names (the smaller element id keeps the plain name).
    public let displayName: String
    public let kind: DataFieldKind
    public let pattern: String
    public let locale: String
    /// The `script` node exporting `transform`; nil when unset or dangling.
    public let transform: OpID?
}

/// One mapping entry whose field is live.
public struct DataMappingEntry: Identifiable, Hashable, Sendable {
    public let id: OpID
    public let field: OpID
    public let path: String
}

/// One live source as read.
public struct DataSourceInfo: Identifiable, Hashable, Sendable {
    public let id: OpID
    public let name: String
    public let kind: Wiretuner_Doc_V1_DataSourceKind
    /// The whole variant, every kind's settings kept.
    public let spec: Wiretuner_Doc_V1_DataSourceSpec
    /// The mapping entries whose field is a live field (the others are ignored on read).
    public let mapping: [DataMappingEntry]
    /// The embedded records, when any were written.
    public let sample: Wiretuner_Doc_V1_EmbeddedRecords?

    /// The HTTP settings with the read-time defaults applied: `timeout_s` 0 reads 30,
    /// `first_page` 0 reads 1, `max_pages` 0 reads 1000, unspecified pagination reads NONE and an
    /// unspecified method GET.
    public var http: Wiretuner_Doc_V1_HttpSource {
        var http = spec.http
        if http.timeoutS == 0 { http.timeoutS = 30 }
        if http.pagination.firstPage == 0 { http.pagination.firstPage = 1 }
        if http.pagination.maxPages == 0 { http.pagination.maxPages = 1000 }
        if http.pagination.mode == .unspecified { http.pagination.mode = .none }
        if http.method == .unspecified { http.method = .get }
        return http
    }

    /// Whether an HTTP source's URL is usable: `https`, non-empty.  Anything else is shown as an
    /// error and the server refuses it.
    public var hasValidURL: Bool {
        let url = spec.http.url.lowercased()
        return url.hasPrefix("https://") && url.count > "https://".count
    }

    /// The `script` node a script source names (nil when unset or dangling: "script missing").
    public let script: OpID?
}

/// How a binding applies, as read.
public enum DataBindingKind: String, Hashable, Sendable, CaseIterable {
    case image, visibility, link, text

    public init?(_ stored: Wiretuner_Doc_V1_BindingKind) {
        switch stored {
        case .image: self = .image
        case .visibility: self = .visibility
        case .link: self = .link
        case .text: self = .text
        default: return nil
        }
    }

    public var stored: Wiretuner_Doc_V1_BindingKind {
        switch self {
        case .image: .image
        case .visibility: .visibility
        case .link: .link
        case .text: .text
        }
    }

    /// Whether a field of `kind` suits this binding (data-merge.adoc, "Binding an object"): IMAGE
    /// for image, BOOLEAN for visibility, LINK for link, anything for text.
    public func accepts(_ kind: DataFieldKind) -> Bool {
        switch self {
        case .image: kind == .image
        case .visibility: kind == .boolean
        case .link: kind == .link
        case .text: true
        }
    }
}

/// A node's binding as read: the field it names, how it applies, and whether it resolves.  A
/// binding whose field is dangling or of a type the kind does not accept is `missing` and is
/// treated as unbound (the *missing* badge).
public struct DataBindingInfo: Hashable, Sendable {
    public let node: OpID
    /// The stored field id (nil when the stored id is zero).
    public let field: OpID?
    public let kind: DataBindingKind
    /// The field, when live and suited to the kind.
    public let resolved: DataFieldInfo?

    public var isMissing: Bool { resolved == nil }
}

/// A placeholder span in a text node: the live range its `field` mark covers and the field.
public struct DataPlaceholder: Hashable, Sendable {
    public let node: OpID
    /// Live offsets (Unicode scalars).
    public let range: Range<Int>
    /// The stored field id; nil for the zero id (a typed name that matched no field).
    public let field: OpID?
    /// The field, when live.
    public let resolved: DataFieldInfo?

    /// What the canvas shows without preview: `{{name}}` of the live field, else `{{missing}}`.
    public var label: String { resolved.map { "{{\($0.displayName)}}" } ?? "{{missing}}" }
}

/// The document's data-merge block as read (`SettingsProps` 80-82).
public struct DataModel: Sendable {
    /// Live fields in sequence order.
    public let fields: [DataFieldInfo]
    /// Live sources in sequence order.
    public let sources: [DataSourceInfo]
    /// The connected source: nil when unset, dangling or deleted.
    public let activeSource: DataSourceInfo?
    private let byID: [OpID: DataFieldInfo]
    private let byName: [String: DataFieldInfo]

    public init(_ state: EngineState) {
        let settings = state.props(WellKnown.settings).settings
        // Duplicate names: the smaller element id keeps the plain name.
        let ordered = settings.dataFields.compactMap { field -> (OpID, Wiretuner_Doc_V1_DataField)? in
            OpID(element: field.id).map { ($0, field) }
        }
        var suffixes: [OpID: Int] = [:]
        var groups: [String: [OpID]] = [:]
        for (id, field) in ordered where !field.name.isEmpty {
            groups[field.name.lowercased(), default: []].append(id)
        }
        for ids in groups.values where ids.count > 1 {
            for (index, id) in ids.sorted().enumerated() where index > 0 {
                suffixes[id] = index + 1
            }
        }
        fields = ordered.map { id, field in
            let transform = field.hasTransform ? OpID(field.transform.id) : nil
            return DataFieldInfo(id: id, name: field.name, displayName: suffixes[id].map { "\(field.name) (\($0))" } ?? field.name,
                                 kind: DataFieldKind(field.type), pattern: field.format.pattern, locale: field.format.locale,
                                 transform: transform.flatMap { Self.isScript($0, in: state) ? $0 : nil })
        }
        let byID = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
        self.byID = byID
        var byName: [String: DataFieldInfo] = [:]
        for field in fields.sorted(by: { $0.id < $1.id }) where !field.name.isEmpty && byName[field.name.lowercased()] == nil {
            byName[field.name.lowercased()] = field
        }
        self.byName = byName
        let sources = settings.dataSources.compactMap { source -> DataSourceInfo? in
            guard let id = OpID(element: source.id) else { return nil }
            let mapping = source.mapping.compactMap { entry -> DataMappingEntry? in
                guard let entryID = OpID(element: entry.id), let field = OpID(element: entry.field), byID[field] != nil else { return nil }
                return DataMappingEntry(id: entryID, field: field, path: entry.path)
            }
            let script = source.spec.script.hasScript ? OpID(source.spec.script.script.id) : nil
            return DataSourceInfo(id: id, name: source.name, kind: source.spec.kind, spec: source.spec, mapping: mapping,
                                  sample: source.hasSample ? source.sample : nil,
                                  script: script.flatMap { Self.isScript($0, in: state) ? $0 : nil })
        }
        self.sources = sources
        let active = settings.hasDataSourceActive ? OpID(element: settings.dataSourceActive) : nil
        activeSource = active.flatMap { id in sources.first { $0.id == id } }
    }

    /// Whether `node` is a live `script` node (kind 241).
    static func isScript(_ node: OpID, in state: EngineState) -> Bool {
        state.isLive(node) && state.store.kind(node) == ScriptFields.kind
    }

    /// The live field `id`.
    public func field(_ id: OpID?) -> DataFieldInfo? {
        id.flatMap { byID[$0] }
    }

    /// The live field named `name` (case-insensitive; of equal names, the smaller id).
    public func field(named name: String) -> DataFieldInfo? {
        byName[name.lowercased()]
    }

    /// The source `id`, when live.
    public func source(_ id: OpID) -> DataSourceInfo? {
        sources.first { $0.id == id }
    }

    /// The column or path `field` reads in `source`: the last live mapping entry for it, else the
    /// field's own name.
    public func path(of field: DataFieldInfo, in source: DataSourceInfo?) -> String {
        source?.mapping.last { $0.field == field.id }?.path ?? field.name
    }

    // MARK: Bindings and placeholders

    /// The binding `node` holds, or nil when it holds none.
    public func binding(of node: OpID, in state: EngineState) -> DataBindingInfo? {
        guard let binding = DataBindings.stored(state.props(node)), let kind = DataBindingKind(binding.kind) else { return nil }
        let id = OpID(element: binding.field)
        let resolved = field(id).flatMap { kind.accepts($0.kind) ? $0 : nil }
        return DataBindingInfo(node: node, field: id, kind: kind, resolved: resolved)
    }

    /// The placeholder spans of text node `text`, in order.  Adjacent runs marked with the same
    /// field are one span.
    public func placeholders(in text: TextNode) -> [DataPlaceholder] {
        var result: [DataPlaceholder] = []
        var current: (range: Range<Int>, stored: Wiretuner_Doc_V1_ElementId)?
        func flush() {
            guard let span = current else { return }
            let id = OpID(element: span.stored).flatMap { $0 == DataPlaceholders.unknownField ? nil : $0 }
            result.append(DataPlaceholder(node: text.id, range: span.range, field: id, resolved: field(id)))
            current = nil
        }
        for run in text.runs {
            let stored = run.values.lazy.compactMap { value -> Wiretuner_Doc_V1_ElementId? in
                if case .field(let id)? = value.value { return id }
                return nil
            }.first
            guard let stored, run.range.count > 0 else {
                flush()
                continue
            }
            if let span = current, span.stored == stored, span.range.upperBound == run.range.lowerBound {
                current = (span.range.lowerBound..<run.range.upperBound, stored)
            } else {
                flush()
                current = (run.range, stored)
            }
        }
        flush()
        return result
    }

    /// Every use of every field in the live document: placeholder spans and bindings, keyed by
    /// field id (dangling ids included, so a deleted field's uses can be counted).
    public func uses(in state: EngineState) -> [OpID: Int] {
        var counts: [OpID: Int] = [:]
        for node in DataBindings.liveNodes(in: state) {
            if let binding = DataBindings.stored(state.props(node)), DataBindingKind(binding.kind) != nil, let id = OpID(element: binding.field) {
                counts[id, default: 0] += 1
            }
            if let text = TextNode(node, in: state) {
                for placeholder in placeholders(in: text) {
                    if let id = placeholder.field { counts[id, default: 0] += 1 }
                }
            }
        }
        return counts
    }
}

/// Reading `CommonProps.data_binding` on any kind, image and barcode included.
public enum DataBindings {
    /// The register path of `CommonProps.data_binding` (field 12, ATOMIC) on kind `kind`.
    public static func path(kind: UInt32) -> RegisterPath { RegisterPath([kind, 1, 12]) }

    /// The stored binding of `props` (nil when unset or the kind has no common props).
    public static func stored(_ props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_DataBinding? {
        let common: Wiretuner_Doc_V1_CommonProps?
        if case .image(let image)? = props.kind { common = image.common } else { common = NodeValues.common(props) }
        guard let common, common.hasDataBinding else { return nil }
        return common.dataBinding
    }

    /// A sparse `NodeProps` of `kind` carrying `binding` in its common props (nil `binding`
    /// writes the register unset).  Nil for a kind that has no common props WTModel writes.
    static func values(kind: UInt32, _ binding: Wiretuner_Doc_V1_DataBinding?) -> Wiretuner_Doc_V1_NodeProps? {
        var props = Wiretuner_Doc_V1_NodeProps()
        if kind == ImageKind.kind {
            props.image = .init()
            if let binding { props.image.common.dataBinding = binding }
            return props
        }
        guard let known = NodeKind(rawValue: kind) else { return nil }
        return NodeValues.common(kind: known) { common in
            if let binding { common.dataBinding = binding }
        }
    }

    /// Every live node under the layers and the symbols, depth first (deleted subtrees skipped).
    static func liveNodes(in state: EngineState) -> [OpID] {
        var result: [OpID] = []
        func visit(_ node: OpID) {
            for child in state.liveChildren(node) {
                result.append(child)
                visit(child)
            }
        }
        visit(WellKnown.layers)
        visit(WellKnown.symbols)
        return result
    }
}

/// The `image` node kind (`NodeProps.image` = 170), which WTModel only reads for bindings.
public enum ImageKind {
    public static let kind: UInt32 = 170
}
