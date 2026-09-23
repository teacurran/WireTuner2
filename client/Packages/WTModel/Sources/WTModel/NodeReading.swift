import WTCRDT
import WTProto
import WTRender

extension NodeID {
    /// The render-side mirror of a merge-engine id (WTRender cannot import WTCRDT).
    public init(_ id: OpID) {
        self.init(counter: id.counter, replica: id.replica)
    }
}

extension OpID {
    /// The merge-engine id a render-side `NodeID` mirrors.
    public init(_ id: NodeID) {
        self.init(counter: id.counter, replica: id.replica)
    }

    /// This id as a doc.v1 `ElementId`.
    public var elementID: Wiretuner_Doc_V1_ElementId { Ops.elementID(self) }

    /// The id a doc.v1 `ElementId` names; nil for the all-zero "none".
    public init?(element: Wiretuner_Doc_V1_ElementId) {
        guard element.counter != 0 || element.replica != 0 else { return nil }
        self.init(counter: element.counter, replica: element.replica)
    }
}

/// The well-known collections of every document (docs/spec/crdt-model.adoc, "The node tree").
public enum WellKnown {
    public static let document = OpID.wellKnown(0)
    public static let settings = OpID.wellKnown(1)
    public static let pages = OpID.wellKnown(2)
    public static let layers = OpID.wellKnown(4)
    public static let swatches = OpID.wellKnown(5)
    public static let symbols = OpID.wellKnown(7)
}

/// The `NodeProps.kind` field numbers WTModel reads (docs/spec/crdt-model.adoc, the kind table).
public enum NodeKind: UInt32, Sendable, CaseIterable {
    case path = 20
    case rect = 21
    case ellipse = 22
    case polygon = 23
    /// A chart regenerated from its data (charts.adoc).
    case chart = 24
    /// A line joining two objects, routed on read from their bounds (connectors.adoc).
    case connector = 25
    case group = 50
    case layer = 150
    /// A symbol's master: its children are the artwork (library.adoc).
    case symbol = 151
    /// An instance of a symbol, on a layer (library.adoc).
    case instance = 153
    /// A placed file shown through its preview, such as EPS (import-formats.adoc).
    case placedFile = 171
    /// A QR or Code 128 barcode (data-merge.adoc, "Barcodes").
    case barcode = 240
}

extension EngineState {
    /// Whether `node` exists and its `deleted` register does not hold true.  A node under a
    /// deleted ancestor is still live by this test; the tree walks skip deleted subtrees.
    public func isLive(_ node: OpID) -> Bool {
        store.exists(node) && store.deleted(node)?.current.value != true
    }

    /// The live children of `node`, in sibling order (position, then id): bottom first.
    public func liveChildren(_ node: OpID) -> [OpID] {
        store.children(node).filter(isLive)
    }

    /// The kind of `node`, when WTModel knows it.
    public func nodeKind(_ node: OpID) -> NodeKind? {
        NodeKind(rawValue: store.kind(node))
    }

    /// The live elements of the SEQUENCE at `sequence` of `node`, in order (tombstones skipped).
    public func liveElements(_ node: OpID, _ sequence: RegisterPath) -> [OpID] {
        store.elementOrder(node, sequence).filter { store.element(node, sequence.element($0))?.isDeleted == false }
    }

    /// The position register of the element `element` of the SEQUENCE at `sequence`.
    public func position(_ node: OpID, _ sequence: RegisterPath, _ element: OpID) -> [UInt8]? {
        store.element(node, sequence.element(element))?.position.current.value
    }

    /// The merged properties of `node` as a typed message: every register that holds a value,
    /// placed at its path, and every live sequence element in sequence order with its `id` set
    /// (tombstoned elements and everything under them are left out).  TEXT fields are not read.
    public func props(_ node: OpID) -> Wiretuner_Doc_V1_NodeProps {
        let kind = store.kind(node)
        guard kind != 0 else { return Wiretuner_Doc_V1_NodeProps() }
        let root = PropsTree()
        _ = root.child(kind)
        for (path, element) in store.elements(node) where !element.isDeleted {
            root.markElement(at: path)
        }
        for (path, register) in store.registers(node) {
            if let value = register.value {
                root.leafNode(at: path)?.leaf = value
            }
        }
        let bytes = root.encodeMessage { sequence in liveElements(node, sequence) }
        return (try? Wiretuner_Doc_V1_NodeProps(serializedBytes: bytes)) ?? Wiretuner_Doc_V1_NodeProps()
    }
}

