import WTProto

/// `local_only` fields (crdt-model.adoc, "Local-only fields"): view state and per-Mac values a
/// document keeps for convenience -- a security-scoped bookmark, an output folder, zoom -- that
/// never leave the device.  A register is local-only when the walk to it crosses a field whose
/// merge-table row says `local_only` (the field itself or any STRUCT, VARIANT or SEQUENCE field
/// above it).
///
/// * The engines never merge them from a change: a remote change's write to a local-only register
///   is a deterministic no-op, in WTCRDT and wt-crdt alike (`registers/local-only-*` vectors).
/// * WTCRDT writes them while applying a local change (`EngineState.applyLocal`) into the
///   replica's local registers, which reads see but the state hash, snapshots and garbage
///   collection do not (`NodeStore.localRegisters`).
/// * `strip` takes them out of a change before it enters the outbox (WTModel's `DocumentCore`)
///   and on the server before a pushed change is logged, both engines byte for byte alike
///   (`registers/local-only-strip` vectors): nothing local-only is ever on the wire.
public enum LocalOnly {
    /// Whether the field rows `path` crosses include a `local_only` one, the field it ends at
    /// included.  The walk starts at `NodeProps` and follows the table: STRUCT and VARIANT fields
    /// into their message, SEQUENCE fields (after the element segment) into the element message,
    /// TEXT fields into their characters; it stops, answering false, at an unknown field or one
    /// nothing is beneath (ATOMIC, SET).  Element segments carry no row and need no state.
    public static func enters(_ schema: Schema, _ path: RegisterPath) -> Bool {
        var message: String? = Schema.root
        for segment in path.segments {
            guard case .field(let number) = segment else { continue }
            guard let current = message, let row = schema.field(current, Int(number)) else { return false }
            if row.localOnly { return true }
            message = inner(schema, row)
        }
        return false
    }

    /// The message a walk continues in beneath `row`, or nil when nothing is beneath it.
    private static func inner(_ schema: Schema, _ row: Schema.FieldPolicy) -> String? {
        guard let typeName = row.typeName else { return nil }
        switch row.policy {
        case .structure, .variant, .sequence: return typeName
        case .text: return schema.field(typeName, Int(PathResolver.charsField))?.typeName
        default: return nil
        }
    }

    /// `change` without anything local-only: a `SetFields` loses the paths that enter a
    /// `local_only` field (and becomes a `Noop`, keeping its counter, when none is left), and the
    /// `NodeProps` of every op that carries one (`CreateNode.props`, `SetFields.values`,
    /// `ElementInsert.values`, `SetAdd.values`, `SetRemove.values`) loses its local-only fields,
    /// however deep (`strip(props:)`).  Every other op, and a change with nothing local-only, is
    /// returned exactly as it came.
    public static func strip(_ change: Wiretuner_Doc_V1_Change, schema: Schema) -> Wiretuner_Doc_V1_Change {
        var out = change
        var changed = false
        for index in change.ops.indices {
            if let op = strip(change.ops[index], schema) {
                out.ops[index] = op
                changed = true
            }
        }
        return changed ? out : change
    }

    /// Whether `change` carries anything `strip` would take out.
    public static func carries(_ change: Wiretuner_Doc_V1_Change, schema: Schema) -> Bool {
        change.ops.contains { strip($0, schema) != nil }
    }

    // The op without its local-only content, or nil when it has none.
    private static func strip(_ op: Wiretuner_Doc_V1_Op, _ schema: Schema) -> Wiretuner_Doc_V1_Op? {
        var out = op
        switch op.op {
        case .create(let create):
            guard let props = strip(props: create.props, schema) else { return nil }
            out.create.props = props
        case .set(let set):
            let kept = set.paths.filter { path in RegisterPath(path).map { !enters(schema, $0) } ?? true }
            let props = strip(props: set.values, schema)
            guard kept.count != set.paths.count || props != nil else { return nil }
            if kept.isEmpty {
                var noop = Wiretuner_Doc_V1_Op()
                noop.noop = Wiretuner_Doc_V1_Noop()
                return noop
            }
            out.set.paths = kept
            if let props { out.set.values = props }
        case .elementInsert(let insert):
            guard let props = strip(props: insert.values, schema) else { return nil }
            out.elementInsert.values = props
        case .setAdd(let add):
            guard let props = strip(props: add.values, schema) else { return nil }
            out.setAdd.values = props
        case .setRemove(let remove):
            guard let props = strip(props: remove.values, schema) else { return nil }
            out.setRemove.values = props
        default:
            return nil
        }
        return out
    }

