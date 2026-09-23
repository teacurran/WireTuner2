import WTCRDT
import WTGeometry
import WTProto
import WTRender

// ATTR-024: the gradient model commands (docs/_includes/appearance/gradients.adoc, "Applying a
// gradient", "The ramp", "Merge semantics").  A gradient is the `gradient` case of a fill's
// `FillSettings` (field 3); its stops are a SEQUENCE whose ramp order is the stops' `offset`, then
// element id -- sequence positions are written but never read.

/// Register paths of a `GradientFill`, relative to the fill's `settings` message.
public enum GradientFields {
    public static let type: [UInt32] = [3, 1]
    public static let behavior: [UInt32] = [3, 2]
    public static let repeatCount: [UInt32] = [3, 3]
    public static let axis: [UInt32] = [3, 4]
    public static let stops: [UInt32] = [3, 5]
    public static let overprint: [UInt32] = [3, 6]
    /// A stop's `offset` and `color`, relative to its element.
    public static let stopOffset: UInt32 = 2
    public static let stopColor: UInt32 = 3
}

/// One stop of a ramp as read.
public struct GradientRampStop: Hashable, Sendable {
    public var id: OpID
    /// Clamped to 0 ... 1.
    public var offset: Double
    public var color: Wiretuner_Doc_V1_ColorRef
}

/// The gradient's read-time normalizations (gradients.adoc, "Read-time normalizations").
public struct NormalizedGradient: Hashable, Sendable {
    public var type: Wiretuner_Doc_V1_GradientType
    public var behavior: Wiretuner_Doc_V1_GradientBehavior
    /// 1 ... 100; 1 for Normal and Auto size.
    public var repeatCount: Int
    /// Nil reads as Auto size geometry, whatever `behavior` says.
    public var axis: Gradient.Axis?
    /// The ramp: two or more stops (one stop reads as that colour at both ends); empty when the
    /// fill reads as Basic.
    public var stops: [GradientRampStop]
}

/// Reading gradients.
public enum GradientReading {
    /// The live stops of `gradient` in ramp order: offset (clamped to 0 ... 1), then element id.
    public static func ramp(_ gradient: Wiretuner_Doc_V1_GradientFill) -> [GradientRampStop] {
        gradient.stops.map { stop in
            let offset = stop.offset.isFinite ? min(max(stop.offset, 0), 1) : 0
            return GradientRampStop(id: OpID(element: stop.id) ?? .zero, offset: offset, color: stop.color)
        }.sorted { a, b in a.offset != b.offset ? a.offset < b.offset : a.id < b.id }
    }

    /// `gradient` with every read-time normalization applied.
    public static func normalized(_ gradient: Wiretuner_Doc_V1_GradientFill) -> NormalizedGradient {
        let type: Wiretuner_Doc_V1_GradientType
        switch gradient.type {
        case .logarithmic, .radial, .rectangle, .contour, .cone: type = gradient.type
        default: type = .linear
        }
        let behavior: Wiretuner_Doc_V1_GradientBehavior
        switch gradient.behavior {
        case .repeat, .reflect, .autoSize: behavior = gradient.behavior
        default: behavior = .normal
        }
        let count = behavior == .repeat || behavior == .reflect ? Int(min(max(gradient.repeatCount, 1), 100)) : 1
        var stops = ramp(gradient)
        if stops.count == 1 {
            var start = stops[0]
            start.offset = 0
            var end = stops[0]
            end.offset = 1
            stops = [start, end]
        }
        return NormalizedGradient(type: type, behavior: behavior, repeatCount: count, axis: axis(gradient, type: type), stops: stops)
    }

    /// The axis as read: unset is Auto size (nil); `end` equal to `start` reads as a 1 pt axis;
    /// an unset `end2` on Radial and Rectangle is `end − start` turned 90° about `start`.
    static func axis(_ gradient: Wiretuner_Doc_V1_GradientFill, type: Wiretuner_Doc_V1_GradientType) -> Gradient.Axis? {
        guard gradient.hasAxis else { return nil }
        let start = Point(x: gradient.axis.start.x, y: gradient.axis.start.y)
        var end = Point(x: gradient.axis.end.x, y: gradient.axis.end.y)
        if end == start { end = Point(x: start.x + 1, y: start.y) }
        var end2: Point?
        if type == .radial || type == .rectangle {
            end2 = gradient.axis.hasEnd2 ? Point(x: gradient.axis.end2.x, y: gradient.axis.end2.y)
                : Point(x: start.x - (end.y - start.y), y: start.y + (end.x - start.x))
        }
        return Gradient.Axis(start: start, end: end, end2: end2)
    }

