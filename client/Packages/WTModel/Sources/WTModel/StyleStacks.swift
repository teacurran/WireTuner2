import WTCRDT
import WTProto

// Attribute stacks as the graphic style commands (LIB-019) and the scene (StyleAppearance) read
// and write them (styles.adoc, "Resolution (read-time)", "Merge semantics").  A stack is carried
// as `AttributePayload.Element`s, bottom first, in *canonical* form: each element's `id` is its
// place (counter = index + 1, replica 0) and an effect's `attached_to` the place of its element,
// so stacks gathered from several nodes -- an object's overrides over its style's chain over the
// document defaults -- compare and write alike.

/// Where an attribute stack is stored: an object's stack, a graphic style's `appearance`, or the
/// document's default attributes on the settings node.
enum StackHost: Hashable, Sendable {
    case object(OpID, NodeKind)
    case style(OpID)
    case defaults

    /// The stack of `node` when it has one (an object of a kind with a stack, the settings
    /// node).  A style's is `.style(id)`.
    static func of(_ node: OpID, in state: EngineState) -> StackHost? {
        if node == WellKnown.settings { return .defaults }
        guard let kind = state.nodeKind(node), NodeValues.appearanceField(kind) != nil else { return nil }
        return .object(node, kind)
    }

    var node: OpID {
        switch self {
        case .object(let node, _), .style(let node): node
        case .defaults: WellKnown.settings
        }
    }

    /// The register path of the `AppearanceProps`.
    var path: RegisterPath {
        switch self {
        case .object(_, let kind): RegisterPath([kind.rawValue, NodeValues.appearanceField(kind)!])
        case .style: RegisterPath([GraphicStyleResolver.styleKind, 6])
        case .defaults: RegisterPath([2, 10, 1])
        }
    }

    func sequence(_ list: AppearanceList) -> RegisterPath { path.child(list.rawValue) }

    /// A sparse `NodeProps` holding `stack` at this host's path.
    func values(_ stack: Wiretuner_Doc_V1_AppearanceProps) -> Wiretuner_Doc_V1_NodeProps {
        switch self {
        case .object(_, let kind):
            return NodeValues.with(kind: kind, appearanceField: NodeValues.appearanceField(kind)!, stack)
        case .style:
            var props = Wiretuner_Doc_V1_NodeProps()
            props.style.appearance = stack
            return props
        case .defaults:
            var props = Wiretuner_Doc_V1_NodeProps()
            props.settings.defaults.appearance = stack
            return props
        }
    }

    /// Encloses the encoding of an `AppearanceProps` into a whole `NodeProps`.
    func wrap(_ appearance: [UInt8]) -> [UInt8] {
        path.fields.reversed().reduce(appearance) { Wire.field($1, $0) }
    }

    /// The stack as stored in `props` (the host node's properties).
    func appearance(in props: Wiretuner_Doc_V1_NodeProps) -> Wiretuner_Doc_V1_AppearanceProps {
        switch self {
        case .object: NodeValues.appearance(props)!
        case .style: props.style.appearance
        case .defaults: props.settings.defaults.appearance
        }
    }
}

/// One live element of a stored stack: its row (list and element id) and its value.
struct StackEntry: Hashable, Sendable {
    var row: AppearanceRow
    var element: AttributePayload.Element
}

/// Reading, composing, comparing and writing stacks.
enum StyleStacks {
    static let appearanceType = "wiretuner.doc.v1.AppearanceProps"

    /// The category a list belongs to.
    static func category(_ list: AppearanceList) -> StyleCategory {
        switch list {
        case .fills: .fills
        case .strokes: .strokes
        case .effects: .effects
        }
    }

    /// The list of a stack category (nil for halftone, which is not a stack).
    static func list(_ category: StyleCategory) -> AppearanceList? {
        switch category {
        case .fills: .fills
        case .strokes: .strokes
        case .effects: .effects
        case .halftone: nil
        }
    }

    // MARK: Reading

