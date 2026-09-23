import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

// ATTR-008: brush model commands (docs/_includes/appearance/stroke-attributes.adoc, "Brush
// strokes", "Creating a brush", "Brush reference", "Brush node fields", "Brush import").

/// How *Create Brush…* turns the selection into the brush's symbol.
public enum BrushSymbolSource: Hashable, Sendable {
    /// A symbol is added to the Library; the selected objects stay as they are.
    case copy
    /// A symbol is added and the selected objects are replaced by an instance of it.
    case convert
}

/// What happens to strokes using a brush that is removed.
public enum BrushRemoval: Hashable, Sendable {
    /// Each using object becomes a group of itself (without the brush stroke) and the stroke's
    /// copies as ordinary paths.
    case release
    /// The brush and the paths using it are deleted.
    case delete
}

/// What *Edit…* does with an edited brush that is in use.
public enum BrushEditChoice: Hashable, Sendable {
    /// The brush node's registers are written: every stroke using it changes.
    case change
    /// A new brush "Copy of <name>" with the edits, applied to these stroke rows only.
    case create(strokes: [BrushStrokeRow])
}

/// One stroke row of an object.
public struct BrushStrokeRow: Hashable, Sendable {
    public var node: OpID
    public var element: OpID

    public init(node: OpID, element: OpID) {
        self.node = node
        self.element = element
    }

    var row: AppearanceRow { AppearanceRow(.strokes, element) }
}

/// A brush's editable definition (the Edit Brush sheet): its settings and the symbols it paints,
/// bottom first.
public struct BrushDefinition: Hashable, Sendable {
    public var props: Wiretuner_Doc_V1_BrushProps
    public var symbols: [OpID]

    public init(props: Wiretuner_Doc_V1_BrushProps = BrushDefinition.defaultProps, symbols: [OpID] = []) {
        self.props = props
        self.props.symbols = []
        self.symbols = symbols
    }

    /// A new brush's settings: Spray, oriented on the path, spacing 100%, no angle, offset or
    /// scaling variation.
    public static var defaultProps: Wiretuner_Doc_V1_BrushProps {
        var props = Wiretuner_Doc_V1_BrushProps()
        props.mode = .spray
        props.count = 1
        props.orientOnPath = true
        props.spacing = variation(100)
        props.angle = variation(0)
        props.offset = variation(0)
        props.scaling = variation(100)
        return props
    }

    static func variation(_ value: Double) -> Wiretuner_Doc_V1_BrushVariation {
        var variation = Wiretuner_Doc_V1_BrushVariation()
        variation.mode = .fixed
        variation.value = value
        return variation
    }
}

/// Why a brush command was refused.
public enum BrushError: Error, Equatable, Sendable {
    case notABrush(OpID)
    /// A brush paints at least one symbol.
    case noSymbols
}

enum BrushEditing {
    /// The live brush `id`, or throws.
    static func brush(_ id: OpID, in state: EngineState) throws -> BrushEntry {
        guard Brushes.isBrush(id, in: state), let entry = Brushes.list(state).first(where: { $0.id == id }) else { throw BrushError.notABrush(id) }
        return entry
    }

    /// Creates a brush node of `definition` named `name` after `after` (at the end when nil),
    /// its symbols inserted in the same change; returns its id.
    @discardableResult
    static func create(_ definition: BrushDefinition, name: String, after: OpID?, state: EngineState, builder: inout ChangeBuilder) throws -> OpID {
        var props = definition.props
        props.common = Wiretuner_Doc_V1_CommonProps()
        props.common.name = name
        let (lo, hi) = neighbours(after, in: state)
        let position = try PathEditing.keys(between: lo, and: hi, count: 1)[0]
        let brush = builder.append(Ops.create(parent: BrushFields.collection, position: position, props: BrushFields.values(props)))
        try insertSymbols(definition.symbols, into: brush, after: nil, builder: &builder)
        return brush
    }

