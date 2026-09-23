import WTCRDT
import WTProto

/// Builders for the doc.v1 ops commands emit (docs/spec/crdt-model.adoc, "Operations").
public enum Ops {
    /// `CreateNode` under `parent` at `position` with `props` (the kind case and initial values).
    public static func create(parent: OpID, position: [UInt8], props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_Op {
        var create = Wiretuner_Doc_V1_CreateNode()
        create.parent = parent.proto
        create.position = .init(position)
        create.props = props
        var op = Wiretuner_Doc_V1_Op()
        op.create = create
        return op
    }

    /// `SetFields` writing the registers `paths` name on `node` from `values` (a path with no
    /// value in `values` clears its register).
    public static func set(_ node: OpID, _ paths: [RegisterPath], values: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_Op {
        var set = Wiretuner_Doc_V1_SetFields()
        set.node = node.proto
        set.paths = paths.map(\.proto)
        set.values = values
        var op = Wiretuner_Doc_V1_Op()
        op.set = set
        return op
    }

    /// `MoveNode` of `node` under `parent` at `position`.
    public static func move(_ node: OpID, parent: OpID, position: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var move = Wiretuner_Doc_V1_MoveNode()
        move.node = node.proto
        move.parent = parent.proto
        move.position = .init(position)
        var op = Wiretuner_Doc_V1_Op()
        op.move = move
        return op
    }

    /// `SetDeleted` of `node`.
    public static func setDeleted(_ node: OpID, _ deleted: Bool = true) -> Wiretuner_Doc_V1_Op {
        var setDeleted = Wiretuner_Doc_V1_SetDeleted()
        setDeleted.node = node.proto
        setDeleted.deleted = deleted
        var op = Wiretuner_Doc_V1_Op()
        op.setDeleted = setDeleted
        return op
    }

    /// `TextInsert` of `chars` into the TEXT field `field` of `node` between the Fugue origins
    /// `left` and `right` (`.zero`: the start or end).
    public static func textInsert(_ node: OpID, _ field: RegisterPath, _ chars: String, left: OpID = .zero,
                                  right: OpID = .zero) -> Wiretuner_Doc_V1_Op {
        var insert = Wiretuner_Doc_V1_TextInsert()
        insert.node = node.proto
        insert.text = field.proto
        insert.leftOrigin = elementID(left)
        insert.rightOrigin = elementID(right)
        insert.chars = chars
        var op = Wiretuner_Doc_V1_Op()
        op.textInsert = insert
        return op
    }

    /// `TextDelete` of `count` consecutive characters from `first` in the TEXT field `field`.
    public static func textDelete(_ node: OpID, _ field: RegisterPath, first: OpID, count: UInt64) -> Wiretuner_Doc_V1_Op {
        var range = Wiretuner_Doc_V1_ElementIdRange()
        range.first = elementID(first)
        range.count = count
        var delete = Wiretuner_Doc_V1_TextDelete()
        delete.node = node.proto
        delete.text = field.proto
        delete.ranges = [range]
        var op = Wiretuner_Doc_V1_Op()
        op.textDelete = delete
        return op
    }

    /// `ElementInsert` of one element per position into the SEQUENCE field `sequence` of `node`,
    /// with initial values from `values` (sparse, holding the inserted elements).
    public static func elementInsert(_ node: OpID, _ sequence: RegisterPath, positions: [[UInt8]],
                                     values: Wiretuner_Doc_V1_NodeProps = .init()) -> Wiretuner_Doc_V1_Op {
        var insert = Wiretuner_Doc_V1_ElementInsert()
        insert.node = node.proto
        insert.sequence = sequence.proto
        insert.positions = positions.map { .init($0) }
        insert.values = values
        var op = Wiretuner_Doc_V1_Op()
        op.elementInsert = insert
        return op
    }

    /// `ElementMove` of the element at `element` to `position`.
    public static func elementMove(_ node: OpID, _ element: RegisterPath, position: [UInt8]) -> Wiretuner_Doc_V1_Op {
        var move = Wiretuner_Doc_V1_ElementMove()
        move.node = node.proto
        move.element = element.proto
        move.position = .init(position)
        var op = Wiretuner_Doc_V1_Op()
        op.elementMove = move
        return op
    }

    /// `ElementDelete` of the elements at `elements` (`deleted` false restores them).
    public static func elementDelete(_ node: OpID, _ elements: [RegisterPath], deleted: Bool = true) -> Wiretuner_Doc_V1_Op {
        var delete = Wiretuner_Doc_V1_ElementDelete()
        delete.node = node.proto
        delete.elements = elements.map(\.proto)
        delete.deleted = deleted
        var op = Wiretuner_Doc_V1_Op()
        op.elementDelete = delete
        return op
    }

    /// `SetAdd` of the members `values` holds at the SET field `set` of `node`.
    public static func setAdd(_ node: OpID, _ set: RegisterPath, values: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_Op {
        var add = Wiretuner_Doc_V1_SetAdd()
        add.node = node.proto
        add.set = set.proto
        add.values = values
        var op = Wiretuner_Doc_V1_Op()
        op.setAdd = add
        return op
    }

    /// `SetRemove` of the members `values` holds at the SET field `set` of `node`.
    public static func setRemove(_ node: OpID, _ set: RegisterPath, values: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_Op {
        var remove = Wiretuner_Doc_V1_SetRemove()
        remove.node = node.proto
        remove.set = set.proto
        remove.values = values
        var op = Wiretuner_Doc_V1_Op()
        op.setRemove = remove
        return op
    }

    /// `Noop`: keeps one counter slot and changes nothing.
    public static func noop() -> Wiretuner_Doc_V1_Op {
        var op = Wiretuner_Doc_V1_Op()
        op.noop = Wiretuner_Doc_V1_Noop()
        return op
    }

    /// The doc.v1 `ElementId` of `id`.
    public static func elementID(_ id: OpID) -> Wiretuner_Doc_V1_ElementId {
        var element = Wiretuner_Doc_V1_ElementId()
        element.counter = id.counter
        element.replica = id.replica
        return element
    }
}