    /// The live elements of `host`, bottom first (the three lists share one position space: by
    /// position, then element id).  Values come from `props` when given (the scene's completed
    /// properties), else from the merged state.
    static func entries(_ host: StackHost, props: Wiretuner_Doc_V1_NodeProps? = nil, in state: EngineState) -> [StackEntry] {
        let appearance = host.appearance(in: props ?? state.props(host.node))
        var keyed: [(position: [UInt8], entry: StackEntry)] = []
        for list in AppearanceList.allCases {
            let path = host.sequence(list)
            let values: [OpID: AttributePayload.Element]
            switch list {
            case .fills: values = elements(appearance.fills.map { ($0.id, .fill($0)) })
            case .strokes: values = elements(appearance.strokes.map { ($0.id, .stroke($0)) })
            case .effects: values = elements(appearance.effects.map { ($0.id, .effect($0)) })
            }
            for id in state.liveElements(host.node, path) {
                keyed.append((state.position(host.node, path, id) ?? [], StackEntry(row: AppearanceRow(list, id), element: values[id]!)))
            }
        }
        return keyed.sorted { a, b in
            if a.position != b.position { return FractionalIndex.less(a.position, b.position) }
            if a.entry.row.element != b.entry.row.element { return a.entry.row.element < b.entry.row.element }
            return a.entry.row.list.rawValue < b.entry.row.list.rawValue
        }.map(\.entry)
    }

    private static func elements(_ pairs: [(Wiretuner_Doc_V1_ElementId, AttributePayload.Element)]) -> [OpID: AttributePayload.Element] {
        Dictionary(pairs.compactMap { pair in OpID(element: pair.0).map { ($0, pair.1) } }) { first, _ in first }
    }

    /// The entries of the document defaults: the stored stack, or -- when it holds no fill or
    /// stroke -- the built-in defaults (`Appearances.standard`, which carry no element ids; they
    /// are numbered in list order).
    static func defaultEntries(in state: EngineState) -> [StackEntry] {
        let stored = entries(.defaults, in: state)
        guard !stored.contains(where: { $0.row.list != .effects }) else { return stored }
        let standard = Appearances.standard
        let elements = standard.fills.map(AttributePayload.Element.fill) + standard.strokes.map(AttributePayload.Element.stroke)
        return elements.enumerated().map { index, element in
            StackEntry(row: AppearanceRow(element.list, OpID(counter: UInt64(index + 1), replica: 0)), element: element)
        }
    }

    // MARK: Composing

    /// Where each category of a look comes from: the host node and its entries of that category.
    struct Part: Hashable, Sendable {
        var source: OpID
        /// The source's whole stack (ranks are indexes into it).
        var entries: [StackEntry]
    }

    /// A composed look: a canonical stack and the halftone screen.
    struct Look: Hashable, Sendable {
        var stack: [AttributePayload.Element]
        var halftone: Wiretuner_Doc_V1_Halftone?

        /// The elements of `category` with ids cleared (for comparing looks).
        func content(_ category: StyleCategory) -> [[UInt8]] {
            guard let list = StyleStacks.list(category) else { return halftone.map { screen in [Wire.bytes { try screen.serializedBytes() }] } ?? [] }
            return stack.filter { $0.list == list }.map(StyleStacks.content)
        }
    }

    /// An element's encoding with its id cleared (a canonical attachment is kept).
    static func content(_ element: AttributePayload.Element) -> [UInt8] {
        switch element {
        case .fill(var fill):
            fill.clearID()
            return Wire.bytes { try fill.serializedBytes() }
        case .stroke(var stroke):
            stroke.clearID()
            return Wire.bytes { try stroke.serializedBytes() }
        case .effect(var effect):
            effect.clearID()
            return Wire.bytes { try effect.serializedBytes() }
        }
    }