    /// The positions around the slot after `node` among the collection's children (after the
    /// last child when nil).
    static func neighbours(_ node: OpID?, in state: EngineState) -> ([UInt8]?, [UInt8]?) {
        let children = state.store.children(BrushFields.collection)
        let index = node.flatMap { children.firstIndex(of: $0) } ?? children.count - 1
        let position = { (at: Int) in children.indices.contains(at) ? state.store.placement(children[at])?.position : nil }
        return (position(index), position(index + 1))
    }

    static func insertSymbols(_ symbols: [OpID], into brush: OpID, after: [UInt8]?, builder: inout ChangeBuilder) throws {
        guard !symbols.isEmpty else { return }
        var props = Wiretuner_Doc_V1_BrushProps()
        props.symbols = symbols.map { symbol in
            var element = Wiretuner_Doc_V1_BrushSymbol()
            element.symbol.id = symbol.proto
            return element
        }
        let keys = try PathEditing.keys(between: after, and: nil, count: symbols.count)
        builder.append(Ops.elementInsert(brush, BrushFields.symbols, positions: keys, values: BrushFields.values(props)))
    }

    /// The live objects holding a Brush stroke that references `brush`, with those strokes.
    static func users(of brush: OpID, in state: EngineState) -> [(node: OpID, strokes: [OpID])] {
        state.store.nodes.sorted().compactMap { node in
            guard state.isEffectivelyLive(node), let appearance = NodeValues.appearance(state.props(node)) else { return nil }
            let strokes = appearance.strokes.filter { stroke in
                stroke.settings.kind == .brush && stroke.settings.brush.brush.hasID && OpID(stroke.settings.brush.brush.id) == brush
            }.compactMap { OpID(element: $0.id) }
            return strokes.isEmpty ? nil : (node, strokes)
        }
    }

    /// "Copy of <name>", unique among the brushes.
    static func copyName(_ name: String, in state: EngineState) -> String {
        let taken = Set(Brushes.list(state).map(\.name))
        return ColorText.unique("Copy of \(name)") { taken.contains($0) }
    }
}

/// menu:Modify[Brush > Create Brush…] with the sheet's btn:[OK]: a symbol of the selection --
/// a copy (*Copy*) or the objects themselves, replaced by an instance (*Convert*, as Convert to
/// Symbol does) -- tagged as a brush tip, and a brush node of `definition` painting it, in one
/// change labelled "Create Brush".
public struct CreateBrush: Command {
    public var nodes: [OpID]
    public var source: BrushSymbolSource
    public var name: String
    public var definition: BrushDefinition

    public init(_ nodes: [OpID], source: BrushSymbolSource, name: String, definition: BrushDefinition = BrushDefinition()) {
        self.nodes = nodes
        self.source = source
        self.name = name
        self.definition = definition
    }

    public var label: String { "Create Brush" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let members = Objects.stackingOrder(Objects.editable(nodes, in: state), in: state)
        guard !members.isEmpty else { throw BrushError.noSymbols }
        let symbol: OpID
        switch source {
        case .convert:
            // Convert to Symbol's first op creates the symbol (the selection is on a layer).
            symbol = OpID(counter: builder.nextCounter, replica: builder.replica)
            try ConvertToSymbol(members, name: name).execute(&builder, state: state)
        case .copy:
            symbol = try Self.copySymbol(members, state: state, builder: &builder)
        }
        var usage = Wiretuner_Doc_V1_NodeProps()
        usage.symbol.usage = .brushTip
        builder.append(Ops.set(symbol, [RegisterPath([NodeKind.symbol.rawValue, 2])], values: usage))
        var definition = self.definition
        definition.symbols = [symbol] + definition.symbols
        try BrushEditing.create(definition, name: name, after: nil, state: state, builder: &builder)
    }

