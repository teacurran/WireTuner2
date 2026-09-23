import WTCRDT
import WTProto

/// Which list of an attribute stack a row belongs to (`AppearanceProps` fields 1-3).
public enum AppearanceList: UInt32, Sendable, Hashable, CaseIterable {
    case fills = 1
    case strokes = 2
    case effects = 3

    var noun: String {
        switch self {
        case .fills: "Fill"
        case .strokes: "Stroke"
        case .effects: "Effect"
        }
    }
}

/// One row of an object's attribute stack: a fill, stroke or effect element.
public struct AppearanceRow: Hashable, Sendable {
    public var list: AppearanceList
    public var element: OpID

    public init(_ list: AppearanceList, _ element: OpID) {
        self.list = list
        self.element = element
    }
}

/// Register paths and reading of attribute stacks.
public enum AppearanceEditing {
    /// The path of the node's `AppearanceProps`.
    static func stackPath(_ kind: NodeKind) -> RegisterPath? {
        NodeValues.appearanceField(kind).map { RegisterPath([kind.rawValue, $0]) }
    }

    /// The SEQUENCE of `list` on a node of `kind`.
    public static func sequence(_ kind: NodeKind, _ list: AppearanceList) -> RegisterPath? {
        stackPath(kind)?.child(list.rawValue)
    }

    /// The live elements of `list` on `node`, bottom first.
    public static func rows(_ node: OpID, _ list: AppearanceList, in state: EngineState) -> [OpID] {
        guard let kind = state.nodeKind(node), let path = sequence(kind, list) else { return [] }
        return state.liveElements(node, path)
    }

    /// A basic stroke element's width register.
    public static func strokeWidth(_ kind: NodeKind, _ element: OpID) -> RegisterPath? {
        sequence(kind, .strokes)?.element(element).child(3).child(2).child(2)
    }

    /// A basic fill's or stroke's colour register.
    public static func color(_ kind: NodeKind, _ row: AppearanceRow) -> RegisterPath? {
        guard row.list != .effects else { return nil }
        return sequence(kind, row.list)?.element(row.element).child(3).child(2).child(1)
    }

    /// A sparse `NodeProps` of `kind` whose stack `build` fills.
    static func values(_ kind: NodeKind, _ build: (inout Wiretuner_Doc_V1_AppearanceProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var stack = Wiretuner_Doc_V1_AppearanceProps()
        build(&stack)
        return NodeValues.with(kind: kind, appearanceField: NodeValues.appearanceField(kind) ?? 0, stack)
    }

    /// Writes of every basic stroke width on `node` multiplied by `factor` (a transform with
    /// *Strokes* on).
    static func scaleStrokeWidths(_ node: OpID, kind: NodeKind, by factor: Double, state: EngineState) -> [Wiretuner_Doc_V1_Op] {
        guard let appearance = NodeValues.appearance(state.props(node)) else { return [] }
        return appearance.strokes.compactMap { stroke in
            guard stroke.settings.kind == .basic, let id = OpID(element: stroke.id), let path = strokeWidth(kind, id) else { return nil }
            var value = stroke
            value.settings.basic.width = stroke.settings.basic.width * factor
            return Ops.set(node, [path], values: values(kind) { $0.strokes = [value] })
        }
    }

    /// The node's kind when it has an attribute stack, or throws.
    static func stackKind(_ node: OpID, in state: EngineState) throws -> NodeKind {
        let kind = try Objects.kind(node, in: state)
        guard NodeValues.appearanceField(kind) != nil else { throw ObjectEditError.notAnObject(node) }
        return kind
    }

    /// The element `row` of `node` as a typed value, for copying.
    static func element(_ node: OpID, _ row: AppearanceRow, in state: EngineState) -> Wiretuner_Doc_V1_NodeProps? {
        guard let kind = state.nodeKind(node), let appearance = NodeValues.appearance(state.props(node)) else { return nil }
        switch row.list {
        case .fills:
            guard let fill = appearance.fills.first(where: { OpID(element: $0.id) == row.element }) else { return nil }
            return values(kind) { $0.fills = [fill] }
        case .strokes:
            guard let stroke = appearance.strokes.first(where: { OpID(element: $0.id) == row.element }) else { return nil }
            return values(kind) { $0.strokes = [stroke] }
        case .effects:
            guard let effect = appearance.effects.first(where: { OpID(element: $0.id) == row.element }) else { return nil }
            return values(kind) { $0.effects = [effect] }
        }
    }

    /// A key directly above `row` in its list (or at the top when nil or unknown).
    static func keyAbove(_ node: OpID, _ list: AppearanceList, _ row: OpID?, kind: NodeKind, state: EngineState) throws -> [UInt8] {
        let path = sequence(kind, list)!
        let order = state.store.elementOrder(node, path)
        let key: (OpID) -> [UInt8]? = { state.position(node, path, $0) }
        if let row, let index = order.firstIndex(of: row) {
            return try PathEditing.keys(between: key(row), and: index + 1 < order.count ? key(order[index + 1]) : nil, count: 1)[0]
        }
        return try PathEditing.keys(between: order.last.flatMap(key), and: nil, count: 1)[0]
    }
}

/// Adds a fill, stroke or effect above the selected row (OBJ-004, object-panel.adoc): an
/// `ElementInsert` into the matching list of each node -- directly above `above` when that row is
/// in the same list, otherwise at the top of the list.  btn:[Add Stroke] adds a 1 pt black basic
/// stroke, btn:[Add Fill] a black basic fill.
public struct AddAppearance: Command {
    public var nodes: [OpID]
    public var list: AppearanceList
    public var above: AppearanceRow?
    /// The element added (fill, stroke or effect as sparse props of its list; built by the
    /// initialisers).
    private var fill: Wiretuner_Doc_V1_Fill?
    private var stroke: Wiretuner_Doc_V1_Stroke?
    private var effect: Wiretuner_Doc_V1_Effect?

