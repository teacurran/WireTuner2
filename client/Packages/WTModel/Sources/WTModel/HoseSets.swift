import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// DRAW-038: Graphic Hose sets in the document (docs/_includes/drawing/graphic-hose.adoc, "Data
// model", "Merge semantics").  A set is a `hose_set` node (`NodeProps` field 26, hose.proto)
// under the symbols collection 0:7; its children are the hose's objects in sibling order, never
// drawn on the pasteboard (0:7 is not a layer).  Each object is stored centred on the origin, so
// a spray places it by its centre.

/// The `hose_set` node kind's registers.
public enum HoseFields {
    /// `NodeProps.hose_set`.
    public static let kind: UInt32 = 26
    /// Where document sets live: the symbols collection.
    public static let collection = WellKnown.symbols
    public static let name = RegisterPath([26, 1, 1])
    public static let note = RegisterPath([26, 1, 2])
    /// The `HoseOptions` field `field`.
    public static func option(_ field: UInt32) -> RegisterPath { RegisterPath([26, 2, field]) }
    /// A set sprays its first ten live objects.
    public static let maximumObjects = 10
    /// A library set's identity in `CommonProps.note`: this prefix and a UUID.
    public static let libraryPrefix = "wt-hose:"
}

/// Why a hose command was refused.
public enum HoseError: Error, Equatable, Sendable {
    /// Not a live hose set.
    case notASet(OpID)
    /// Not a live object of the set.
    case notAnObject(OpID)
    /// The set already has ten objects.
    case full
    /// Nothing on the pasteboard to add.
    case nothingToAdd
    /// A set needs a name.
    case emptyName
    /// Another set of the document holds the name.
    case nameTaken(String)
    /// The `.wthose` bundle is not a hose.
    case unreadableBundle
}

/// One option of a set, as `SetHoseOptions` writes it.
public enum HoseOption: Hashable, Sendable {
    case order(Wiretuner_Doc_V1_HoseOrder)
    case spacing(Wiretuner_Doc_V1_HoseSpacing)
    /// Points, > 0.
    case gridSize(Double)
    /// 0 ... 200.
    case spacingAmount(Double)
    case scale(Wiretuner_Doc_V1_HoseScale)
    /// 1 ... 200.
    case scalePercent(Double)
    case rotation(Wiretuner_Doc_V1_HoseRotation)
    /// Radians.
    case angle(Double)

    /// The `HoseOptions` field number.
    var field: UInt32 {
        switch self {
        case .order: 1
        case .spacing: 2
        case .gridSize: 3
        case .spacingAmount: 4
        case .scale: 5
        case .scalePercent: 6
        case .rotation: 7
        case .angle: 8
        }
    }

    /// Writes the option into `options`, or throws for a value out of range.
    func write(into options: inout Wiretuner_Doc_V1_HoseOptions) throws {
        switch self {
        case .order(let value): options.order = value
        case .spacing(let value): options.spacing = value
        case .scale(let value): options.scale = value
        case .rotation(let value): options.rotation = value
        case .gridSize(let value):
            guard value.isFinite, value > 0 else { throw ObjectEditError.invalidValue("grid size") }
            options.gridSize = value
        case .spacingAmount(let value):
            guard value.isFinite, (0...200).contains(value) else { throw ObjectEditError.invalidValue("spacing") }
            options.spacingAmount = value
        case .scalePercent(let value):
            guard value.isFinite, (1...200).contains(value) else { throw ObjectEditError.invalidValue("scale") }
            options.scalePercent = value
        case .angle(let value):
            guard value.isFinite else { throw ObjectEditError.invalidValue("angle") }
            options.angle = value
        }
    }
}

/// One document hose set as read.
public struct HoseSet: Hashable, Sendable {
    public let id: OpID
    public let name: String
    /// The library identity of a set copied from a library hose.
    public let libraryID: UUID?
    /// The stored options.
    public let stored: Wiretuner_Doc_V1_HoseOptions
    /// The options after the read normalizations.
    public let options: HoseSprayOptions
    /// The objects a spray takes: the first ten live children, in sibling order.
    public let objects: [OpID]
    /// Live children past the tenth (a merge of concurrent additions): listed dimmed, never sprayed.
    public let extras: [OpID]
}

/// Reading hose sets.
public enum HoseSets {
    /// The live sets of the document, in sibling order.
    public static func list(in state: EngineState) -> [HoseSet] {
        state.liveChildren(HoseFields.collection).compactMap { set($0, in: state) }
    }

