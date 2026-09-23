import WTProto

/// Turns a `SetFields` path into register writes with the merge table
/// (docs/spec/crdt-model.adoc, "Field paths and registers"):
///
/// * a path ending at an ATOMIC field is one register; its value is that field's records in
///   `values`, or unset when `values` holds none;
/// * a path ending at a STRUCT field stands for every register beneath it in the table, each
///   written from `values` (absent leaves written unset);
/// * beneath a MERGE_VARIANT message present in `values`, only the case messages present are
///   written, so a kind switch never clears another case; a variant being cleared clears every
///   case;
/// * anything else -- an unknown field, a path running past an ATOMIC field, an element segment,
///   a SEQUENCE, TEXT or SET field (later tasks) -- makes the path a no-op.
struct PathResolver: Sendable {
    /// One register write: where, and the value (nil = unset).
    struct Assignment: Equatable {
        let path: RegisterPath
        let value: [UInt8]?
    }

    let schema: Schema

    /// The writes `path` stands for on a node of `kind`, or nil when the path is malformed for it
    /// (a deterministic no-op, "Totality").
    func resolve(kind: UInt32, path: Wiretuner_Doc_V1_FieldPath, values: WireMessage) -> [Assignment]? {
        let segments = path.segments
        guard let head = segments.first, case .field(kind)? = head.segment else { return nil }
        var message = Schema.root
        var current: WireMessage? = values
        var fields: [UInt32] = []
        var index = 0
        while true {
            guard case .field(let number)? = segments[index].segment,
                  let row = schema.field(message, Int(number)),
                  Self.isRegisterWalkable(row) else { return nil }
            fields.append(number)
            let at = RegisterPath(fields)
            let last = index == segments.count - 1
            if row.policy == .atomic {
                return last ? [Assignment(path: at, value: current?.records(number))] : nil
            }
            let sub = current?.message(number)
            if last {
                var out: [Assignment] = []
                var branch: Set<String> = []
                expand(row.typeName!, at, sub, absentAsUnset: true, &branch, &out)
                return out
            }
            message = row.typeName!
            current = sub
            index += 1
        }
    }

    /// The registers a `CreateNode`'s props set: every leaf present, nothing else.
    func initial(kind: UInt32, props: WireMessage) -> [Assignment] {
        var out: [Assignment] = []
        var branch: Set<String> = []
        let row = schema.field(Schema.root, Int(kind))!
        expand(row.typeName!, RegisterPath([kind]), props.message(kind), absentAsUnset: false, &branch, &out)
        return out
    }

    // ATOMIC fields are registers; singular STRUCT/VARIANT message fields are walked through.
    private static func isRegisterWalkable(_ row: Schema.FieldPolicy) -> Bool {
        switch row.policy {
        case .atomic: true
        case .structure, .variant: !row.repeated && row.typeName != nil
        default: false
        }
    }

    /// Appends the registers beneath `message` at `prefix`.  With `absentAsUnset` every leaf is
    /// written (a STRUCT write or clear); without it only leaves present in `value` are (a
    /// CreateNode).  A message already on the current branch is not entered again, so a recursive
    /// schema expands finitely and identically in both engines.
    private func expand(
        _ message: String, _ prefix: RegisterPath, _ value: WireMessage?, absentAsUnset: Bool,
        _ branch: inout Set<String>, _ out: inout [Assignment]
    ) {
        guard absentAsUnset || value != nil, branch.insert(message).inserted else { return }
        let variant = schema.variant(message)
        for row in schema.fields(message) {
            let number = UInt32(row.fieldNumber)
            let present = value?.has(number) ?? false
            let skippedCase = variant != nil && value != nil && !present
                && variant!.caseFields.contains(row.fieldNumber)
            guard Self.isRegisterWalkable(row), !skippedCase, absentAsUnset || present else { continue }
            let path = prefix.child(number)
            if row.policy == .atomic {
                out.append(Assignment(path: path, value: value?.records(number)))
            } else {
                expand(row.typeName!, path, value?.message(number), absentAsUnset: absentAsUnset, &branch, &out)
            }
        }
        branch.remove(message)
    }
}
