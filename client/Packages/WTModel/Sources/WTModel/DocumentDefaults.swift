import WTCRDT
import WTProto

/// The document's default attributes (default-attributes.adoc; OBJ-037): the attribute stack on
/// the settings node's `defaults.appearance` that every new drawable object is born with.  The
/// Object panel edits it with nothing selected through the ordinary stack commands (the settings
/// node is a `StackOwner`); this is the `DefaultsProvider` the drawing and type tools read at
/// creation, the style link, the current colours laid over the defaults, and *Changing object
/// changes defaults*.
public enum DocumentDefaults {
    /// A current colour (applying-color.adoc, "The color wells"): *None*, or a colour.
    public enum ColorChoice: Hashable, Sendable {
        case noColor
        case color(Wiretuner_Doc_V1_ColorRef)
    }

    /// The appearance a new object is born with: a copy of the live fills and strokes of
    /// `settings.defaults.appearance`, bottom first, their element ids cleared -- the creation
    /// command's inserts give the copy fresh ids, so the object holds no reference to the defaults.
    /// With no live fill or stroke (a document written before the field, or every element
    /// deleted) it reads as the built-in defaults, a 1 pt black basic stroke and no fill.
    public static func appearance(in state: EngineState) -> Wiretuner_Doc_V1_AppearanceProps {
        let stored = state.props(WellKnown.settings).settings.defaults.appearance
        var copy = Wiretuner_Doc_V1_AppearanceProps()
        copy.fills = live(stored.fills, rows: AppearanceEditing.rows(WellKnown.settings, .fills, in: state), id: { OpID(element: $0.id) }) {
            $0.clearID()
        }
        copy.strokes = live(stored.strokes, rows: AppearanceEditing.rows(WellKnown.settings, .strokes, in: state), id: { OpID(element: $0.id) }) {
            $0.clearID()
        }
        return copy.fills.isEmpty && copy.strokes.isEmpty ? Appearances.standard : copy
    }

    /// The elements of `elements` whose ids are in `rows`, in `rows`' order, each passed through
    /// `clear`.
    static func live<Element>(_ elements: [Element], rows: [OpID], id: (Element) -> OpID?, clear: (inout Element) -> Void) -> [Element] {
        let byID = Dictionary(elements.compactMap { element in id(element).map { ($0, element) } }) { first, _ in first }
        return rows.compactMap { byID[$0] }.map { element in
            var copy = element
            clear(&copy)
            return copy
        }
    }

    /// What a new object gets: the document's defaults with your current colours laid over them.
    public static func newObjectAppearance(in state: EngineState, fill: ColorChoice? = nil, stroke: ColorChoice? = nil) -> Wiretuner_Doc_V1_AppearanceProps {
        applying(fill: fill, stroke: stroke, to: appearance(in: state))
    }