    /// A symbol holding copies of `members` in pasteboard space, its origin at their centre.
    static func copySymbol(_ members: [OpID], state: EngineState, builder: inout ChangeBuilder) throws -> OpID {
        var bounds = Rect.null
        for member in members {
            if let rect = Objects.bounds(of: member, in: state) { bounds = bounds.union(rect) }
        }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.symbol.common.name = SymbolEditing.defaultName(for: members, in: state)
        props.symbol.origin = PathEditing.proto(bounds.isNull ? .zero : Point(x: bounds.midX, y: bounds.midY))
        let symbol = builder.append(Ops.create(parent: WellKnown.symbols, position: try PathEditing.topPosition(in: WellKnown.symbols, state: state), props: props))
        let keys = try PathEditing.keys(between: nil, and: nil, count: members.count)
        for (member, key) in zip(members, keys) {
            var tree = NodeTree(member, state: state)
            tree.transform = Objects.pasteboardTransform(of: member, in: state)
            try NodeCopier.create(tree, parent: symbol, position: key, schema: state.schema, builder: &builder)
        }
        return symbol
    }
}

/// The Edit Brush sheet's btn:[OK].  *Change* writes the brush node's settings (and replaces its
/// symbols when they changed), so every stroke using it follows; *Create* makes "Copy of <name>"
/// with the edits and points the given strokes at it.  Labelled "Edit Brush".
public struct EditBrush: Command {
    public var brush: OpID
    public var definition: BrushDefinition
    public var choice: BrushEditChoice

    public init(_ brush: OpID, definition: BrushDefinition, choice: BrushEditChoice = .change) {
        self.brush = brush
        self.definition = definition
        self.choice = choice
    }

    public var label: String { "Edit Brush" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let entry = try BrushEditing.brush(brush, in: state)
        guard !definition.symbols.isEmpty else { throw BrushError.noSymbols }
        switch choice {
        case .change:
            // An empty name in the sheet keeps the brush's name.
            let fields = definition.props.common.name.isEmpty ? BrushFields.settings.filter { $0 != BrushFields.name } : BrushFields.settings
            builder.append(Ops.set(brush, fields, values: BrushFields.values(definition.props)))
            guard definition.symbols != entry.symbols else { return }
            let old = state.liveElements(brush, BrushFields.symbols)
            if !old.isEmpty { builder.append(Ops.elementDelete(brush, old.map { BrushFields.symbols.element($0) })) }
            let last = old.last.flatMap { state.position(brush, BrushFields.symbols, $0) }
            try BrushEditing.insertSymbols(definition.symbols, into: brush, after: last, builder: &builder)
        case .create(let strokes):
            let name = definition.props.common.name.isEmpty || definition.props.common.name == entry.name
                ? BrushEditing.copyName(entry.name, in: state) : definition.props.common.name
            let copy = try BrushEditing.create(definition, name: name, after: brush, state: state, builder: &builder)
            try ApplyBrush(strokes, brush: copy, fresh: definition).write(&builder, state: state)
        }
    }
}

/// The action menu's *Duplicate*: "Copy of <name>" just after the brush, with its settings and
/// symbols.  Labelled "Duplicate Brush".
public struct DuplicateBrush: Command {
    public var brush: OpID

    public init(_ brush: OpID) {
        self.brush = brush
    }

    public var label: String { "Duplicate Brush" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let entry = try BrushEditing.brush(brush, in: state)
        try BrushEditing.create(BrushDefinition(props: entry.props, symbols: entry.symbols), name: BrushEditing.copyName(entry.name, in: state),
                                after: brush, state: state, builder: &builder)
    }
}

/// The action menu's *Remove…*: *Delete* deletes the brush node and every object whose stroke
/// uses it; *Release* bakes each using object's brush strokes into ordinary paths grouped with
/// the object (whose brush strokes are removed), then deletes the brush.  A stroke applying the
/// brush concurrently reads its cached Basic stroke.  Labelled "Remove Brush".
public struct RemoveBrush: Command {
    public var brush: OpID
    public var removal: BrushRemoval

