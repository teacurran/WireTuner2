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

    /// The element's settings field: 3 on `Fill` and `Stroke`, 4 on `Effect` (after `attached_to`).
    var settingsField: UInt32 { self == .effects ? 4 : 3 }
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

/// Where an attribute stack lives: an object's own props, or the document's default attributes
/// on the settings node (`SettingsProps.defaults.appearance`, default-attributes.adoc), which the
/// Object panel edits with nothing selected.
enum StackOwner: Hashable, Sendable {
    case object(NodeKind)
    case defaults

    /// The owner of `node`'s stack, or nil when the node has none.
    static func of(_ node: OpID, in state: EngineState) -> StackOwner? {
        if node == WellKnown.settings { return .defaults }
        guard let kind = state.nodeKind(node), NodeValues.appearanceField(kind) != nil else { return nil }
        return .object(kind)
    }

    /// The path of the `AppearanceProps`.
    var path: RegisterPath {
        switch self {
        case .object(let kind): RegisterPath([kind.rawValue, NodeValues.appearanceField(kind)!])
        case .defaults: RegisterPath([2, 10, 1])
        }
    }

    func sequence(_ list: AppearanceList) -> RegisterPath { path.child(list.rawValue) }

    /// A sparse `NodeProps` holding `stack` at this owner's path.
    func values(_ stack: Wiretuner_Doc_V1_AppearanceProps) -> Wiretuner_Doc_V1_NodeProps {
        switch self {
        case .object(let kind):
            return NodeValues.with(kind: kind, appearanceField: NodeValues.appearanceField(kind)!, stack)
        case .defaults:
            var props = Wiretuner_Doc_V1_NodeProps()
            props.settings.defaults.appearance = stack
            return props
        }
    }