    /// The colour of a removed stop as its tombstone holds it (what *Restore* re-inserts), or nil
    /// when the stop never had one.
    public static func tombstoneColor(_ node: OpID, row: AppearanceRow, stop: OpID, in state: EngineState) -> Wiretuner_Doc_V1_ColorRef? {
        guard let owner = StackOwner.of(node, in: state) else { return nil }
        let path = GradientEditing.stops(owner, row).element(stop).child(GradientFields.stopColor)
        guard let bytes = state.store.register(node, path)?.value else { return nil }
        return WireRecords(bytes).first { $0.field == GradientFields.stopColor }.flatMap { try? Wiretuner_Doc_V1_ColorRef(serializedBytes: $0.payload) }
    }
}

/// Shared writing of gradient fills.
enum GradientEditing {
    /// The fill `row` of `node`, its owner and its stored gradient, or throws.
    static func fill(_ node: OpID, _ row: AppearanceRow, in state: EngineState) throws -> (owner: StackOwner, entry: AttributeEntry) {
        guard row.list == .fills else { throw PathEditError.unknownPoint(row.element) }
        let owner = try AppearanceEditing.owner(node, row, in: state)
        return (owner, AttributeEntry.read(node, row, owner: owner, state: state))
    }

    /// The fill's `settings` path.
    static func settings(_ owner: StackOwner, _ row: AppearanceRow) -> RegisterPath {
        owner.sequence(.fills).element(row.element).child(AppearanceList.fills.settingsField)
    }

    /// The stops SEQUENCE of the fill's gradient.
    static func stops(_ owner: StackOwner, _ row: AppearanceRow) -> RegisterPath {
        settings(owner, row).appending(GradientFields.stops)
    }

    /// A sparse `NodeProps` holding `gradient` as the fill's gradient (and `kind` when given).
    static func values(_ owner: StackOwner, _ gradient: Wiretuner_Doc_V1_GradientFill, kind: Wiretuner_Doc_V1_FillKind? = nil) -> Wiretuner_Doc_V1_NodeProps {
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.gradient = gradient
        if let kind { fill.settings.kind = kind }
        return AppearanceEditing.values(owner) { $0.fills = [fill] }
    }

    /// `ElementInsert`s of `stops` (offset, colour) into the fill's ramp after its last stop.
    static func insert(_ stops: [(offset: Double, color: Wiretuner_Doc_V1_ColorRef)], node: OpID, owner: StackOwner, row: AppearanceRow,
                       state: EngineState, builder: inout ChangeBuilder) throws {
        let sequence = self.stops(owner, row)
        let last = state.liveElements(node, sequence).last.flatMap { state.position(node, sequence, $0) }
        let keys = try PathEditing.keys(between: last, and: nil, count: stops.count)
        var gradient = Wiretuner_Doc_V1_GradientFill()
        gradient.stops = stops.map { stop in
            var value = Wiretuner_Doc_V1_GradientStop()
            value.offset = min(max(stop.offset, 0), 1)
            value.color = stop.color
            return value
        }
        builder.append(Ops.elementInsert(node, sequence, positions: keys, values: values(owner, gradient)))
    }

    /// The stop `stop` of the ramp, or throws.
    static func stop(_ stop: OpID, in entry: AttributeEntry) throws -> (index: Int, ramp: [GradientRampStop]) {
        let ramp = GradientReading.ramp(entry.fill.settings.gradient)
        guard let index = ramp.firstIndex(where: { $0.id == stop }) else { throw PathEditError.unknownPoint(stop) }
        return (index, ramp)
    }

    /// The colour a new gradient starts from: the fill's current colour, else black.
    static func startColor(_ entry: AttributeEntry) -> Wiretuner_Doc_V1_ColorRef {
        AttributeFields.color(entry).flatMap { $0.ref == nil ? nil : $0 } ?? ColorResolver.inline(.black)
    }
}

