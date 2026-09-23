import WTCRDTSchema

/// The merge table as the engine reads it: the generated `WTMergeTable` (or another table of the
/// same shape) with the model's reference rule applied.  It is the only feature-specific input
/// the engine has (docs/spec/crdt-model.adoc, "Merge policies").
///
/// The reference rule: a `NodeRef` field is one ATOMIC register ("References" under "Merge
/// rules") whatever policy the table gives it, so an id's counter and replica can never come
/// from two different writes.
public struct Schema: Sendable {
    public typealias Policy = WTMergeTable.Policy
    public typealias FieldPolicy = WTMergeTable.FieldPolicy
    public typealias VariantPolicy = WTMergeTable.VariantPolicy

    /// The message every field path starts from.
    public static let root = "wiretuner.doc.v1.NodeProps"
    /// The oneof of `root` whose set case is a node's kind.
    public static let kindOneof = "kind"

    static let nodeRef = "wiretuner.doc.v1.NodeRef"

    private let messages: [String: [Int: FieldPolicy]]
    private let variants: [String: VariantPolicy]
    /// The field numbers of `NodeProps.kind`: the node kinds this table knows.
    public let kinds: Set<UInt32>

    private init(messages: [String: [Int: FieldPolicy]], variants: [String: VariantPolicy]) {
        self.messages = messages
        self.variants = variants
        let root = messages[Self.root] ?? [:]
        kinds = Set(root.values.filter { $0.oneof == Self.kindOneof }.map { UInt32($0.fieldNumber) })
    }

    /// The generated table (protoc-gen-wtcrdt over proto/).
    public static let generated = Schema(messages: WTMergeTable.messages, variants: WTMergeTable.variants)

    /// A table of the generated shape, with the reference rule applied.
    public init(messages: [String: WTMergeTable.MessagePolicy], variants: [String: VariantPolicy]) {
        self.init(
            messages: messages.mapValues { $0.fields.mapValues(Self.referenceRule) },
            variants: variants
        )
    }

    private static func referenceRule(_ row: FieldPolicy) -> FieldPolicy {
        let singularRef = row.typeName == nodeRef && !row.repeated
        return singularRef && row.policy == .structure ? with(row, policy: .atomic) : row
    }

    private static func with(_ row: FieldPolicy, policy: Policy) -> FieldPolicy {
        FieldPolicy(
            fieldNumber: row.fieldNumber, name: row.name, policy: policy, onDangling: row.onDangling,
            localOnly: row.localOnly, type: row.type, repeated: row.repeated, typeName: row.typeName,
            elementMessage: row.elementMessage, oneof: row.oneof
        )
    }

    /// Why an override cannot apply.
    public struct OverrideError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// This table with one field's policy replaced.  For tests and conformance vectors that
    /// exercise a merge rule before any schema field uses it; the result is not re-checked the way
    /// protoc-gen-wtcrdt checks the schema.
    public func with(_ message: String, field: Int, policy: Policy) throws(OverrideError) -> Schema {
        guard let row = self.field(message, field) else {
            throw OverrideError(description: "no field \(message).\(field) in the merge table")
        }
        var rows = messages
        rows[message]?[field] = Self.with(row, policy: policy)
        return Schema(messages: rows, variants: variants)
    }

    /// This table with `message` declared a MERGE_VARIANT message (see `with(_:field:policy:)`).
    public func withVariant(_ message: String, kindField: Int, caseFields: [Int]) -> Schema {
        var declared = variants
        declared[message] = VariantPolicy(kindField: kindField, caseFields: caseFields)
        return Schema(messages: messages, variants: declared)
    }

    /// The row for one field, or nil when the message or the field is unknown.
    public func field(_ message: String, _ number: Int) -> FieldPolicy? {
        messages[message]?[number]
    }

    /// The rows of one message in field-number order (empty for an unknown message).
    public func fields(_ message: String) -> [FieldPolicy] {
        (messages[message] ?? [:]).values.sorted { $0.fieldNumber < $1.fieldNumber }
    }

    /// The variant declaration of `message`, or nil when it is not a variant.
    public func variant(_ message: String) -> VariantPolicy? {
        variants[message]
    }
}