    /// The stack as stored on `node`.
    static func appearance(_ node: OpID, in state: EngineState) -> Wiretuner_Doc_V1_AppearanceProps? {
        node == WellKnown.settings ? state.props(node).settings.defaults.appearance : NodeValues.appearance(state.props(node))
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

    /// The live elements of `list` on `node` (an object, or the settings node's defaults), bottom
    /// first.
    public static func rows(_ node: OpID, _ list: AppearanceList, in state: EngineState) -> [OpID] {
        guard let owner = StackOwner.of(node, in: state) else { return [] }
        return state.liveElements(node, owner.sequence(list))
    }

    /// Every live row of `node`'s stack, bottom first: the three lists share one position space,
    /// so the stack is their elements sorted by position, then element id
    /// (attribute-stack.adoc, "Data model").
    public static func stack(_ node: OpID, in state: EngineState) -> [AppearanceRow] {
        guard let owner = StackOwner.of(node, in: state) else { return [] }
        var keyed: [(position: [UInt8], row: AppearanceRow)] = []
        for list in AppearanceList.allCases {
            let path = owner.sequence(list)
            for id in state.liveElements(node, path) {
                keyed.append((state.position(node, path, id) ?? [], AppearanceRow(list, id)))
            }
        }
        return keyed.sorted { a, b in
            if a.position != b.position { return FractionalIndex.less(a.position, b.position) }
            if a.row.element != b.row.element { return a.row.element < b.row.element }
            return a.row.list.rawValue < b.row.list.rawValue
        }.map(\.row)
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

    /// A sparse `NodeProps` for `owner` whose stack `build` fills.
    static func values(_ owner: StackOwner, _ build: (inout Wiretuner_Doc_V1_AppearanceProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var stack = Wiretuner_Doc_V1_AppearanceProps()
        build(&stack)
        return owner.values(stack)
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

    /// The owner of `node`'s stack -- a live object, or the settings node -- or throws.
    static func owner(_ node: OpID, in state: EngineState) throws -> StackOwner {
        if node == WellKnown.settings { return .defaults }
        let kind = try Objects.kind(node, in: state)
        guard NodeValues.appearanceField(kind) != nil else { throw ObjectEditError.notAnObject(node) }
        return .object(kind)
    }

    /// The owner of `node`'s stack when `row` is one of its live rows, or throws.
    static func owner(_ node: OpID, _ row: AppearanceRow, in state: EngineState) throws -> StackOwner {
        let owner = try owner(node, in: state)
        guard state.liveElements(node, owner.sequence(row.list)).contains(row.element) else { throw PathEditError.unknownPoint(row.element) }
        return owner
    }

    /// The element `row` of `node` as a typed value, for copying.
    static func element(_ node: OpID, _ row: AppearanceRow, in state: EngineState) -> Wiretuner_Doc_V1_NodeProps? {
        guard let owner = StackOwner.of(node, in: state), let appearance = StackOwner.appearance(node, in: state) else { return nil }
        switch row.list {
        case .fills:
            guard let fill = appearance.fills.first(where: { OpID(element: $0.id) == row.element }) else { return nil }
            return values(owner) { $0.fills = [fill] }
        case .strokes:
            guard let stroke = appearance.strokes.first(where: { OpID(element: $0.id) == row.element }) else { return nil }
            return values(owner) { $0.strokes = [stroke] }
        case .effects:
            guard let effect = appearance.effects.first(where: { OpID(element: $0.id) == row.element }) else { return nil }
            return values(owner) { $0.effects = [effect] }
        }
    }

    /// The position of `row` in `node`'s stack.
    static func position(_ node: OpID, _ row: AppearanceRow, owner: StackOwner, state: EngineState) -> [UInt8]? {
        state.position(node, owner.sequence(row.list), row.element)
    }

    /// A key directly above `row` in the merged stack, whatever list the neighbour above belongs
    /// to (or at the top of the stack when `row` is nil or not in it).
    static func keyAbove(_ node: OpID, _ row: AppearanceRow?, owner: StackOwner, state: EngineState) throws -> [UInt8] {
        let order = stack(node, in: state)
        let key: (AppearanceRow) -> [UInt8]? = { position(node, $0, owner: owner, state: state) }
        if let row, let index = order.firstIndex(of: row) {
            return try PathEditing.keys(between: key(row), and: index + 1 < order.count ? key(order[index + 1]) : nil, count: 1)[0]
        }
        return try PathEditing.keys(between: order.last.flatMap(key), and: nil, count: 1)[0]
    }

    /// A key that places an element at `index` (0 = bottom) of `node`'s stack once `moving` (the
    /// element being moved, if any) is taken out of it.
    static func key(at index: Int, of node: OpID, moving: AppearanceRow?, owner: StackOwner, state: EngineState) throws -> [UInt8] {
        let order = stack(node, in: state).filter { $0 != moving }
        let target = min(max(index, 0), order.count)
        let key: (AppearanceRow) -> [UInt8]? = { position(node, $0, owner: owner, state: state) }
        let lo = target > 0 ? key(order[target - 1]) : nil
        let hi = target < order.count ? key(order[target]) : nil
        return try PathEditing.keys(between: lo, and: hi, count: 1)[0]
    }
}

/// Adds a fill, stroke or effect above the selected row (OBJ-004, object-panel.adoc; ATTR-002):
/// an `ElementInsert` into the matching list of each node -- directly above `above` in the merged
/// stack, whichever list that row belongs to, otherwise at the top of the stack.  btn:[Add Stroke]
/// adds a 1 pt black basic stroke, btn:[Add Fill] a black basic fill.  The settings node takes
/// the command too: it edits the document's default attributes.
public struct AddAppearance: Command {
    public var nodes: [OpID]
    public var list: AppearanceList
    public var above: AppearanceRow?
    /// Per node, the row to insert above (the matching row of a multi-object selection);
    /// overrides `above`.
    public var aboveRows: [OpID: AppearanceRow] = [:]
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
            let owner = try AppearanceEditing.owner(node, in: state)
            let key = try AppearanceEditing.keyAbove(node, aboveRows[node] ?? above, owner: owner, state: state)
            let values = AppearanceEditing.values(owner) { stack in
                if let fill { stack.fills = [fill] }
                if let stroke { stack.strokes = [stroke] }
                if let effect { stack.effects = [effect] }
            }
            builder.append(Ops.elementInsert(node, owner.sequence(list), positions: [key], values: values))
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
        let owner = try AppearanceEditing.owner(node, row, in: state)
        builder.append(Ops.elementDelete(node, [owner.sequence(row.list).element(row.element)]))
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
        let owner = try AppearanceEditing.owner(node, in: state)
        let path = owner.sequence(row.list)
        var rows = state.liveElements(node, path)
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

/// Duplicates a row: every register of the element copied under a fresh element id, directly
/// above itself, or at `index` of the merged stack (0 = bottom) for an kbd:[Option]-drag.
public struct DuplicateAppearance: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var index: Int?

    public init(node: OpID, row: AppearanceRow, at index: Int? = nil) {
        self.node = node
        self.row = row
        self.index = index
    }

    public var label: String { "Duplicate \(row.list.noun)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let owner = try AppearanceEditing.owner(node, in: state)
        guard let values = AppearanceEditing.element(node, row, in: state) else { throw PathEditError.unknownPoint(row.element) }
        let key = try index.map { try AppearanceEditing.key(at: $0, of: node, moving: nil, owner: owner, state: state) }
            ?? AppearanceEditing.keyAbove(node, row, owner: owner, state: state)
        builder.append(Ops.elementInsert(node, owner.sequence(row.list), positions: [key], values: values))
    }
}

/// Sets the colour of fill or stroke rows on each node (the Object panel's colour well fanned out
/// over a mixed selection, or a colour dropped on a row): one register each, the colour of the
/// row's live kind -- `basic.color` for a Basic fill, `pattern.color` for a Pattern stroke and so
/// on.  A kind without a colour (Tiled, Gradient) is left alone.
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
            guard row.list != .effects else { throw PathEditError.unknownPoint(row.element) }
            let owner = try AppearanceEditing.owner(node, row, in: state)
            let entry = AttributeEntry.read(node, row, owner: owner, state: state)
            guard let field = AttributeFields.colorPath(entry) else { continue }
            var settings = AttributeSettings(row.list)
            settings.setColor(color, at: field)
            let path = owner.sequence(row.list).element(row.element).child(3)
            builder.append(Ops.set(node, [path.appending(field)], values: settings.values(owner)))
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
            let owner = try AppearanceEditing.owner(node, AppearanceRow(.strokes, element), in: state)
            var stroke = Wiretuner_Doc_V1_Stroke()
            stroke.settings.basic.width = Measure.rounded(width)
            let path = owner.sequence(.strokes).element(element).child(3).child(2).child(2)
            builder.append(Ops.set(node, [path], values: AppearanceEditing.values(owner) { $0.strokes = [stroke] }))
        }
    }
}