/// Choosing *Gradient* from the *Fill type* pop-up (gradients.adoc, "Applying a gradient"): the
/// `kind` register and, when the fill's gradient has no stops yet, a two-stop ramp from the
/// fill's current colour to white with the type written -- so it draws a gradient the moment it
/// is chosen.  A gradient chosen before keeps its ramp.  Labelled "Change fill type".
public struct ChooseGradient: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var type: Wiretuner_Doc_V1_GradientType

    public init(_ rows: [(node: OpID, row: AppearanceRow)], type: Wiretuner_Doc_V1_GradientType = .linear) {
        self.rows = rows
        self.type = type
    }

    public var label: String { fannedLabel("Change fill type", count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let (owner, entry) = try GradientEditing.fill(node, row, in: state)
            let base = GradientEditing.settings(owner, row)
            var gradient = Wiretuner_Doc_V1_GradientFill()
            var fields = [AttributeFields.kind]
            let fresh = entry.fill.settings.gradient.stops.isEmpty
            if fresh {
                gradient.type = type
                fields.append(GradientFields.type)
            }
            builder.append(Ops.set(node, fields.map { base.appending($0) }, values: GradientEditing.values(owner, gradient, kind: .gradient)))
            if fresh {
                try GradientEditing.insert([(0, GradientEditing.startColor(entry)), (1, ColorResolver.inline(.white))], node: node, owner: owner,
                                           row: row, state: state, builder: &builder)
            }
        }
    }
}

/// The gradient form's *Gradient type*, *Behavior* and *Count*, and the handles (`axis`): the
/// named registers of each row's gradient.  An axis drag writes `axis` on every mouse move; the
/// window groups the drag into one undo step (APP-011) and the outbox keeps the last write.
public struct EditGradient: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var fields: [[UInt32]]
    public var gradient: Wiretuner_Doc_V1_GradientFill
    public var baseLabel: String

    public init(_ rows: [(node: OpID, row: AppearanceRow)], label: String, fields: [[UInt32]], _ build: (inout Wiretuner_Doc_V1_GradientFill) -> Void) {
        self.rows = rows
        self.baseLabel = label
        self.fields = fields
        var gradient = Wiretuner_Doc_V1_GradientFill()
        build(&gradient)
        self.gradient = gradient
    }

    public static func type(_ rows: [(node: OpID, row: AppearanceRow)], _ type: Wiretuner_Doc_V1_GradientType) -> EditGradient {
        EditGradient(rows, label: "Change gradient type", fields: [GradientFields.type]) { $0.type = type }
    }

    public static func behavior(_ rows: [(node: OpID, row: AppearanceRow)], _ behavior: Wiretuner_Doc_V1_GradientBehavior) -> EditGradient {
        EditGradient(rows, label: "Change gradient behavior", fields: [GradientFields.behavior]) { $0.behavior = behavior }
    }

    /// *Count*, 1 ... 100.
    public static func count(_ rows: [(node: OpID, row: AppearanceRow)], _ count: Int) -> EditGradient {
        EditGradient(rows, label: "Change gradient count", fields: [GradientFields.repeatCount]) { $0.repeatCount = UInt32(clamping: count) }
    }

    /// The handles: one ATOMIC `axis` value (`end2` for Radial and Rectangle only).
    public static func axis(_ rows: [(node: OpID, row: AppearanceRow)], start: Point, end: Point, end2: Point? = nil) -> EditGradient {
        EditGradient(rows, label: "Move gradient handle", fields: [GradientFields.axis]) { gradient in
            gradient.axis.start = PathEditing.proto(start)
            gradient.axis.end = PathEditing.proto(end)
            if let end2 { gradient.axis.end2 = PathEditing.proto(end2) }
        }
    }

    public var label: String { fannedLabel(baseLabel, count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        if fields.contains(GradientFields.repeatCount), !(1...100).contains(gradient.repeatCount) { throw ObjectEditError.invalidValue("count") }
        guard !fields.contains(GradientFields.stops) else { throw ObjectEditError.invalidValue("stops") }
        for (node, row) in rows {
            let (owner, _) = try GradientEditing.fill(node, row, in: state)
            let base = GradientEditing.settings(owner, row)
            builder.append(Ops.set(node, fields.map { base.appending($0) }, values: GradientEditing.values(owner, gradient)))
        }
    }
}

/// Dropping a colour on the ramp (gradients.adoc, "To add a color"): a new stop at `offset`.
/// Labelled "Add color stop".
public struct AddGradientStop: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var offset: Double
    public var color: Wiretuner_Doc_V1_ColorRef

    public init(node: OpID, row: AppearanceRow, offset: Double, color: Wiretuner_Doc_V1_ColorRef) {
        self.node = node
        self.row = row
        self.offset = offset
        self.color = color
    }

    public var label: String { "Add color stop" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard offset.isFinite else { throw ObjectEditError.invalidValue("offset") }
        let (owner, _) = try GradientEditing.fill(node, row, in: state)
        try GradientEditing.insert([(offset, color)], node: node, owner: owner, row: row, state: state, builder: &builder)
    }
}