    // `props` without its local-only fields, or nil when it has none (or does not parse).
    private static func strip(props: Wiretuner_Doc_V1_NodeProps, _ schema: Schema) -> Wiretuner_Doc_V1_NodeProps? {
        guard schema.localOnlyReach.contains(Schema.root), let bytes: [UInt8] = try? props.serializedBytes(),
              let stripped = strip(props: bytes, schema: schema) else { return nil }
        return try? Wiretuner_Doc_V1_NodeProps(serializedBytes: stripped)
    }

    /// An encoded `NodeProps` without its local-only fields, or nil when it has none or is not
    /// well-formed (the engines ignore such values whole).  Only messages that can reach a
    /// `local_only` field are looked into (`Schema.localOnlyReach`).  The walk follows the table from
    /// `NodeProps`: a record whose row is `local_only` is dropped; a LEN record of a STRUCT,
    /// VARIANT or SEQUENCE field is stripped in its message (a SEQUENCE element's `id` untouched),
    /// and of a TEXT field in each of its characters (the engine's fields 1-5 untouched); every
    /// other record -- unknown fields, ATOMIC values, set members -- is kept byte for byte.  A
    /// record that changed is written again as tag, length and payload; the rest are copied as
    /// they came, so both engines produce the same bytes.
    public static func strip(props bytes: [UInt8], schema: Schema) -> [UInt8]? {
        strip(Schema.root, bytes[...], reserved: 0, schema)
    }

    private static func strip(_ message: String, _ bytes: ArraySlice<UInt8>, reserved: Int, _ schema: Schema) -> [UInt8]? {
        guard schema.localOnlyReach.contains(message), let parsed = WireMessage.parse(Array(bytes)) else { return nil }
        var out = WireWriter()
        var changed = false
        for record in parsed.allRecords {
            guard Int(record.number) > reserved, let row = schema.field(message, Int(record.number)) else {
                out.raw(Array(record.record))
                continue
            }
            if row.localOnly {
                changed = true
                continue
            }
            var inner: [UInt8]?
            if record.wireType == WireMessage.len, let typeName = row.typeName {
                switch row.policy {
                case .structure, .variant:
                    inner = strip(typeName, record.payload, reserved: 0, schema)
                case .sequence:
                    inner = strip(typeName, record.payload, reserved: PathResolver.elementReserved, schema)
                case .text:
                    inner = stripText(typeName, record.payload, schema)
                default:
                    break
                }
            }
            if let inner {
                out.lenField(record.number, inner)
                changed = true
            } else {
                out.raw(Array(record.record))
            }
        }
        return changed ? out.bytes : nil
    }

    // A TEXT field's message (`RichText`): each character (`chars`, field 1) stripped beyond the
    // engine's fields; marks and anything else kept.
    private static func stripText(_ message: String, _ bytes: ArraySlice<UInt8>, _ schema: Schema) -> [UInt8]? {
        guard let char = schema.field(message, Int(PathResolver.charsField))?.typeName, schema.localOnlyReach.contains(char),
              let parsed = WireMessage.parse(Array(bytes)) else { return nil }
        var out = WireWriter()
        var changed = false
        for record in parsed.allRecords {
            if record.number == PathResolver.charsField, record.wireType == WireMessage.len,
               let inner = strip(char, record.payload, reserved: PathResolver.charReserved, schema) {
                out.lenField(record.number, inner)
                changed = true
            } else {
                out.raw(Array(record.record))
            }
        }
        return changed ? out.bytes : nil
    }
}