    public static func fill(_ nodes: [OpID], above: AppearanceRow? = nil,
                            _ value: Wiretuner_Doc_V1_Fill = Appearances.basicFill(red: 0, green: 0, blue: 0)) -> AddAppearance {
        var command = AddAppearance(nodes: nodes, list: .fills, above: above)
        command.fill = value
        return command
    }

    public static func stroke(_ nodes: [OpID], above: AppearanceRow? = nil,
                              _ value: Wiretuner_Doc_V1_Stroke = Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)) -> AddAppearance {
        var command = AddAppearance(nodes: nodes, list: .strokes, above: above)
        command.stroke = value
        return command
    }

    public static func effect(_ nodes: [OpID], above: AppearanceRow? = nil, _ value: Wiretuner_Doc_V1_Effect) -> AddAppearance {
        var command = AddAppearance(nodes: nodes, list: .effects, above: above)
        command.effect = value
        return command
    }

    private init(nodes: [OpID], list: AppearanceList, above: AppearanceRow?) {
        self.nodes = nodes
        self.list = list
        self.above = above
    }

    public var label: String { "Add \(list.noun)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in nodes {
            let kind = try AppearanceEditing.stackKind(node, in: state)
            let row = above?.list == list ? above?.element : nil
            let key = try AppearanceEditing.keyAbove(node, list, row, kind: kind, state: state)
            let values = AppearanceEditing.values(kind) { stack in
                if let fill { stack.fills = [fill] }
                if let stroke { stack.strokes = [stroke] }
                if let effect { stack.effects = [effect] }
            }
            builder.append(Ops.elementInsert(node, AppearanceEditing.sequence(kind, list)!, positions: [key], values: values))
        }
    }
}

/// Removes a row (btn:[Remove]): an `ElementDelete`; a concurrent edit of the row stays on the
/// tombstone.
public struct RemoveAppearance: Command {
    public var node: OpID
    public var row: AppearanceRow

    public init(node: OpID, row: AppearanceRow) {
        self.node = node
        self.row = row
    }

    public var label: String { "Remove \(row.list.noun)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let kind = try AppearanceEditing.stackKind(node, in: state)
        guard AppearanceEditing.rows(node, row.list, in: state).contains(row.element) else { throw PathEditError.unknownPoint(row.element) }
        builder.append(Ops.elementDelete(node, [AppearanceEditing.sequence(kind, row.list)!.element(row.element)]))
    }
}