    /// The canonical stack of `parts` (a category without a part is empty): fills and strokes
    /// in their source's order when one source supplies both, else the fills below the strokes;
    /// then the effects in their source's order.  An effect keeps its attachment when its element
    /// comes from the same source.
    static func compose(_ parts: [StyleCategory: Part]) -> [AttributePayload.Element] {
        func ranked(_ category: StyleCategory) -> [(source: OpID, rank: Int, entry: StackEntry)] {
            guard let part = parts[category], let list = list(category) else { return [] }
            return part.entries.enumerated().filter { $0.element.row.list == list }.map { (part.source, $0.offset, $0.element) }
        }
        let fills = ranked(.fills)
        let strokes = ranked(.strokes)
        var paint = fills + strokes
        if parts[.fills]?.source == parts[.strokes]?.source { paint.sort { $0.rank < $1.rank } }
        let ordered = paint + ranked(.effects)
        var place: [OpID: [OpID: UInt64]] = [:]
        for (index, item) in ordered.enumerated() { place[item.source, default: [:]][item.entry.row.element] = UInt64(index + 1) }
        return ordered.enumerated().map { index, item in
            let id = Ops.elementID(OpID(counter: UInt64(index + 1), replica: 0))
            switch item.entry.element {
            case .fill(var fill):
                fill.id = id
                return .fill(fill)
            case .stroke(var stroke):
                stroke.id = id
                return .stroke(stroke)
            case .effect(var effect):
                effect.id = id
                if effect.hasAttachedTo {
                    if let target = OpID(element: effect.attachedTo).flatMap({ place[item.source]?[$0] }) {
                        effect.attachedTo = Ops.elementID(OpID(counter: target, replica: 0))
                    } else {
                        effect.clearAttachedTo()
                    }
                }
                return .effect(effect)
            }
        }
    }

    /// The canonical form of one stored stack.
    static func canonical(_ entries: [StackEntry], source: OpID) -> [AttributePayload.Element] {
        let part = Part(source: source, entries: entries)
        return compose([.fills: part, .strokes: part, .effects: part])
    }

    /// The link of `chain` (nearest first) supplying each category: the nearest that governs and
    /// sets it.
    static func chainSources(_ chain: [OpID], styles: GraphicStyleResolver) -> [StyleCategory: OpID] {
        var result: [StyleCategory: OpID] = [:]
        for link in chain.reversed() {
            let props = styles.entries[link]!.props
            for category in styles.governs(link) where sets(category, props) { result[category] = link }
        }
        return result
    }

    /// Whether a style's own registers set `category`.
    static func sets(_ category: StyleCategory, _ props: Wiretuner_Doc_V1_StyleProps) -> Bool {
        switch category {
        case .fills: !props.appearance.fills.isEmpty
        case .strokes: !props.appearance.strokes.isEmpty
        case .effects: !props.appearance.effects.isEmpty
        case .halftone: props.common.hasHalftone
        }
    }

    /// What a style chain (nearest first) supplies: only the categories some link governs and
    /// sets, without the document defaults.
    static func look(chain: [OpID], styles: GraphicStyleResolver, state: EngineState) -> (look: Look, sources: [StyleCategory: OpID]) {
        let sources = chainSources(chain, styles: styles)
        var cache: [OpID: [StackEntry]] = [:]
        var parts: [StyleCategory: Part] = [:]
        for (category, link) in sources where category != .halftone {
            if cache[link] == nil { cache[link] = entries(.style(link), in: state) }
            parts[category] = Part(source: link, entries: cache[link]!)
        }
        let halftone = sources[.halftone].map { styles.entries[$0]!.props.common.halftone }
        return (Look(stack: compose(parts), halftone: halftone), sources)
    }

    /// The effective look of `object` were it to use the style chain `chain` (nearest first):
    /// its own set categories, then the chain's, then the document defaults.  `props` stands for
    /// the object's stored properties when given.  Also returns whether a category fell back to
    /// the defaults and the categories the object sets itself.
    static func look(of object: OpID, chain: [OpID], props: Wiretuner_Doc_V1_NodeProps? = nil, styles: GraphicStyleResolver,
                     state: EngineState) -> (look: Look, usesDefaults: Bool, own: Set<StyleCategory>) {
        let own = styles.ownCategories(of: object, in: state)
        let sources = chainSources(chain, styles: styles)
        let objectProps = props ?? state.props(object)
        var cache: [OpID: [StackEntry]] = [:]
        func entries(of node: OpID) -> [StackEntry] {
            if let known = cache[node] { return known }
            let value: [StackEntry]
            if node == object {
                value = StyleStacks.entries(StackHost.of(object, in: state)!, props: objectProps, in: state)
            } else if node == WellKnown.settings {
                value = defaultEntries(in: state)
            } else {
                value = StyleStacks.entries(.style(node), in: state)
            }
            cache[node] = value
            return value
        }
        var usesDefaults = false
        var parts: [StyleCategory: Part] = [:]
        for category in [StyleCategory.fills, .strokes, .effects] {
            let source: OpID
            if own.contains(category) {
                source = object
            } else if let link = sources[category] {
                source = link
            } else {
                source = WellKnown.settings
                usesDefaults = true
            }
            parts[category] = Part(source: source, entries: entries(of: source))
        }
        let halftone: Wiretuner_Doc_V1_Halftone?
        if own.contains(.halftone) {
            halftone = NodeValues.common(objectProps)?.halftone
        } else {
            halftone = sources[.halftone].map { styles.entries[$0]!.props.common.halftone }
        }
        return (Look(stack: compose(parts), halftone: halftone), usesDefaults, own)
    }