    /// The live set `id`, or nil.
    public static func set(_ id: OpID, in state: EngineState) -> HoseSet? {
        guard state.store.kind(id) == HoseFields.kind, state.isLive(id), state.store.placement(id)?.parent == HoseFields.collection else { return nil }
        let props = state.props(id).hoseSet
        let children = state.liveChildren(id)
        return HoseSet(id: id, name: props.common.name, libraryID: libraryID(props.common.note), stored: props.options,
                       options: options(props.options), objects: Array(children.prefix(HoseFields.maximumObjects)),
                       extras: Array(children.dropFirst(HoseFields.maximumObjects)))
    }

    /// The live set copied from the library hose `libraryID`, if the document has one (the one
    /// with the smallest id when a merge made two).
    public static func set(libraryID: UUID, in state: EngineState) -> HoseSet? {
        list(in: state).filter { $0.libraryID == libraryID }.min { $0.id < $1.id }
    }

    /// The identity a set's note holds, or nil.
    static func libraryID(_ note: String) -> UUID? {
        guard note.hasPrefix(HoseFields.libraryPrefix) else { return nil }
        return UUID(uuidString: String(note.dropFirst(HoseFields.libraryPrefix.count)))
    }

    /// The note recording `libraryID`.
    static func note(_ libraryID: UUID) -> String { HoseFields.libraryPrefix + libraryID.uuidString }

    /// `stored` with the read normalizations: unset enums read as their defaults, a grid size of
    /// 0 or less reads as 36 pt, a scale of 0 reads as 100%.
    public static func options(_ stored: Wiretuner_Doc_V1_HoseOptions) -> HoseSprayOptions {
        let order: HoseSprayOptions.Order = switch stored.order {
        case .backAndForth: .backAndForth
        case .random: .random
        default: .loop
        }
        let spacing: HoseSprayOptions.Spacing = switch stored.spacing {
        case .grid: .grid
        case .random: .random
        default: .variable
        }
        let rotation: HoseSprayOptions.Rotation = switch stored.rotation {
        case .incremental: .incremental
        case .random: .random
        default: .uniform
        }
        return HoseSprayOptions(order: order, spacing: spacing, gridSize: stored.gridSize, spacingAmount: stored.spacingAmount,
                                scale: stored.scale == .random ? .random : .uniform, scalePercent: stored.scalePercent,
                                rotation: rotation, angle: stored.angle)
    }

    /// The set's objects' size at 100%: the largest side of any object's bounds (1 when none has
    /// bounds), the sprayer's spacing unit.
    public static func extent(of set: HoseSet, in state: EngineState) -> Double {
        let sides = set.objects.compactMap { Objects.bounds(of: $0, in: state) }.map { max($0.width, $0.height) }
        return max(sides.max() ?? 1, 1)
    }

    /// The set as a tree (the set node and its live objects), for `.wthose` bundles.
    public static func tree(_ id: OpID, in state: EngineState) -> NodeTree {
        NodeTree(id, state: state)
    }

    /// A name as stored, trimmed; refused when empty or held by another set.
    static func checkedName(_ name: String, except: OpID? = nil, in state: EngineState) throws -> String {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SwatchFields.maxName))
        guard !clean.isEmpty else { throw HoseError.emptyName }
        guard !list(in: state).contains(where: { $0.name == clean && $0.id != except }) else { throw HoseError.nameTaken(clean) }
        return clean
    }

    /// The live set `id`, or throws.
    static func live(_ id: OpID, in state: EngineState) throws -> HoseSet {
        guard let set = set(id, in: state) else { throw HoseError.notASet(id) }
        return set
    }

    /// Payload artwork as one hose object centred on the origin: a single copied object, or a
    /// group of several.
    static func object(from payload: ClipboardPayload) -> NodeTree {
        let center = payload.bounds.map { Point(x: $0.midX, y: $0.midY) } ?? .zero
        let recentre = AffineTransform.translation(x: -center.x, y: -center.y)
        let trees = payload.nodes.map { tree -> NodeTree in
            var copy = tree
            copy.transform = tree.transform.concatenating(recentre)
            copy.transformConnectors(by: recentre)
            return copy
        }
        if trees.count == 1 { return trees[0] }
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group.common.name = "Group"
        return NodeTree(props: group, children: trees)
    }
}

/// menu:Sets[New…] in the Graphic Hose sheet: an empty set at the top of the symbols collection.
/// Labelled "New hose set".
public struct CreateHoseSet: Command {
    public var name: String
    public var options: Wiretuner_Doc_V1_HoseOptions

    public init(name: String, options: Wiretuner_Doc_V1_HoseOptions = Wiretuner_Doc_V1_HoseOptions()) {
        self.name = name
        self.options = options
    }

