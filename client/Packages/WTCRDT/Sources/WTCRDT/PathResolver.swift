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
///   and its elements, a SET field's members and a TEXT field merge by their own ops;
/// * anything else -- an unknown field, a path running past an ATOMIC or SET field, an element
///   segment anywhere but directly after a SEQUENCE field -- makes the path a no-op.
///
/// Element segments are transparent in `values`: the sparse message holds, at a SEQUENCE field,
/// only the element the path names.
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
        /// At an existing sequence element: the path, the element message type, and the navigated
        /// `values` message of the element.
        case element(RegisterPath, String, WireMessage?)
    }

    let schema: Schema

    /// Where `path` leads on a node of `kind`, or nil when it is malformed for it.
    /// `elementExists` says whether the element at a path (ending with an element segment) exists.
    func walk(
        kind: UInt32, path: Wiretuner_Doc_V1_FieldPath, values: WireMessage?,
        elementExists: (RegisterPath) -> Bool
    ) -> Target? {
        guard let full = RegisterPath(path), full.segments.first == .field(kind) else { return nil }
        var message = Schema.root
        var current = values
        var inElement = false
        var sequence: Schema.FieldPolicy?
        for index in full.segments.indices {
            let at = RegisterPath(segments: Array(full.segments[...index]))
            let last = index == full.segments.count - 1
            switch full.segments[index] {
            case .field(let number):
                guard sequence == nil, let row = schema.field(message, Int(number)),
                      !(inElement && number == 1) else { return nil }
                if last {
                    return .field(at, row, current)
                }
                guard let typeName = row.typeName, !row.repeated || row.policy == .sequence else { return nil }
                switch row.policy {
                case .structure, .variant:
                    message = typeName
                    inElement = false
                case .sequence:
                    sequence = row
                default:
                    return nil
                }
                current = current?.message(number)
            case .element:
                guard let row = sequence, elementExists(at) else { return nil }
                sequence = nil
                message = row.typeName!
                inElement = true
                if last {
                    return .element(at, message, current)
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
                   inElement: false, &branch, &out)
        case .element(let at, let message, let value)?:
            expand(message, at, value, absentAsUnset: true, inElement: true, &branch, &out)
        case nil:
            return nil
        }
        return out
    }

    /// The registers a `CreateNode`'s props set: every leaf present, nothing else.
    func initial(kind: UInt32, props: WireMessage) -> [Assignment] {
        let row = schema.field(Schema.root, Int(kind))!
        return initial(row.typeName!, RegisterPath([kind]), props.message(kind), inElement: false)
    }

    /// The registers a new element's values set: every leaf present except its id.
    func initial(element message: String, at path: RegisterPath, values: WireMessage?) -> [Assignment] {
        initial(message, path, values, inElement: true)
    }

    private func initial(_ message: String, _ path: RegisterPath, _ value: WireMessage?, inElement: Bool) -> [Assignment] {
        var out: [Assignment] = []
        var branch: Set<String> = []
        expand(message, path, value, absentAsUnset: false, inElement: inElement, &branch, &out)
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
        inElement: Bool, _ branch: inout Set<String>, _ out: inout [Assignment]
    ) {
        guard absentAsUnset || value != nil, branch.insert(message).inserted else { return }
        let variant = schema.variant(message)
        for row in schema.fields(message) where !(inElement && row.fieldNumber == 1) {
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
                       inElement: false, &branch, &out)
            }
        }
        branch.remove(message)
    }
}