    /// The effective look of `object` as it is (its style's chain after the read-time rules).
    static func look(of object: OpID, styles: GraphicStyleResolver, state: EngineState) -> Look {
        look(of: object, chain: styles.style(of: object, in: state).map(styles.chain) ?? [], styles: styles, state: state).look
    }

    /// The look of the document defaults (the stored stack or the built-in one; no halftone).
    static func defaultsLook(in state: EngineState) -> Look {
        Look(stack: canonical(defaultEntries(in: state), source: WellKnown.settings), halftone: nil)
    }

    // MARK: Writing

    /// Appends the ops inserting `elements` (canonical, bottom first) into the empty stack of
    /// `host`, in order.  Nested sequences (a gradient's stops) follow their element; each
    /// effect's `attached_to` is pointed at the inserted copy of its element.  Returns the
    /// inserted element ids in order.
    @discardableResult
    static func insert(_ elements: [AttributePayload.Element], into host: StackHost, state: EngineState,
                       builder: inout ChangeBuilder) throws -> [OpID] {
        guard !elements.isEmpty else { return [] }
        return try insert(elements, into: host, keys: PathEditing.keys(between: nil, and: nil, count: elements.count), attached: [:],
                          state: state, builder: &builder)
    }

    /// `insert` at the given keys (one per element); an effect attached to a place outside
    /// `elements` is pointed at `attached[place]`.
    static func insert(_ elements: [AttributePayload.Element], into host: StackHost, keys: [[UInt8]], attached: [UInt64: OpID],
                       state: EngineState, builder: inout ChangeBuilder) throws -> [OpID] {
        let schema = state.schema
        var mapping = attached
        var inserted: [OpID] = []
        var attachments: [(effect: OpID, target: UInt64)] = []
        for (element, key) in zip(elements, keys) {
            var value = Wiretuner_Doc_V1_AppearanceProps()
            let place: UInt64
            let body: [UInt8]
            switch element {
            case .fill(var fill):
                place = fill.id.counter
                fill.clearID()
                value.fills = [fill]
                body = Wire.bytes { try fill.serializedBytes() }
            case .stroke(var stroke):
                place = stroke.id.counter
                stroke.clearID()
                value.strokes = [stroke]
                body = Wire.bytes { try stroke.serializedBytes() }
            case .effect(var effect):
                place = effect.id.counter
                if effect.hasAttachedTo { attachments.append((OpID.zero, effect.attachedTo.counter)) }
                effect.clearID()
                effect.clearAttachedTo()
                value.effects = [effect]
                body = Wire.bytes { try effect.serializedBytes() }
            }
            let sequence = host.sequence(element.list)
            let id = builder.append(Ops.elementInsert(host.node, sequence, positions: [key], values: host.values(value)))
            if case .effect(let effect) = element, effect.hasAttachedTo { attachments[attachments.count - 1].effect = id }
            inserted.append(id)
            mapping[place] = id
            let list = element.list.rawValue
            try NodeCopier.copySequences(schema.field(appearanceType, Int(list))!.typeName!, payload: body, prefix: sequence.element(id),
                                         node: host.node, schema: schema, wrap: {
                                             host.wrap(Wire.field(list, Wire.field(1, Wire.elementID(id)) + $0))
                                         }, builder: &builder)
        }
        for attachment in attachments {
            guard let target = mapping[attachment.target] else { continue }
            var effect = Wiretuner_Doc_V1_Effect()
            effect.id = Ops.elementID(attachment.effect)
            effect.attachedTo = Ops.elementID(target)
            builder.append(Ops.set(host.node, [host.sequence(.effects).element(attachment.effect).child(3)],
                                   values: host.values(Wiretuner_Doc_V1_AppearanceProps.with { $0.effects = [effect] })))
        }
        return inserted
    }