    public var label: String { "New hose set" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.hoseSet.common.name = try HoseSets.checkedName(name, in: state)
        props.hoseSet.options = options
        builder.append(Ops.create(parent: HoseFields.collection, position: try PathEditing.topPosition(in: HoseFields.collection, state: state),
                                  props: props))
    }
}

/// menu:Sets[Rename…].  Labelled "Rename hose set".
public struct RenameHoseSet: Command {
    public var set: OpID
    public var name: String

    public init(_ set: OpID, name: String) {
        self.set = set
        self.name = name
    }

    public var label: String { "Rename hose set" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try HoseSets.live(set, in: state)
        let clean = try HoseSets.checkedName(name, except: set, in: state)
        guard clean != current.name else { return }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.hoseSet.common.name = clean
        builder.append(Ops.set(set, [HoseFields.name], values: props))
    }
}

/// menu:Sets[Duplicate…]: a deep copy of the set -- options and objects -- under a new name; the
/// copy is the document's own (no library identity).  Labelled "Duplicate hose set".
public struct DuplicateHoseSet: Command {
    public var set: OpID
    public var name: String

    public init(_ set: OpID, name: String) {
        self.set = set
        self.name = name
    }

    public var label: String { "Duplicate hose set" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try HoseSets.live(set, in: state)
        var tree = HoseSets.tree(set, in: state)
        tree.props.hoseSet.common.name = try HoseSets.checkedName(name, in: state)
        tree.props.hoseSet.common.note = ""
        try NodeCopier.create(tree, parent: HoseFields.collection, position: try PathEditing.topPosition(in: HoseFields.collection, state: state),
                              schema: state.schema, builder: &builder)
    }
}

/// menu:Sets[Delete…]: the set's `deleted` flag.  Its objects stay inside it, so restoring the set
/// (`RestoreHoseSet`, the review sheet) brings them back; objects sprayed from it are copies and
/// stay.  Labelled "Delete hose set".
public struct DeleteHoseSet: Command {
    public var set: OpID

    public init(_ set: OpID) {
        self.set = set
    }

    public var label: String { "Delete hose set" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try HoseSets.live(set, in: state)
        builder.append(Ops.setDeleted(set))
    }
}

/// Restoring a deleted set with its objects (the review sheet's *Restore*).  Labelled "Restore
/// hose set".
public struct RestoreHoseSet: Command {
    public var set: OpID

    public init(_ set: OpID) {
        self.set = set
    }

    public var label: String { "Restore hose set" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.store.kind(set) == HoseFields.kind, !state.isLive(set) else { throw HoseError.notASet(set) }
        builder.append(Ops.setDeleted(set, false))
    }
}

/// btn:[Paste In]: the pasteboard's artwork becomes the set's next object -- one copied object as
/// it is, several as a group -- centred on the origin.  Refused when the set already has ten live
/// objects (a merge may still make more; only the first ten spray).  Labelled "Paste in hose
/// object".
public struct AddHoseObject: Command {
    public var set: OpID
    public var payload: ClipboardPayload

    public init(_ set: OpID, payload: ClipboardPayload) {
        self.set = set
        self.payload = payload
    }

    public var label: String { "Paste in hose object" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try HoseSets.live(set, in: state)
        guard !payload.isEmpty else { throw HoseError.nothingToAdd }
        guard current.objects.count + current.extras.count < HoseFields.maximumObjects else { throw HoseError.full }
        try NodeCopier.create(HoseSets.object(from: payload), parent: set, position: try PathEditing.topPosition(in: set, state: state),
                              schema: state.schema, builder: &builder)
    }
}

/// btn:[Remove]: the object's `deleted` flag.  Labelled "Remove hose object".
public struct RemoveHoseObject: Command {
    public var set: OpID
    public var object: OpID

    public init(_ set: OpID, object: OpID) {
        self.set = set
        self.object = object
    }

    public var label: String { "Remove hose object" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try HoseSets.live(set, in: state)
        guard (current.objects + current.extras).contains(object) else { throw HoseError.notAnObject(object) }
        builder.append(Ops.setDeleted(object))
    }
}

/// The *Options* view: each named option is its own register (two people changing different
/// options both hold; the same option is LWW).  Labelled "Change hose options".
public struct SetHoseOptions: Command {
    public var set: OpID
    public var options: [HoseOption]

    public init(_ set: OpID, _ options: [HoseOption]) {
        self.set = set
        self.options = options
    }