/// Dragging a stop along the ramp: its `offset`.  Dragging an end stop inward leaves a copy of it
/// at the end in the same change, so the ramp always has two ends.  Labelled "Move color stop".
public struct MoveGradientStop: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var stop: OpID
    public var offset: Double

    public init(node: OpID, row: AppearanceRow, stop: OpID, offset: Double) {
        self.node = node
        self.row = row
        self.stop = stop
        self.offset = offset
    }

    public var label: String { "Move color stop" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard offset.isFinite else { throw ObjectEditError.invalidValue("offset") }
        let (owner, entry) = try GradientEditing.fill(node, row, in: state)
        let (index, ramp) = try GradientEditing.stop(stop, in: entry)
        let target = min(max(offset, 0), 1)
        let current = ramp[index]
        guard target != current.offset else { return }
        var stopValue = Wiretuner_Doc_V1_GradientStop()
        stopValue.offset = target
        var gradient = Wiretuner_Doc_V1_GradientFill()
        gradient.stops = [stopValue]
        let path = GradientEditing.stops(owner, row).element(stop).child(GradientFields.stopOffset)
        builder.append(Ops.set(node, [path], values: GradientEditing.values(owner, gradient)))
        let isEnd = (index == 0 && target > current.offset) || (index == ramp.count - 1 && target < current.offset)
        let covered = ramp.contains { $0.id != stop && $0.offset == current.offset }
        if isEnd, !covered {
            try GradientEditing.insert([(current.offset, current.color)], node: node, owner: owner, row: row, state: state, builder: &builder)
        }
    }
}

/// Recolouring a stop (its swatch on the ramp, a colour dropped on it): the stop's ATOMIC
/// `color`.  Labelled "Change stop color".
public struct RecolorGradientStop: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var stop: OpID
    public var color: Wiretuner_Doc_V1_ColorRef

    public init(node: OpID, row: AppearanceRow, stop: OpID, color: Wiretuner_Doc_V1_ColorRef) {
        self.node = node
        self.row = row
        self.stop = stop
        self.color = color
    }

    public var label: String { "Change stop color" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (owner, entry) = try GradientEditing.fill(node, row, in: state)
        _ = try GradientEditing.stop(stop, in: entry)
        var stopValue = Wiretuner_Doc_V1_GradientStop()
        stopValue.color = color
        var gradient = Wiretuner_Doc_V1_GradientFill()
        gradient.stops = [stopValue]
        builder.append(Ops.set(node, [GradientEditing.stops(owner, row).element(stop).child(GradientFields.stopColor)],
                               values: GradientEditing.values(owner, gradient)))
    }
}

/// kbd:[Cmd]-dragging a stop: a new stop of the same colour at `offset`.  Labelled "Copy color
/// stop".
public struct CopyGradientStop: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var stop: OpID
    public var offset: Double

    public init(node: OpID, row: AppearanceRow, stop: OpID, offset: Double) {
        self.node = node
        self.row = row
        self.stop = stop
        self.offset = offset
    }

    public var label: String { "Copy color stop" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard offset.isFinite else { throw ObjectEditError.invalidValue("offset") }
        let (owner, entry) = try GradientEditing.fill(node, row, in: state)
        let (index, ramp) = try GradientEditing.stop(stop, in: entry)
        try GradientEditing.insert([(offset, ramp[index].color)], node: node, owner: owner, row: row, state: state, builder: &builder)
    }
}

/// Dragging a stop off the ramp: an `ElementDelete`, refused for the two end stops and whenever
/// two or fewer stops are left (the command layer never removes the last two).  A concurrent
/// recolour stays on the tombstone for *Restore*.  Labelled "Remove color stop".
public struct RemoveGradientStop: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var stop: OpID

    public init(node: OpID, row: AppearanceRow, stop: OpID) {
        self.node = node
        self.row = row
        self.stop = stop
    }

    public var label: String { "Remove color stop" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (owner, entry) = try GradientEditing.fill(node, row, in: state)
        let (index, ramp) = try GradientEditing.stop(stop, in: entry)
        guard ramp.count > 2, index != 0, index != ramp.count - 1 else { throw ObjectEditError.invalidValue("stop") }
        builder.append(Ops.elementDelete(node, [GradientEditing.stops(owner, row).element(stop)]))
    }
}