/// A sparse message being reassembled from register paths: field numbers to sub-messages or
/// leaves, and after a SEQUENCE field its elements by id.  Also rooted below `NodeProps` (a
/// paragraph's registers on a newline, `TextNode`), with `path` the root's full register path.
final class PropsTree {
    var leaf: [UInt8]?
    var fields: [UInt32: PropsTree] = [:]
    var elements: [OpID: PropsTree] = [:]
    /// Set on an element node that is live (inserted and not deleted).
    var isElement = false
    /// Set on a SEQUENCE field's node (an element segment follows it).
    var isSequence = false
    /// The path of this node from `NodeProps` (for looking up a sequence's order).
    let path: RegisterPath?

    init(path: RegisterPath? = nil) {
        self.path = path
    }

    func child(_ field: UInt32) -> PropsTree {
        if let existing = fields[field] { return existing }
        let node = PropsTree(path: path?.child(field) ?? RegisterPath([field]))
        fields[field] = node
        return node
    }

    /// Walks `path` (an element's path), creating nodes, and marks the element live.
    func markElement(at path: RegisterPath) {
        var current = self
        for segment in path.segments {
            switch segment {
            case .field(let number):
                current = current.child(number)
            case .element(let id):
                current.isSequence = true
                if let existing = current.elements[id] {
                    current = existing
                } else {
                    let node = PropsTree(path: current.path?.element(id))
                    current.elements[id] = node
                    current = node
                }
            }
        }
        current.isElement = true
    }

    /// The node for the register at `path`, or nil when the path runs through an element that
    /// is not live.
    func leafNode(at path: RegisterPath) -> PropsTree? {
        var current = self
        for segment in path.segments {
            switch segment {
            case .field(let number):
                current = current.child(number)
            case .element(let id):
                current.isSequence = true
                guard let existing = current.elements[id], existing.isElement else { return nil }
                current = existing
            }
        }
        return current
    }

    /// The protobuf encoding of this node as a message: fields in number order; a SEQUENCE field
    /// as one occurrence per live element in `order`'s order, `id` (field 1) first.
    func encodeMessage(order: (RegisterPath) -> [OpID]) -> [UInt8] {
        var out: [UInt8] = []
        for number in fields.keys.sorted() {
            let node = fields[number]!
            if let leaf = node.leaf {
                out += leaf
            } else if node.isSequence, let path = node.path {
                for id in order(path) {
                    guard let element = node.elements[id], element.isElement else { continue }
                    var payload = Wire.field(1, Wire.elementID(id))
                    payload += element.encodeMessage(order: order)
                    out += Wire.field(number, payload)
                }
            } else {
                out += Wire.field(number, node.encodeMessage(order: order))
            }
        }
        return out
    }
}

/// Minimal protobuf wire writing for `PropsTree`.
enum Wire {
    /// A message's encoding (empty if it cannot be encoded, which a proto3 message built here
    /// never is).
    static func bytes(_ encode: () throws -> [UInt8]) -> [UInt8] {
        (try? encode()) ?? []
    }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }

    /// A length-delimited record of field `number`.
    static func field(_ number: UInt32, _ payload: [UInt8]) -> [UInt8] {
        varint(UInt64(number) << 3 | 2) + varint(UInt64(payload.count)) + payload
    }

    /// An `ElementId` message's encoding (counter varint, replica fixed64).
    static func elementID(_ id: OpID) -> [UInt8] {
        var out = varint(1 << 3 | 0) + varint(id.counter)
        out += varint(2 << 3 | 1)
        withUnsafeBytes(of: id.replica.littleEndian) { out += $0 }
        return out
    }
}
