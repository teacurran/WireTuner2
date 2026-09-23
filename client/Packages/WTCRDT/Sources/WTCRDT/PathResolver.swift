import WTProto

/// Walks a field path with the merge table (docs/spec/crdt-model.adoc, "Field paths and
/// registers") and turns it into what an op writes:
///
/// * a path ending at an ATOMIC field is one register; its value is that field's records in
///   `values`, or unset when `values` holds none;
/// * a path ending at a STRUCT field, or at a sequence element, stands for every register
///   beneath it in the table, each written from `values` (absent leaves written unset); an
///   element's `id` (field 1) is never a register;
/// * beneath a MERGE_VARIANT message present in `values`, only the case messages present are
///   written, so a kind switch never clears another case; a variant being cleared clears every
///   case;
/// * a SEQUENCE field is entered only through an element segment naming an element that exists,
///   and a TEXT field only through one naming a newline character (its paragraph registers,
///   CRDT-006); elements, characters, marks and a SET field's members merge by their own ops;
/// * anything else -- an unknown field, a path running past an ATOMIC or SET field, an element
///   segment anywhere but directly after a SEQUENCE field -- makes the path a no-op.
///
/// Element segments are transparent in `values`: the sparse message holds, at a SEQUENCE field,
/// only the element the path names, and at a TEXT field a `RichText` whose `chars` hold only the
/// character the path names.
struct PathResolver: Sendable {
    /// One register write: where, and the value (nil = unset).
    struct Assignment: Equatable {
        let path: RegisterPath
        let value: [UInt8]?
    }

    /// Where a path ends.
    enum Target {
        /// At a field: the path, the field's row, and the navigated `values` message holding it.
        case field(RegisterPath, Schema.FieldPolicy, WireMessage?)
        /// At an existing element: the path, the element message type, the navigated `values`
        /// message of the element, and the highest field number the engine owns in it (1 for a
        /// sequence element, its `id`; 5 for a character: id, codepoint, deleted, origins).
        case element(RegisterPath, String, WireMessage?, reserved: Int)
    }

    /// Engine-owned fields of a sequence element: its `id`.
    static let elementReserved = 1
    /// Engine-owned fields of a character (`TextChar`): id, codepoint, deleted, left and right
    /// origin; the paragraph (field 6) and anything after are registers.
    static let charReserved = 5
    /// `RichText.chars`: the field of a TEXT field's message holding its characters.
    static let charsField: UInt32 = 1

    let schema: Schema

    /// Where `path` leads on a node of `kind`, or nil when it is malformed for it.
    /// `elementExists` says whether the element at a path (ending with an element segment) exists:
    /// a sequence element, or a newline character of a TEXT field.
    func walk(
        kind: UInt32, path: Wiretuner_Doc_V1_FieldPath, values: WireMessage?,
        elementExists: (RegisterPath) -> Bool
    ) -> Target? {
        guard let full = RegisterPath(path), full.segments.first == .field(kind) else { return nil }
        var message = Schema.root
        var current = values
        var reserved = 0
        var container: Schema.FieldPolicy?
        for index in full.segments.indices {
            let at = RegisterPath(segments: Array(full.segments[...index]))
            let last = index == full.segments.count - 1
            switch full.segments[index] {
            case .field(let number):
                guard container == nil, let row = schema.field(message, Int(number)),
                      Int(number) > reserved else { return nil }
                if last {
                    return .field(at, row, current)
                }
                guard let typeName = row.typeName, !row.repeated || row.policy == .sequence else { return nil }
                switch row.policy {
                case .structure, .variant:
                    message = typeName
                    reserved = 0
                case .sequence, .text:
                    container = row
                default:
                    return nil
                }
                current = current?.message(number)
            case .element:
                guard let row = container, elementExists(at) else { return nil }
                container = nil
                if row.policy == .text {
                    guard let char = schema.field(row.typeName!, Int(Self.charsField))?.typeName else { return nil }
                    message = char
                    reserved = Self.charReserved
                    current = current?.message(Self.charsField)
                } else {
                    message = row.typeName!
                    reserved = Self.elementReserved
                }
                if last {
                    return .element(at, message, current, reserved: reserved)
                }
            }
        }
        return nil
    }