    public init(_ brush: OpID, _ removal: BrushRemoval) {
        self.brush = brush
        self.removal = removal
    }

    public var label: String { "Remove Brush" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try BrushEditing.brush(brush, in: state)
        let users = BrushEditing.users(of: brush, in: state)
        switch removal {
        case .delete:
            for user in users { builder.append(Ops.setDeleted(user.node)) }
        case .release:
            guard !users.isEmpty else { break }
            var scene = DocumentDisplayListBuilder(canvas: "release")
            let built = scene.rebuild(state)
            for user in users {
                try release(user.node, strokes: user.strokes, scene: built, state: state, builder: &builder)
            }
        }
        builder.append(Ops.setDeleted(brush))
    }

    /// Groups `node` with its brush strokes baked: a group at the node's slot holding the node
    /// and, above it, the strokes' copies as paths; the brush stroke elements are removed.
    private func release(_ node: OpID, strokes: [OpID], scene: DocumentScene, state: EngineState, builder: inout ChangeBuilder) throws {
        // A user is a live, placed object with a stack.
        let parent = Objects.parent(of: node, in: state)!
        let owner = StackOwner.of(node, in: state)!
        let items = scene.object(node).map { Self.brushItems($0.item) } ?? []
        let trees = Baking.trees(items)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.group.kind = .group
        let key = try Arranging.keys(next: node, above: true, count: 1, in: state)[0]
        let group = builder.append(Ops.create(parent: parent, position: key, props: props))
        let keys = try PathEditing.keys(between: nil, and: nil, count: 2)
        builder.append(Ops.move(node, parent: group, position: keys[0]))
        builder.append(Ops.elementDelete(node, strokes.map { owner.sequence(.strokes).element($0) }))
        // The baked copies are in pasteboard space: their group maps them into the new group's.
        var baked = Wiretuner_Doc_V1_NodeProps()
        baked.group.kind = .group
        let toGroup = Objects.pasteboardTransform(ofSpace: parent, in: state).inverse
        if !toGroup.isIdentity { baked.group.common.transform = PathEditing.proto(toGroup) }
        try NodeCopier.create(NodeTree(props: baked, children: trees), parent: group, position: keys[1], schema: state.schema, builder: &builder)
    }

    /// Only the brush strokes of an object's item (every other fill and stroke dropped).
    static func brushItems(_ item: DisplayItem) -> [DisplayItem] {
        switch item {
        case .path(var path):
            path.appearance = Appearance(path.appearance.items.filter { element in
                if case .stroke(let stroke) = element, case .brush = stroke.kind { return true }
                return false
            })
            return path.appearance.items.isEmpty ? [] : [.path(path)]
        case .group(let group):
            return group.children.flatMap(brushItems)
        default:
            return []
        }
    }
}

/// Choosing a brush from the brush pop-up: each stroke row becomes a Brush stroke referencing
/// `brush` with its cached Basic stroke (the row's current colour and width, drawn if the brush
/// goes), its colour, width 100% unless set, and a seed of its own if it has none.  Labelled
/// "Apply Brush".
public struct ApplyBrush: Command {
    public var strokes: [BrushStrokeRow]
    public var brush: OpID
    /// Set when the brush is created in the same change (it is not in the state yet).
    var fresh: BrushDefinition?

    public init(_ strokes: [BrushStrokeRow], brush: OpID) {
        self.strokes = strokes
        self.brush = brush
    }

    init(_ strokes: [BrushStrokeRow], brush: OpID, fresh: BrushDefinition) {
        self.strokes = strokes
        self.brush = brush
        self.fresh = fresh
    }

