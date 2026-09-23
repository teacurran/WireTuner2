import WTCRDT
import WTProto

/// Attribute names people read ("Fill", "Transform", "Size") for the registers a change wrote,
/// from the merge table's field names (the attribution flash's label and the review sheet's
/// property rows, collaboration.adoc).
enum RegisterNames {
    /// The title of the register at `path` (from `NodeProps`): the first field under the kind's
    /// message, looking through `common` and `appearance` to the field inside them.
    static func title(_ path: RegisterPath, schema: Schema = .generated) -> String {
        let fields = path.fields
        guard let kindNumber = fields.first, let kind = schema.field(Schema.root, Int(kindNumber)) else { return "Attribute" }
        var message = kind.typeName
        var chosen = kind.name
        for number in fields.dropFirst() {
            guard let current = message, let field = schema.field(current, Int(number)) else { break }
            chosen = field.name
            guard field.name == "common" || field.name == "appearance" else { break }
            message = field.typeName
        }
        return humanized(chosen)
    }

    /// "stroke_width" → "Stroke width".
    static func humanized(_ name: String) -> String {
        let words = name.split(separator: "_").map(String.init)
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// Every attribute a change wrote on each node, in op order: register writes by name, moves as
    /// "Position", deletions as "Deleted", text edits as "Text", creations as "Created".
    static func touched(by change: Wiretuner_Doc_V1_Change, schema: Schema = .generated) -> [(node: OpID, attributes: [String])] {
        var order: [OpID] = []
        var names: [OpID: [String]] = [:]
        func add(_ node: Wiretuner_Doc_V1_OpId, _ title: String) {
            let id = OpID(node)
            if names[id] == nil { order.append(id) }
            if names[id, default: []].contains(title) == false { names[id, default: []].append(title) }
        }
        for op in change.ops {
            switch op.op {
            case .set(let set)?:
                for path in set.paths.compactMap(RegisterPath.init) { add(set.node, title(path, schema: schema)) }
            case .move(let move)?: add(move.node, "Position")
            case .setDeleted(let deleted)?: add(deleted.node, deleted.deleted ? "Deleted" : "Restored")
            case .elementInsert(let insert)?: add(insert.node, RegisterPath(insert.sequence).map { title($0, schema: schema) } ?? "Points")
            case .elementMove(let move)?: add(move.node, RegisterPath(move.element).map { title($0, schema: schema) } ?? "Points")
            case .elementDelete(let delete)?: add(delete.node, delete.elements.first.flatMap(RegisterPath.init).map { title($0, schema: schema) } ?? "Points")
            case .textInsert(let insert)?: add(insert.node, "Text")
            case .textDelete(let delete)?: add(delete.node, "Text")
            case .textMark(let mark)?: add(mark.node, "Text style")
            default: break
            }
        }
        return order.map { ($0, names[$0] ?? []) }
    }
}