    /// The register writes of a `SetFields` path on a node of `kind`, or nil when the path does
    /// not name registers (a deterministic no-op, "Totality").
    func resolve(
        kind: UInt32, path: Wiretuner_Doc_V1_FieldPath, values: WireMessage,
        elementExists: (RegisterPath) -> Bool
    ) -> [Assignment]? {
        var out: [Assignment] = []
        var branch: Set<String> = []
        switch walk(kind: kind, path: path, values: values, elementExists: elementExists) {
        case .field(let at, let row, let container)?:
            let number = row.fieldNumber
            if row.policy == .atomic {
                return [Assignment(path: at, value: container?.records(UInt32(number)))]
            }
            guard Self.isStruct(row) else { return nil }
            expand(row.typeName!, at, container?.message(UInt32(number)), absentAsUnset: true,
                   reserved: 0, &branch, &out)
        case .element(let at, let message, let value, let reserved)?:
            expand(message, at, value, absentAsUnset: true, reserved: reserved, &branch, &out)
        case nil:
            return nil
        }
        return out
    }

    /// The registers a `CreateNode`'s props set: every leaf present, nothing else.
    func initial(kind: UInt32, props: WireMessage) -> [Assignment] {
        let row = schema.field(Schema.root, Int(kind))!
        return initial(row.typeName!, RegisterPath([kind]), props.message(kind), reserved: 0)
    }

    /// The registers a new element's values set: every leaf present except its id.
    func initial(element message: String, at path: RegisterPath, values: WireMessage?) -> [Assignment] {
        initial(message, path, values, reserved: Self.elementReserved)
    }

    private func initial(_ message: String, _ path: RegisterPath, _ value: WireMessage?, reserved: Int) -> [Assignment] {
        var out: [Assignment] = []
        var branch: Set<String> = []
        expand(message, path, value, absentAsUnset: false, reserved: reserved, &branch, &out)
        return out
    }

    // Singular STRUCT/VARIANT message fields are walked through.
    private static func isStruct(_ row: Schema.FieldPolicy) -> Bool {
        (row.policy == .structure || row.policy == .variant) && !row.repeated && row.typeName != nil
    }

    /// Appends the registers beneath `message` at `prefix`.  With `absentAsUnset` every leaf is
    /// written (a STRUCT write or clear); without it only leaves present in `value` are (a
    /// CreateNode or an inserted element).  A message already on the current branch is not entered
    /// again, so a recursive schema expands finitely and identically in both engines.
    private func expand(
        _ message: String, _ prefix: RegisterPath, _ value: WireMessage?, absentAsUnset: Bool,
        reserved: Int, _ branch: inout Set<String>, _ out: inout [Assignment]
    ) {
        guard absentAsUnset || value != nil, branch.insert(message).inserted else { return }
        let variant = schema.variant(message)
        for row in schema.fields(message) where row.fieldNumber > reserved {
            let number = UInt32(row.fieldNumber)
            let present = value?.has(number) ?? false
            let skippedCase = variant != nil && value != nil && !present
                && variant!.caseFields.contains(row.fieldNumber)
            guard row.policy == .atomic || Self.isStruct(row), !skippedCase, absentAsUnset || present else { continue }
            let path = prefix.child(number)
            if row.policy == .atomic {
                out.append(Assignment(path: path, value: value?.records(number)))
            } else {
                expand(row.typeName!, path, value?.message(number), absentAsUnset: absentAsUnset,
                       reserved: 0, &branch, &out)
            }
        }
        branch.remove(message)
    }
}