    public var label: String { fannedLabel("Apply Brush", count: strokes.count) }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try BrushEditing.brush(brush, in: state)
        try write(&builder, state: state)
    }

    func write(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for (index, stroke) in strokes.enumerated() {
            let owner = try AppearanceEditing.owner(stroke.node, stroke.row, in: state)
            let entry = AttributeEntry.read(stroke.node, stroke.row, owner: owner, state: state)
            var settings = AttributeSettings(.strokes)
            settings.stroke.kind = .brush
            var cached = Wiretuner_Doc_V1_BasicStroke()
            cached.color = AttributeFields.color(entry).flatMap { $0.ref == nil ? nil : $0 } ?? ColorResolver.inline(.black)
            cached.width = max(AttributeFields.width(entry) ?? 1, 0)
            settings.stroke.brush.brush.id = brush.proto
            settings.stroke.brush.brush.cached = try cached.serializedData()
            settings.stroke.brush.color = cached.color
            var fields = [AttributeFields.kind, AttributeFields.Brush.brush, AttributeFields.Brush.color]
            let current = entry.stroke.settings.brush
            if current.widthPercent == 0 {
                settings.stroke.brush.widthPercent = 100
                fields.append(AttributeFields.Brush.widthPercent)
            }
            if current.seed == 0 {
                settings.stroke.brush.seed = Seeds.next(builder, salt: UInt64(index))
                fields.append(AttributeFields.Brush.seed)
            }
            let base = owner.sequence(.strokes).element(stroke.element).child(AppearanceList.strokes.settingsField)
            builder.append(Ops.set(stroke.node, fields.map { base.appending($0) }, values: settings.values(owner)))
        }
    }
}

/// The action menu's *Import…* after picking brushes in a brush file (another document's
/// state): each brush copied with its settings, its live symbols copied into the Library and the
/// copies painting them -- one change labelled "Import Brushes".  Colours travel inside the
/// copied artwork (references to the file's swatches read their cached colours); the file's
/// swatches are not added.
public struct ImportBrushes: Command {
    public var source: EngineState
    public var brushes: [OpID]

    public init(from source: EngineState, brushes: [OpID]) {
        self.source = source
        self.brushes = brushes
    }

    public var label: String { brushes.count == 1 ? "Import Brush" : "Import Brushes" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let entries = try brushes.map { try BrushEditing.brush($0, in: source) }
        var copies: [OpID: OpID] = [:]
        var lastSymbol = state.store.children(WellKnown.symbols).last.flatMap { state.store.placement($0)?.position }
        var lastBrush = state.store.children(BrushFields.collection).last.flatMap { state.store.placement($0)?.position }
        for entry in entries {
            for symbol in entry.symbols where copies[symbol] == nil {
                let key = try PathEditing.keys(between: lastSymbol, and: nil, count: 1)[0]
                lastSymbol = key
                copies[symbol] = try NodeCopier.create(NodeTree(symbol, state: source), parent: WellKnown.symbols, position: key,
                                                       schema: state.schema, builder: &builder)
            }
            var props = entry.props
            props.symbols = []
            let key = try PathEditing.keys(between: lastBrush, and: nil, count: 1)[0]
            lastBrush = key
            let brush = builder.append(Ops.create(parent: BrushFields.collection, position: key, props: BrushFields.values(props)))
            try BrushEditing.insertSymbols(entry.symbols.compactMap { copies[$0] }, into: brush, after: nil, builder: &builder)
        }
    }
}

/// *Export…*: a brush file is a document holding the chosen brushes and their symbols.
public enum BrushFile {
    /// A new document's state holding copies of `brushes` of `state` (what the app writes as a
    /// `.wiretuner` package).
    public static func document(_ brushes: [OpID], from state: EngineState, replica: UInt64 = 1) throws -> EngineState {
        var core = DocumentCore(state: EngineState(), replica: replica)
        _ = try core.perform(ImportBrushes(from: state, brushes: brushes), recording: DocumentCore.Recording(limit: 1, now: .init(timeIntervalSince1970: 0)))
        return core.state
    }
}