    /// Appends an `ElementDelete` of `entries` of `host` (nothing for none).
    static func delete(_ entries: [StackEntry], of host: StackHost, builder: inout ChangeBuilder) {
        guard !entries.isEmpty else { return }
        builder.append(Ops.elementDelete(host.node, entries.map { host.sequence($0.row.list).element($0.row.element) }))
    }

    /// Replaces the whole stack of `host` with `elements` (the defaults when a style is selected).
    static func replace(_ host: StackHost, with elements: [AttributePayload.Element], state: EngineState, builder: inout ChangeBuilder) throws {
        delete(entries(host, in: state), of: host, builder: &builder)
        try insert(elements, into: host, state: state, builder: &builder)
    }

    /// Rewrites the stack of `host` in the categories `categories` to hold `target`'s elements of
    /// those categories, editing in place where it can (styles.adoc, "Merge semantics",
    /// `appearance`): within each list the stored element and the target element at the same
    /// index are paired when their kinds match and only the registers that differ are written;
    /// the rest are deleted and inserted, next to their neighbours in the list.  So two
    /// redefinitions that change different fields both survive the merge.  An element whose
    /// nested sequence (a gradient's stops) differs is replaced.
    static func rewrite(_ host: StackHost, categories: Set<StyleCategory>, to target: [AttributePayload.Element], state: EngineState,
                        builder: inout ChangeBuilder) throws {
        let stored = entries(host, in: state)
        // An empty stack takes the target's elements in their order.
        if stored.isEmpty {
            try insert(target.filter { categories.contains(category($0.list)) }, into: host, state: state, builder: &builder)
            return
        }
        var positions: [AppearanceRow: [UInt8]] = [:]
        for entry in stored { positions[entry.row] = state.position(host.node, host.sequence(entry.row.list), entry.row.element) ?? [] }
        let all = positions.values.sorted(by: FractionalIndex.less)
        // Canonical place of each target element → the host element standing for it.
        var mapping: [UInt64: OpID] = [:]
        for list in AppearanceList.allCases where categories.contains(category(list)) {
            let old = stored.filter { $0.row.list == list }
            let new = target.filter { $0.list == list }
            var deletes: [StackEntry] = []
            var pending: [(index: Int, element: AttributePayload.Element)] = []
            var kept: [Int: StackEntry] = [:]
            for index in 0..<max(old.count, new.count) {
                guard index < new.count else {
                    deletes.append(old[index])
                    continue
                }
                let element = attach(new[index], mapping: mapping)
                if index < old.count, AttributeKind.of(old[index].element) == AttributeKind.of(element),
                   let paths = changedLeaves(element.list, old: old[index].element, new: element, schema: state.schema) {
                    kept[index] = old[index]
                    mapping[new[index].place] = old[index].row.element
                    if !paths.isEmpty {
                        let prefix = host.sequence(list).element(old[index].row.element)
                        builder.append(Ops.set(host.node, paths.map { prefix.appending($0) },
                                               values: host.values(element.stack(id: old[index].row.element))))
                    }
                } else {
                    if index < old.count { deletes.append(old[index]) }
                    pending.append((index, new[index]))
                }
            }
            delete(deletes, of: host, builder: &builder)
            // Each inserted run sits between the kept (or already inserted) element below it in
            // this list and the next kept one above it; alone in its list, fills go below the
            // stack and strokes and effects above it.
            var placed: [Int: [UInt8]] = [:]
            for (index, element) in pending {
                let below = (0..<index).reversed().lazy.compactMap { placed[$0] ?? kept[$0].flatMap { positions[$0.row] } }.first
                let above = (index + 1..<max(new.count, index + 1)).lazy.compactMap { kept[$0].flatMap { positions[$0.row] } }.first
                let lo: [UInt8]?
                let hi: [UInt8]?
                if below == nil && above == nil {
                    lo = list == .fills ? nil : all.last
                    hi = list == .fills ? all.first : nil
                } else {
                    lo = below
                    hi = above
                }
                let key = try PathEditing.keys(between: lo, and: hi, count: 1)[0]
                placed[index] = key
                let id = try insert([element], into: host, keys: [key], attached: mapping, state: state, builder: &builder)[0]
                mapping[element.place] = id
            }
        }
    }