    /// `appearance` with the current colours applied: a colour goes to the topmost basic fill
    /// (stroke), or a new basic fill (1 pt basic stroke) is added on top when there is none;
    /// *None* removes the fills (strokes); nil leaves the list as it is.
    public static func applying(fill: ColorChoice?, stroke: ColorChoice?, to appearance: Wiretuner_Doc_V1_AppearanceProps) -> Wiretuner_Doc_V1_AppearanceProps {
        var result = appearance
        switch fill {
        case .noColor?: result.fills = []
        case .color(let color)?:
            if let top = result.fills.lastIndex(where: { isBasic($0.settings.kind) }) {
                result.fills[top].settings.basic.color = color
            } else {
                var added = Wiretuner_Doc_V1_Fill()
                added.settings.kind = .basic
                added.settings.basic.color = color
                result.fills.append(added)
            }
        case nil: break
        }
        switch stroke {
        case .noColor?: result.strokes = []
        case .color(let color)?:
            if let top = result.strokes.lastIndex(where: { isBasic($0.settings.kind) }) {
                result.strokes[top].settings.basic.color = color
            } else {
                var added = Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)
                added.settings.basic.color = color
                result.strokes.append(added)
            }
        case nil: break
        }
        return result
    }

    /// The colour of the topmost basic fill and stroke of `appearance` (*None* when the list has
    /// no basic element): what the Tools panel wells show for the defaults.
    public static func colors(of appearance: Wiretuner_Doc_V1_AppearanceProps) -> (fill: ColorChoice, stroke: ColorChoice) {
        let fill = appearance.fills.last { isBasic($0.settings.kind) }.map { ColorChoice.color($0.settings.basic.color) } ?? .noColor
        let stroke = appearance.strokes.last { isBasic($0.settings.kind) }.map { ColorChoice.color($0.settings.basic.color) } ?? .noColor
        return (fill, stroke)
    }

    static func isBasic(_ kind: Wiretuner_Doc_V1_FillKind) -> Bool { kind == .basic || kind == .unspecified }
    static func isBasic(_ kind: Wiretuner_Doc_V1_StrokeKind) -> Bool { kind == .basic || kind == .unspecified }

    /// The graphic style the defaults mirror; nil -- *Normal* -- when unset or dangling.
    public static func style(in state: EngineState) -> OpID? {
        let ref = state.props(WellKnown.settings).settings.defaults.style
        guard ref.hasID else { return nil }
        let node = OpID(ref.id)
        return state.isLive(node) ? node : nil
    }

    /// `command` in an `AlsoChangingDefaults` when it edits the attribute stack of an object (the
    /// first object it edits becomes the defaults' source) -- *Changing object changes defaults*
    /// is on -- and any other command as it is.
    public static func following(_ command: any Command) -> any Command {
        guard let source = editedObject(of: command) else { return command }
        return AlsoChangingDefaults(command, source: source)
    }

    /// The first object whose attribute stack `command` edits; nil for any other command, and for
    /// an edit of the defaults themselves.
    static func editedObject(of command: any Command) -> OpID? {
        let nodes: [OpID]
        switch command {
        case let add as AddAppearance: nodes = add.nodes
        case let remove as RemoveAppearance: nodes = [remove.node]
        case let move as MoveAppearance: nodes = [move.node]
        case let duplicate as DuplicateAppearance: nodes = [duplicate.node]
        case let color as SetAppearanceColor: nodes = color.rows.map(\.node)
        case let width as SetStrokeWidth: nodes = width.rows.map(\.node)
        case let edit as EditAttribute: nodes = edit.rows.map(\.node)
        case let kind as SetAttributeKind: nodes = kind.rows.map(\.node)
        case let hidden as SetAppearanceHidden: nodes = hidden.rows.map(\.node)
        case let reorder as ReorderAttribute: nodes = reorder.rows.map(\.node)
        case let apply as ApplyColor: nodes = apply.nodes
        default: return nil
        }
        return nodes.first { $0 != WellKnown.settings }
    }

    /// The ops that make the defaults a copy of `stack`: every live default fill, stroke and
    /// effect deleted, then `stack`'s fills and strokes inserted, fills below strokes.
    static func replacement(with stack: Wiretuner_Doc_V1_AppearanceProps, in state: EngineState) throws -> [Wiretuner_Doc_V1_Op] {
        let owner = StackOwner.defaults
        var ops: [Wiretuner_Doc_V1_Op] = []
        let old = AppearanceList.allCases.flatMap { list in
            AppearanceEditing.rows(WellKnown.settings, list, in: state).map { owner.sequence(list).element($0) }
        }
        if !old.isEmpty { ops.append(Ops.elementDelete(WellKnown.settings, old)) }
        var fills = stack.fills, strokes = stack.strokes
        for index in fills.indices { fills[index].clearID() }
        for index in strokes.indices { strokes[index].clearID() }
        let keys = try PathEditing.keys(between: nil, and: nil, count: fills.count + strokes.count)
        if !fills.isEmpty {
            ops.append(Ops.elementInsert(WellKnown.settings, owner.sequence(.fills), positions: Array(keys.prefix(fills.count)),
                                         values: AppearanceEditing.values(owner) { $0.fills = fills }))
        }
        if !strokes.isEmpty {
            ops.append(Ops.elementInsert(WellKnown.settings, owner.sequence(.strokes), positions: Array(keys.suffix(strokes.count)),
                                         values: AppearanceEditing.values(owner) { $0.strokes = strokes }))
        }
        return ops
    }
}

/// Makes the defaults mirror a graphic style (styles.adoc: choosing a style with nothing
/// selected): `defaults.style` set to it -- nil for *Normal* -- and the default stack replaced by
/// a copy of `appearance`, the style's attributes, in one change.
public struct SetDefaultsStyle: Command {
    public var style: OpID?
    public var appearance: Wiretuner_Doc_V1_AppearanceProps

    public init(style: OpID?, appearance: Wiretuner_Doc_V1_AppearanceProps) {
        self.style = style
        self.appearance = appearance
    }

    public var label: String { "Change default attributes" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        if let style { props.settings.defaults.style.id = style.proto }
        builder.append(Ops.set(WellKnown.settings, [RegisterPath([2, 10, 2])], values: props))
        for op in try DocumentDefaults.replacement(with: appearance, in: state) { builder.append(op) }
    }
}

/// *Changing object changes defaults* (default-attributes.adoc, "Merge semantics"): an edit of an
/// object's attributes and, in the *same change*, the defaults rewritten as a copy of `source`'s
/// stack after the edit, so undoing the edit undoes the default change too.  The label is the
/// edit's with " (and defaults)".  An edit that writes nothing writes no defaults either.
public struct AlsoChangingDefaults: Command {
    public var edit: any Command
    public var source: OpID

    public init(_ edit: any Command, source: OpID) {
        self.edit = edit
        self.source = source
    }

    public var label: String { "\(edit.label) (and defaults)" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try edit.execute(&builder, state: state)
        guard !builder.ops.isEmpty, source != WellKnown.settings else { return }
        var after = state
        var change = Wiretuner_Doc_V1_Change()
        change.replica = builder.replica
        change.startCounter = builder.startCounter
        change.ops = builder.ops
        _ = after.applyLocal(change)
        guard let stack = NodeValues.appearance(after.props(source)) else { return }
        var live = Wiretuner_Doc_V1_AppearanceProps()
        live.fills = DocumentDefaults.live(stack.fills, rows: AppearanceEditing.rows(source, .fills, in: after), id: { OpID(element: $0.id) }) { _ in }
        live.strokes = DocumentDefaults.live(stack.strokes, rows: AppearanceEditing.rows(source, .strokes, in: after), id: { OpID(element: $0.id) }) { _ in }
        for op in try DocumentDefaults.replacement(with: live, in: after) { builder.append(op) }
    }
}