/// Switching a Gradient fill to Basic (gradients.adoc: "fills the object with the ramp's
/// left-hand color"): `kind` and `basic.color` in one write; the gradient stays stored and comes
/// back on switching again.  Labelled "Change fill type".
public struct ConvertGradientToBasic: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]

    public init(_ rows: [(node: OpID, row: AppearanceRow)]) {
        self.rows = rows
    }

    public var label: String { fannedLabel("Change fill type", count: rows.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let (owner, entry) = try GradientEditing.fill(node, row, in: state)
            var settings = AttributeSettings(.fills)
            settings.fill.kind = .basic
            var fields = [AttributeFields.kind]
            if let left = GradientReading.ramp(entry.fill.settings.gradient).first {
                settings.fill.basic.color = left.color
                fields.append(AttributeFields.Basic.color)
            }
            let base = GradientEditing.settings(owner, row)
            builder.append(Ops.set(node, fields.map { base.appending($0) }, values: settings.values(owner)))
        }
    }
}

/// Applying a gradient to objects (a gradient swatch, the modifier drops of ATTR-028, a group):
/// every object in the selection, groups expanded to their members (gradients.adoc, "Applying a
/// gradient to a group applies it to every object in the group individually"), gets `gradient`
/// on its topmost fill -- kind, type, behavior, count, axis (unset: Auto size, so each object
/// fits its own bounds) and a ramp replacing the old stops -- or on a new fill when it has none.
/// Labelled "Apply gradient" or "Apply gradient to 3 objects".
public struct ApplyGradient: Command {
    public var nodes: [OpID]
    public var gradient: Wiretuner_Doc_V1_GradientFill

    public init(_ nodes: [OpID], gradient: Wiretuner_Doc_V1_GradientFill) {
        self.nodes = nodes
        self.gradient = gradient
    }

    public var label: String { nodes.count > 1 ? "Apply gradient to \(nodes.count) objects" : "Apply gradient" }

    /// The leaf objects `nodes` name, groups expanded, each once.
    static func leaves(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        var result: [OpID] = []
        var seen: Set<OpID> = []
        func visit(_ node: OpID) {
            guard seen.insert(node).inserted, state.isLive(node) else { return }
            if state.nodeKind(node) == .group {
                state.liveChildren(node).forEach(visit)
            } else if StackOwner.of(node, in: state) != nil {
                result.append(node)
            }
        }
        nodes.forEach(visit)
        return result
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let stops = GradientReading.ramp(gradient).map { (offset: $0.offset, color: $0.color) }
        guard stops.count >= 2 else { throw ObjectEditError.invalidValue("stops") }
        var registers = gradient
        registers.stops = []
        let fields = [AttributeFields.kind, GradientFields.type, GradientFields.behavior, GradientFields.repeatCount, GradientFields.axis]
        for node in Self.leaves(nodes, in: state) {
            let owner = try AppearanceEditing.owner(node, in: state)
            if let top = AppearanceEditing.stack(node, in: state).last(where: { $0.list == .fills }) {
                let sequence = GradientEditing.stops(owner, top)
                let old = state.liveElements(node, sequence).map { sequence.element($0) }
                builder.append(Ops.set(node, fields.map { GradientEditing.settings(owner, top).appending($0) },
                                       values: GradientEditing.values(owner, registers, kind: .gradient)))
                if !old.isEmpty { builder.append(Ops.elementDelete(node, old)) }
                try GradientEditing.insert(stops, node: node, owner: owner, row: top, state: state, builder: &builder)
            } else {
                // A new fill takes the registers with its insert; its stops are a sequence of
                // their own, inserted once the fill exists.
                let key = try AppearanceEditing.keyAbove(node, nil, owner: owner, state: state)
                let element = builder.append(Ops.elementInsert(node, owner.sequence(.fills), positions: [key],
                                                               values: GradientEditing.values(owner, registers, kind: .gradient)))
                let row = AppearanceRow(.fills, element)
                let keys = try PathEditing.keys(between: nil, and: nil, count: stops.count)
                var ramp = Wiretuner_Doc_V1_GradientFill()
                ramp.stops = stops.map { stop in
                    var value = Wiretuner_Doc_V1_GradientStop()
                    value.offset = stop.offset
                    value.color = stop.color
                    return value
                }
                builder.append(Ops.elementInsert(node, GradientEditing.stops(owner, row), positions: keys, values: GradientEditing.values(owner, ramp)))
            }
        }
    }
}