    /// `element` with its canonical attachment pointed at the host element in `mapping` (cleared
    /// when there is none).
    private static func attach(_ element: AttributePayload.Element, mapping: [UInt64: OpID]) -> AttributePayload.Element {
        guard case .effect(var effect) = element, effect.hasAttachedTo else { return element }
        if let target = mapping[effect.attachedTo.counter] {
            effect.attachedTo = Ops.elementID(target)
        } else {
            effect.clearAttachedTo()
        }
        return .effect(effect)
    }

    /// The register fields (relative to the element) where `new` differs from `old`, or nil when
    /// a nested sequence differs.  Ids are ignored.
    static func changedLeaves(_ list: AppearanceList, old: AttributePayload.Element, new: AttributePayload.Element, schema: Schema) -> [[UInt32]]? {
        let type = schema.field(appearanceType, Int(list.rawValue))!.typeName!
        func body(_ element: AttributePayload.Element) -> [UInt8] {
            WireReader.fields(element.encoded)!.filter { $0.number != 1 }.flatMap(\.record)
        }
        return changedLeaves(type, old: body(old), new: body(new), prefix: [], schema: schema)
    }

    /// The registers of message `message` where `new` differs from `old`, below `prefix`.
    static func changedLeaves(_ message: String, old: [UInt8], new: [UInt8], prefix: [UInt32], schema: Schema) -> [[UInt32]]? {
        let a = WireReader.fields(old)!
        let b = WireReader.fields(new)!
        var paths: [[UInt32]] = []
        for row in schema.fields(message) where !(row.fieldNumber == 1 && row.name == "id") {
            let number = UInt32(row.fieldNumber)
            let before = a.filter { $0.number == number }
            let after = b.filter { $0.number == number }
            switch row.policy {
            case .structure where !row.repeated && row.typeName != nil, .variant where !row.repeated && row.typeName != nil:
                guard let nested = changedLeaves(row.typeName!, old: before.last?.payload ?? [], new: after.last?.payload ?? [],
                                                 prefix: prefix + [number], schema: schema) else { return nil }
                paths += nested
            case .sequence:
                let strip = { (field: WireReader.Field) in WireReader.fields(field.payload)!.filter { $0.number != 1 }.flatMap(\.record) }
                if before.map(strip) != after.map(strip) { return nil }
            default:
                if before.flatMap(\.record) != after.flatMap(\.record) { paths.append(prefix + [number]) }
            }
        }
        return paths
    }
}

extension AttributeKind {
    /// The normalized kind of a stack element.
    static func of(_ element: AttributePayload.Element) -> AttributeKind {
        switch element {
        case .fill(let fill): .fill(normalizing: fill.settings.kind)
        case .stroke(let stroke): .stroke(normalizing: stroke.settings.kind)
        case .effect(let effect): .effect(effect.settings.kind)
        }
    }
}

extension AttributePayload.Element {
    /// The canonical place (the id's counter).
    var place: UInt64 {
        switch self {
        case .fill(let fill): fill.id.counter
        case .stroke(let stroke): stroke.id.counter
        case .effect(let effect): effect.id.counter
        }
    }

    /// The element's encoding.
    var encoded: [UInt8] {
        switch self {
        case .fill(let fill): Wire.bytes { try fill.serializedBytes() }
        case .stroke(let stroke): Wire.bytes { try stroke.serializedBytes() }
        case .effect(let effect): Wire.bytes { try effect.serializedBytes() }
        }
    }

    /// An `AppearanceProps` holding only this element, under element id `id`.
    func stack(id: OpID) -> Wiretuner_Doc_V1_AppearanceProps {
        var stack = Wiretuner_Doc_V1_AppearanceProps()
        switch self {
        case .fill(var fill):
            fill.id = Ops.elementID(id)
            stack.fills = [fill]
        case .stroke(var stroke):
            stroke.id = Ops.elementID(id)
            stack.strokes = [stroke]
        case .effect(var effect):
            effect.id = Ops.elementID(id)
            stack.effects = [effect]
        }
        return stack
    }
}