/// Moves a row to `index` in its list (0 = bottom), dragging rows in the properties list: an
/// `ElementMove`, so a concurrent recolour of the row survives.
public struct MoveAppearance: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var index: Int

    public init(node: OpID, row: AppearanceRow, to index: Int) {
        self.node = node
        self.row = row
        self.index = index
    }

    public var label: String { "Move \(row.list.noun)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let kind = try AppearanceEditing.stackKind(node, in: state)
        let path = AppearanceEditing.sequence(kind, row.list)!
        var rows = AppearanceEditing.rows(node, row.list, in: state)
        guard let current = rows.firstIndex(of: row.element) else { throw PathEditError.unknownPoint(row.element) }
        rows.remove(at: current)
        let target = min(max(index, 0), rows.count)
        guard target != current else { return }
        let key: (OpID) -> [UInt8]? = { state.position(node, path, $0) }
        let lo = target > 0 ? key(rows[target - 1]) : nil
        let hi = target < rows.count ? key(rows[target]) : nil
        let position = try PathEditing.keys(between: lo, and: hi, count: 1)[0]
        builder.append(Ops.elementMove(node, path.element(row.element), position: position))
    }
}

/// Duplicates a row directly above itself: every register of the element copied under a fresh
/// element id.
public struct DuplicateAppearance: Command {
    public var node: OpID
    public var row: AppearanceRow

    public init(node: OpID, row: AppearanceRow) {
        self.node = node
        self.row = row
    }

    public var label: String { "Duplicate \(row.list.noun)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let kind = try AppearanceEditing.stackKind(node, in: state)
        guard let values = AppearanceEditing.element(node, row, in: state) else { throw PathEditError.unknownPoint(row.element) }
        let key = try AppearanceEditing.keyAbove(node, row.list, row.element, kind: kind, state: state)
        builder.append(Ops.elementInsert(node, AppearanceEditing.sequence(kind, row.list)!, positions: [key], values: values))
    }
}

/// Sets the colour of a basic fill or stroke row on each node (one register each; the Object panel's
/// colour well, fanned out over a mixed selection).
public struct SetAppearanceColor: Command {
    public var rows: [(node: OpID, row: AppearanceRow)]
    public var color: Wiretuner_Doc_V1_ColorRef

    public init(_ rows: [(node: OpID, row: AppearanceRow)], color: Wiretuner_Doc_V1_ColorRef) {
        self.rows = rows
        self.color = color
    }

    public var label: String {
        let noun = rows.first?.row.list.noun.lowercased() ?? "fill"
        return rows.count > 1 ? "Change \(noun) color of \(rows.count) objects" : "Change \(noun) color"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (node, row) in rows {
            let kind = try AppearanceEditing.stackKind(node, in: state)
            guard let path = AppearanceEditing.color(kind, row), AppearanceEditing.rows(node, row.list, in: state).contains(row.element) else {
                throw PathEditError.unknownPoint(row.element)
            }
            let values = AppearanceEditing.values(kind) { stack in
                if row.list == .fills {
                    var fill = Wiretuner_Doc_V1_Fill()
                    fill.settings.basic.color = color
                    stack.fills = [fill]
                } else {
                    var stroke = Wiretuner_Doc_V1_Stroke()
                    stroke.settings.basic.color = color
                    stack.strokes = [stroke]
                }
            }
            builder.append(Ops.set(node, [path], values: values))
        }
    }
}

/// Sets the width of basic stroke rows (one register each).
public struct SetStrokeWidth: Command {
    public var rows: [(node: OpID, element: OpID)]
    public var width: Double

    public init(_ rows: [(node: OpID, element: OpID)], width: Double) {
        self.rows = rows
        self.width = width
    }

    public var label: String { rows.count > 1 ? "Change stroke width of \(rows.count) objects" : "Change stroke width" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard width >= 0, width.isFinite else { throw ObjectEditError.invalidValue("width") }
        for (node, element) in rows {
            let kind = try AppearanceEditing.stackKind(node, in: state)
            guard AppearanceEditing.rows(node, .strokes, in: state).contains(element) else { throw PathEditError.unknownPoint(element) }
            var stroke = Wiretuner_Doc_V1_Stroke()
            stroke.settings.basic.width = Measure.rounded(width)
            builder.append(Ops.set(node, [AppearanceEditing.strokeWidth(kind, element)!], values: AppearanceEditing.values(kind) { $0.strokes = [stroke] }))
        }
    }
}