    public var label: String { "Change hose options" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try HoseSets.live(set, in: state)
        guard !options.isEmpty else { return }
        var props = Wiretuner_Doc_V1_NodeProps()
        var paths: [RegisterPath] = []
        for option in options {
            try option.write(into: &props.hoseSet.options)
            let path = HoseFields.option(option.field)
            if !paths.contains(path) { paths.append(path) }
        }
        builder.append(Ops.set(set, paths, values: props))
    }
}

/// Spraying with a library hose copies it into the document first -- one change, "Copy hose to
/// document" -- as a set carrying the library identity in its note, unless a live set with that
/// identity is already there (then nothing is written and the tool sprays from that one).
public struct ImportHoseSet: Command {
    public var bundle: HoseBundle

    public init(_ bundle: HoseBundle) {
        self.bundle = bundle
    }

    public var label: String { "Copy hose to document" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var tree = bundle.tree
        if let id = bundle.libraryID {
            guard HoseSets.set(libraryID: id, in: state) == nil else { return }
            tree.props.hoseSet.common.note = HoseSets.note(id)
        }
        try NodeCopier.create(tree, parent: HoseFields.collection, position: try PathEditing.topPosition(in: HoseFields.collection, state: state),
                              schema: state.schema, builder: &builder)
    }
}

/// One spray stroke (graphic-hose.adoc, "Spray vs. anything"): a deep copy of the set's object for
/// each placement, created on top of the layer (the active one, else the drawing layer) with the
/// placement composed into its transform -- concrete values, so every replica sees the same
/// stroke.  A symbol member (an `instance`) sprays as instances.  Placements naming no object
/// (past the set's first ten) are skipped.  Labelled "Spray 12 objects" (or "Spray object").
/// A stroke that would pass the 10,000-op change limit is split by `SprayHose.strokes`.
public struct SprayHose: Command {
    /// The op limit of one change.
    public static let opLimit = 10_000

    public var set: OpID
    public var placements: [HosePlacement]
    public var layer: OpID?
    /// The whole stroke's object count when this is one piece of a split stroke (the label).
    public var strokeCount: Int?

    public init(_ set: OpID, placements: [HosePlacement], layer: OpID? = nil, strokeCount: Int? = nil) {
        self.set = set
        self.placements = placements
        self.layer = layer
        self.strokeCount = strokeCount
    }

    public var label: String {
        let count = strokeCount ?? placements.count
        return count == 1 ? "Spray object" : "Spray \(count) objects"
    }

    /// The stroke as consecutive changes of at most `limit` ops each (one when it fits); every
    /// piece carries the whole stroke's label, so the history reads as one spray.
    public static func strokes(_ set: OpID, placements: [HosePlacement], layer: OpID? = nil, in state: EngineState,
                               limit: Int = opLimit) throws -> [SprayHose] {
        let current = try HoseSets.live(set, in: state)
        var costs: [OpID: Int] = [:]
        for object in current.objects {
            var scratch = ChangeBuilder(replica: 1, startCounter: 1)
            try NodeCopier.create(NodeTree(object, state: state), parent: set, position: [0x80], schema: state.schema, builder: &scratch)
            costs[object] = scratch.ops.count
        }
        var pieces: [[HosePlacement]] = [[]]
        var used = 1 // a possible layer creation
        for placement in placements {
            guard placement.index >= 0, placement.index < current.objects.count else { continue }
            let cost = costs[current.objects[placement.index]]!
            if used + cost > limit, !pieces[pieces.count - 1].isEmpty {
                pieces.append([])
                used = 1
            }
            pieces[pieces.count - 1].append(placement)
            used += cost
        }
        let total = pieces.reduce(0) { $0 + $1.count }
        return pieces.filter { !$0.isEmpty }.map { SprayHose(set, placements: $0, layer: layer, strokeCount: total) }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let current = try HoseSets.live(set, in: state)
        let placed = placements.filter { $0.index >= 0 && $0.index < current.objects.count }
        guard !placed.isEmpty else { return }
        let target = try PathEditing.ensureLayer(&builder, state: state, preferred: layer)
        let toLayer = Objects.pasteboardTransform(ofSpace: target, in: state).inverse
        let top = state.store.children(target).last.flatMap { state.store.placement($0)?.position }
        let keys = try PathEditing.keys(between: top, and: nil, count: placed.count)
        var trees: [OpID: NodeTree] = [:]
        for (placement, key) in zip(placed, keys) {
            let object = current.objects[placement.index]
            let source = trees[object] ?? NodeTree(object, state: state)
            trees[object] = source
            var copy = source
            copy.transform = source.transform.concatenating(placement.transform).concatenating(toLayer)
            copy.transformConnectors(by: placement.transform)
            try NodeCopier.create(copy, parent: target, position: key, schema: state.schema, builder: &builder)
        }
    }
}
