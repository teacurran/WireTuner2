import WTCRDT
import WTProto

// The graphic style commands of LIB-019 (library/styles.adoc, "Override model", "Merge
// semantics", "Client"): new, new from Normal, duplicate, rename, apply, redefine, remove, remove
// unused, set parent and set behaviour, and selecting a style as the default attributes.  Copy
// and Paste Attributes are OBJ-014's (`AttributePayload`, `PasteAttributes`): a pasted stack is
// the target's own, so it reads as overrides on the target's style.  Each command is one change
// and one undo step.  Objects store only their overrides; appearance is resolved on read by
// `GraphicStyleResolver`, so a redefine writes one node.

/// Why a graphic style command refused to build its change.
public enum GraphicStyleError: Error, Hashable, Sendable {
    /// Not a live graphic style.
    case notStyle(OpID)
    /// The Normal style cannot be removed or given a parent.
    case normal
    /// The parent would make the style its own ancestor.
    case loop(OpID)
    /// Not an object with an attribute stack.
    case notObject(OpID)
    /// A value out of range: the field or parameter named.
    case invalidValue(String)
}

/// Register paths and building blocks of the graphic style commands.
public enum GraphicStyleFields {
    public static let collection = GraphicStyleResolver.collection
    /// `StyleProps.common.name`.
    public static let name = RegisterPath([GraphicStyleResolver.styleKind, 1, 1])
    /// `StyleProps.common.halftone`.
    public static let halftone = RegisterPath([GraphicStyleResolver.styleKind, 1, 11])
    /// `StyleProps.based_on`.
    public static let basedOn = RegisterPath([GraphicStyleResolver.styleKind, 4])
    /// `StyleProps.behavior`.
    public static let behavior = RegisterPath([GraphicStyleResolver.styleKind, 5])
    /// The name the Normal graphic style is created with.
    public static let normalName = "Normal"

    /// `CommonProps.style` of an object of `kind`.
    static func objectStyle(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 7]) }
    /// `CommonProps.halftone` of an object of `kind`.
    static func objectHalftone(_ kind: NodeKind) -> RegisterPath { RegisterPath([kind.rawValue, 1, 11]) }

    /// The `StyleBehavior` field of a category.
    static func behaviorField(_ category: StyleCategory) -> UInt32 { UInt32(category.rawValue + 1) }

    /// A sparse `NodeProps` of a style.
    static func values(_ build: (inout Wiretuner_Doc_V1_StyleProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.style)
        return props
    }

    /// A behaviour governing `categories`.
    static func behavior(_ categories: Set<StyleCategory>) -> Wiretuner_Doc_V1_StyleBehavior {
        var behavior = Wiretuner_Doc_V1_StyleBehavior()
        behavior.fills = categories.contains(.fills)
        behavior.strokes = categories.contains(.strokes)
        behavior.effects = categories.contains(.effects)
        behavior.halftone = categories.contains(.halftone)
        return behavior
    }

    /// The live graphic style `id`, or throws.
    static func style(_ id: OpID, in styles: GraphicStyleResolver) throws -> Wiretuner_Doc_V1_StyleProps {
        guard let entry = styles.entries[id], styles.isGraphic(id), styles.isLive(id) else { throw GraphicStyleError.notStyle(id) }
        return entry.props
    }

    /// The live graphic styles, in sibling order.
    public static func styles(in state: EngineState, _ styles: GraphicStyleResolver) -> [OpID] {
        state.store.children(collection).filter { styles.entries[$0] != nil && styles.isGraphic($0) && styles.isLive($0) }
    }

    /// The first "Style N" no live graphic style is named.
    public static func nextName(in state: EngineState, _ resolver: GraphicStyleResolver) -> String {
        let names = Set(styles(in: state, resolver).map { resolver.entries[$0]!.props.common.name })
        var number = 1
        while names.contains("Style \(number)") { number += 1 }
        return "Style \(number)"
    }

    /// The objects among `nodes` a style applies to: editable objects with an attribute stack.
    static func objects(_ nodes: [OpID], in state: EngineState) -> [(OpID, NodeKind)] {
        Objects.editable(nodes, in: state).compactMap { node in
            guard case .object(_, let kind)? = StackHost.of(node, in: state) else { return nil }
            return (node, kind)
        }
    }

    /// Writes the style reference of `object` (nil clears it) and clears the object's own
    /// registers in `governed`: an `ElementDelete` of its live elements in each governed list,
    /// and the halftone register listed with no value in the same `SetFields` as the reference
    /// -- the clear-to-unset form, so the clear takes part in LWW like any write.
    static func apply(_ style: OpID?, governed: Set<StyleCategory>, to object: OpID, kind: NodeKind, state: EngineState,
                      builder: inout ChangeBuilder) {
        var paths = [objectStyle(kind)]
        // Listed whether or not this replica sees a value: a concurrent override competes by LWW.
        if governed.contains(.halftone) { paths.append(objectHalftone(kind)) }
        let values = NodeValues.common(kind: kind) { common in
            if let style { common.style.id = style.proto }
        }
        builder.append(Ops.set(object, paths, values: values))
        let host = StackHost.object(object, kind)
        StyleStacks.delete(StyleStacks.entries(host, in: state).filter { governed.contains(StyleStacks.category($0.row.list)) }, of: host,
                           builder: &builder)
    }

    /// Writes `look`'s values in `categories` into `host` (an object or a style) as its own: the
    /// stacks rewritten in place, the halftone written (or cleared).
    static func write(_ look: StyleStacks.Look, categories: Set<StyleCategory>, into host: StackHost, state: EngineState,
                      builder: inout ChangeBuilder) throws {
        let stacks = categories.subtracting([.halftone])
        if !stacks.isEmpty { try StyleStacks.rewrite(host, categories: stacks, to: look.stack, state: state, builder: &builder) }
        guard categories.contains(.halftone) else { return }
        if case .object(let object, let kind) = host {
            builder.append(Ops.set(object, [objectHalftone(kind)], values: NodeValues.common(kind: kind) { common in
                if let screen = look.halftone { common.halftone = screen }
            }))
        } else {
            builder.append(Ops.set(host.node, [halftone], values: values { if let screen = look.halftone { $0.common.halftone = screen } }))
        }
    }

    /// The categories where two looks differ.
    static func differences(_ a: StyleStacks.Look, _ b: StyleStacks.Look) -> Set<StyleCategory> {
        Set(StyleCategory.allCases.filter { a.content($0) != b.content($0) })
    }

    /// Makes `style` hold `look` in the categories `categories` (those where its resolution
    /// changes), and govern them: the fold of Remove (children keep their look when their parent
    /// goes) and of detaching from the parent.
    static func fold(_ look: StyleStacks.Look, categories: Set<StyleCategory>, into style: OpID, styles: GraphicStyleResolver,
                     state: EngineState, builder: inout ChangeBuilder) throws {
        guard !categories.isEmpty else { return }
        try write(look, categories: categories, into: .style(style), state: state, builder: &builder)
        let stored = styles.entries[style]!.props.behavior
        let explicit = StyleCategory.allCases.filter { stored[keyPath: keyPath($0)] }
        guard !explicit.isEmpty else { return }
        let missing = categories.subtracting(explicit).sorted()
        if !missing.isEmpty {
            builder.append(Ops.set(style, missing.map { behavior.child(behaviorField($0)) },
                                   values: values { $0.behavior = GraphicStyleFields.behavior(Set(missing)) }))
        }
    }

    static func keyPath(_ category: StyleCategory) -> WritableKeyPath<Wiretuner_Doc_V1_StyleBehavior, Bool> {
        switch category {
        case .fills: \.fills
        case .strokes: \.strokes
        case .effects: \.effects
        case .halftone: \.halftone
        }
    }
}

/// Creates the Normal graphic style (role NORMAL; styles.adoc, "The Styles panel") when the
/// document has none: governs every category and sets nothing, so it reads as the document
/// defaults.  Part of the document template, not an undo step.
public struct CreateNormalGraphicStyle: Command {
    public init() {}

    public var label: String { "New style" }
    public var recordsUndo: Bool { false }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard GraphicStyleResolver(state).normal == nil else { return }
        _ = Self.create(&builder, at: try PathEditing.topPosition(in: GraphicStyleFields.collection, state: state))
    }

    /// Appends the creation of Normal at `position` and returns its id.
    static func create(_ builder: inout ChangeBuilder, at position: [UInt8]) -> OpID {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.common.name = GraphicStyleFields.normalName
        props.style.kind = .graphic
        props.style.role = .normal
        props.style.behavior = GraphicStyleFields.behavior(Set(StyleCategory.allCases))
        return builder.append(Ops.create(parent: GraphicStyleFields.collection, position: position, props: props))
    }
}

/// menu:Options[New] and *New from Normal* (styles.adoc, "Adding, duplicating and removing
/// styles"): creates a graphic style at the end of the panel governing every category (all four
/// behaviour bools written, since proto3 bools default to false).
///
/// * `.selection(object)`: the object's current look -- overrides included -- as the style's own.
/// * `.normal`: a child of Normal with no attributes of its own (Normal is created in the same
///   change when the document has none).
/// * `.style(parent)`: a child of `parent` with no attributes of its own: identical to it and
///   following it.
/// * `.defaults`: the document's default attributes as the style's own.
///
/// An empty name takes the next free "Style N".  With `applyTo` (the selection, when *Auto-apply
/// new styles to selection* is on) the objects are switched to the new style, their overrides
/// cleared.  "New style".
public struct CreateGraphicStyle: Command {
    public enum Source: Hashable, Sendable {
        case selection(OpID)
        case normal
        case style(OpID)
        case defaults
    }

    public var source: Source
    public var name: String
    public var applyTo: [OpID]
    public var label: String { "New style" }

    public init(_ source: Source, name: String = "", applyTo: [OpID] = []) {
        self.source = source
        self.name = name
        self.applyTo = applyTo
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard name.unicodeScalars.count <= 256 else { throw GraphicStyleError.invalidValue("name") }
        let styles = GraphicStyleResolver(state)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.common.name = name.isEmpty ? GraphicStyleFields.nextName(in: state, styles) : name
        props.style.kind = .graphic
        props.style.behavior = GraphicStyleFields.behavior(Set(StyleCategory.allCases))
        var look = StyleStacks.Look(stack: [], halftone: nil)
        var position = try PathEditing.topPosition(in: GraphicStyleFields.collection, state: state)
        switch source {
        case .selection(let object):
            guard StackHost.of(object, in: state).map({ if case .object = $0 { true } else { false } }) == true, state.isLive(object) else {
                throw GraphicStyleError.notObject(object)
            }
            look = StyleStacks.look(of: object, styles: styles, state: state)
        case .normal:
            var normal = styles.normal
            if normal == nil {
                normal = CreateNormalGraphicStyle.create(&builder, at: position)
                position = try PathEditing.keys(between: position, and: nil, count: 1)[0]
            }
            props.style.basedOn.id = normal!.proto
        case .style(let parent):
            _ = try GraphicStyleFields.style(parent, in: styles)
            props.style.basedOn.id = parent.proto
        case .defaults:
            look = StyleStacks.defaultsLook(in: state)
        }
        if let halftone = look.halftone { props.style.common.halftone = halftone }
        let style = builder.append(Ops.create(parent: GraphicStyleFields.collection, position: position, props: props))
        try StyleStacks.insert(look.stack, into: .style(style), state: state, builder: &builder)
        for (object, kind) in GraphicStyleFields.objects(applyTo, in: state) {
            GraphicStyleFields.apply(style, governed: Set(StyleCategory.allCases), to: object, kind: kind, state: state, builder: &builder)
        }
    }
}

/// menu:Options[Duplicate]: a copy named after the original with " copy" added, with the same
/// parent and behaviour and a copy of its own attributes (not of what it inherits).  "Duplicate
/// style".
public struct DuplicateGraphicStyle: Command {
    public var style: OpID
    public var label: String { "Duplicate style" }

    public init(_ style: OpID) {
        self.style = style
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let styles = GraphicStyleResolver(state)
        let original = try GraphicStyleFields.style(style, in: styles)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.style.common.name = original.common.name + " copy"
        props.style.kind = .graphic
        props.style.behavior = original.behavior
        if original.common.hasHalftone { props.style.common.halftone = original.common.halftone }
        if let parent = styles.parent(of: style) { props.style.basedOn.id = parent.proto }
        let position = try PathEditing.topPosition(in: GraphicStyleFields.collection, state: state)
        let copy = builder.append(Ops.create(parent: GraphicStyleFields.collection, position: position, props: props))
        let stack = StyleStacks.canonical(StyleStacks.entries(.style(style), in: state), source: style)
        try StyleStacks.insert(stack, into: .style(copy), state: state, builder: &builder)
    }
}

/// Renames a graphic style: one ATOMIC write of `CommonProps.name`.  "Rename style".
public struct RenameGraphicStyle: Command {
    public var style: OpID
    public var name: String
    public var label: String { "Rename style" }

    public init(_ style: OpID, to name: String) {
        self.style = style
        self.name = name
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !name.isEmpty, name.unicodeScalars.count <= 256 else { throw GraphicStyleError.invalidValue("name") }
        _ = try GraphicStyleFields.style(style, in: GraphicStyleResolver(state))
        builder.append(Ops.set(style, [GraphicStyleFields.name], values: GraphicStyleFields.values { $0.common.name = name }))
    }
}

/// Applies a graphic style to objects (clicking a style with objects selected, dropping it on an
/// object; styles.adoc, "Applying styles", "Override model"): writes each object's
/// `CommonProps.style` and clears its overrides in every category the style governs --
/// re-clicking an object's own style removes its overrides.  Categories the style does not
/// govern are left alone.  Locked objects are skipped.  "Apply style <name>".
public struct ApplyGraphicStyle: Command {
    public var style: OpID
    public var objects: [OpID]
    public let label: String

    public init(_ style: OpID, to objects: [OpID], in state: EngineState? = nil) {
        self.style = style
        self.objects = objects
        let name = state.flatMap { GraphicStyleResolver($0).entries[style]?.props.common.name } ?? ""
        label = name.isEmpty ? "Apply style" : "Apply style \(name)"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let styles = GraphicStyleResolver(state)
        _ = try GraphicStyleFields.style(style, in: styles)
        let governed = styles.governs(style)
        for (object, kind) in GraphicStyleFields.objects(objects, in: state) {
            GraphicStyleFields.apply(style, governed: governed, to: object, kind: kind, state: state, builder: &builder)
        }
    }
}

/// *Redefine* (styles.adoc, "Modifying and redefining styles"): commits a look to the style, in
/// the categories it governs, where it differs from what the style resolves to now (a category
/// the look leaves as inherited stays inherited).  Stacks are edited in place
/// (`StyleStacks.rewrite`), so a concurrent redefinition of other fields survives; objects
/// using the style change on read, except where they override.  From an object that uses the
/// style, the object's overrides in those categories are cleared in the same change (its
/// overrides become the redefinition).  "Redefine style <name>".
public struct RedefineGraphicStyle: Command {
    public enum Source: Hashable, Sendable {
        /// An object's current look (dragging it onto the style).
        case object(OpID)
        /// Another style's resolved look (dragging one style onto another).
        case style(OpID)
        /// The document's default attributes (the Object panel with nothing selected).
        case defaults
    }

    public var style: OpID
    public var source: Source
    public let label: String

    public init(_ style: OpID, from source: Source, in state: EngineState? = nil) {
        self.style = style
        self.source = source
        let name = state.flatMap { GraphicStyleResolver($0).entries[style]?.props.common.name } ?? ""
        label = name.isEmpty ? "Redefine style" : "Redefine style \(name)"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let styles = GraphicStyleResolver(state)
        _ = try GraphicStyleFields.style(style, in: styles)
        let target: StyleStacks.Look
        switch source {
        case .object(let object):
            guard state.isLive(object), case .object? = StackHost.of(object, in: state) else { throw GraphicStyleError.notObject(object) }
            target = StyleStacks.look(of: object, styles: styles, state: state)
        case .style(let other):
            _ = try GraphicStyleFields.style(other, in: styles)
            target = StyleStacks.look(chain: styles.chain(of: other), styles: styles, state: state).look
        case .defaults:
            target = StyleStacks.defaultsLook(in: state)
        }
        let current = StyleStacks.look(chain: styles.chain(of: style), styles: styles, state: state).look
        let governed = styles.governs(style)
        let changed = GraphicStyleFields.differences(current, target).intersection(governed)
        try GraphicStyleFields.write(target, categories: changed, into: .style(style), state: state, builder: &builder)
        if case .object(let object) = source, styles.style(of: object, in: state) == style, case .object(_, let kind)? = StackHost.of(object, in: state) {
            let own = styles.ownCategories(of: object, in: state).intersection(governed)
            if !own.isEmpty { GraphicStyleFields.apply(style, governed: own, to: object, kind: kind, state: state, builder: &builder) }
        }
    }
}

/// menu:Options[Remove] (styles.adoc, "Delete style in use"): one change that keeps every look.
/// Each object using the style gets, as overrides, every category whose look would change once
/// it points at the style's parent (or Normal; or no style), and is re-pointed there; each child
/// style is re-parented the same way with the categories it inherited through the style folded
/// into it; then the style is deleted.  Normal cannot be removed.  "Remove style <name>".
public struct RemoveGraphicStyle: Command {
    public var style: OpID
    public let label: String

    public init(_ style: OpID, in state: EngineState? = nil) {
        self.style = style
        let name = state.flatMap { GraphicStyleResolver($0).entries[style]?.props.common.name } ?? ""
        label = name.isEmpty ? "Remove style" : "Remove style \(name)"
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let styles = GraphicStyleResolver(state)
        _ = try GraphicStyleFields.style(style, in: styles)
        guard styles.role(of: style) != .normal else { throw GraphicStyleError.normal }
        let parent = styles.parent(of: style)
        let successor = parent ?? styles.normal.flatMap { styles.isLive($0) ? $0 : nil }
        let successorChain = successor.map(styles.chain) ?? []
        for object in styles.index(in: state)[style] ?? [] {
            guard case .object(_, let kind)? = StackHost.of(object, in: state) else { continue }
            let now = StyleStacks.look(of: object, chain: styles.chain(of: style), styles: styles, state: state)
            let after = StyleStacks.look(of: object, chain: successorChain, styles: styles, state: state)
            let bake = GraphicStyleFields.differences(now.look, after.look).subtracting(now.own)
            try GraphicStyleFields.write(now.look, categories: bake, into: .object(object, kind), state: state, builder: &builder)
            builder.append(Ops.set(object, [GraphicStyleFields.objectStyle(kind)], values: NodeValues.common(kind: kind) { common in
                if let successor { common.style.id = successor.proto }
            }))
        }
        for child in GraphicStyleFields.styles(in: state, styles) where child != style && styles.parent(of: child) == style {
            let now = StyleStacks.look(chain: styles.chain(of: child), styles: styles, state: state)
            let after = StyleStacks.look(chain: [child] + (parent.map(styles.chain) ?? []), styles: styles, state: state)
            builder.append(Ops.set(child, [GraphicStyleFields.basedOn], values: GraphicStyleFields.values { props in
                if let parent { props.basedOn.id = parent.proto }
            }))
            try GraphicStyleFields.fold(now.look, categories: GraphicStyleFields.differences(now.look, after.look), into: child, styles: styles,
                                        state: state, builder: &builder)
        }
        builder.append(Ops.setDeleted(style))
    }
}

/// menu:Options[Remove Unused]: deletes every live graphic style no object uses, directly or as
/// the ancestor of a style in use, computed from the style-to-objects index at the moment of the
/// command.  Normal stays.  "Remove unused styles".
public struct RemoveUnusedGraphicStyles: Command {
    public var label: String { "Remove unused styles" }

    public init() {}

    /// The styles the command removes (the sheet's list), in panel order.
    public static func unused(in state: EngineState) -> [OpID] {
        let styles = GraphicStyleResolver(state)
        var used: Set<OpID> = []
        for style in styles.index(in: state).keys { used.formUnion(styles.chain(of: style)) }
        return GraphicStyleFields.styles(in: state, styles).filter { !used.contains($0) && styles.role(of: $0) != .normal }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for style in Self.unused(in: state) {
            builder.append(Ops.setDeleted(style))
        }
    }
}

/// The Style Behavior sheet's *Parent* pop-up (styles.adoc, "Basing one style on another"):
/// sets `based_on`, refusing a parent that would make the style its own ancestor; *None*
/// detaches the style, which keeps what it inherited as its own.  Normal takes no parent.
/// "Style behavior".
public struct SetGraphicStyleParent: Command {
    public var style: OpID
    public var parent: OpID?
    public var label: String { "Style behavior" }

    public init(_ style: OpID, parent: OpID?) {
        self.style = style
        self.parent = parent
    }

    /// The styles the pop-up offers for `style`: every live graphic style but those that would
    /// form a loop (the style itself and its descendants).
    public static func candidates(for style: OpID, in state: EngineState) -> [OpID] {
        let styles = GraphicStyleResolver(state)
        return GraphicStyleFields.styles(in: state, styles).filter { !styles.chain(of: $0).contains(style) }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let styles = GraphicStyleResolver(state)
        _ = try GraphicStyleFields.style(style, in: styles)
        if let parent {
            guard styles.role(of: style) != .normal else { throw GraphicStyleError.normal }
            _ = try GraphicStyleFields.style(parent, in: styles)
            guard !styles.chain(of: parent).contains(style) else { throw GraphicStyleError.loop(parent) }
        } else {
            let now = StyleStacks.look(chain: styles.chain(of: style), styles: styles, state: state)
            let own = StyleStacks.look(chain: [style], styles: styles, state: state)
            try GraphicStyleFields.fold(now.look, categories: GraphicStyleFields.differences(now.look, own.look), into: style, styles: styles,
                                        state: state, builder: &builder)
        }
        builder.append(Ops.set(style, [GraphicStyleFields.basedOn], values: GraphicStyleFields.values { props in
            if let parent { props.basedOn.id = parent.proto }
        }))
    }
}

/// The Style Behavior sheet's categories: which attributes the style governs.  Each category is
/// its own register (STRUCT), and only the ones that change are written, so two people toggling
/// different boxes keep both.  At least one category stays checked.  "Style behavior".
public struct SetGraphicStyleBehavior: Command {
    public var style: OpID
    public var governs: Set<StyleCategory>
    public var label: String { "Style behavior" }

    public init(_ style: OpID, governs: Set<StyleCategory>) {
        self.style = style
        self.governs = governs
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !governs.isEmpty else { throw GraphicStyleError.invalidValue("governs") }
        let stored = try GraphicStyleFields.style(style, in: GraphicStyleResolver(state)).behavior
        let target = GraphicStyleFields.behavior(governs)
        let changed = StyleCategory.allCases.filter { stored[keyPath: GraphicStyleFields.keyPath($0)] != target[keyPath: GraphicStyleFields.keyPath($0)] }
        guard !changed.isEmpty else { return }
        builder.append(Ops.set(style, changed.map { GraphicStyleFields.behavior.child(GraphicStyleFields.behaviorField($0)) },
                               values: GraphicStyleFields.values { $0.behavior = target }))
    }
}

/// Clicking a style with nothing selected (styles.adoc, "Modifying and redefining styles"): the
/// style's resolved look becomes the document's default attributes and `defaults.style` records
/// it, so the plus sign can be computed (`GraphicStyleDefaults.isModified`) and *Redefine* knows
/// its target.  "Default attributes".
public struct SelectGraphicStyleAsDefaults: Command {
    public var style: OpID
    public var label: String { "Default attributes" }

    public init(_ style: OpID) {
        self.style = style
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let styles = GraphicStyleResolver(state)
        _ = try GraphicStyleFields.style(style, in: styles)
        let look = StyleStacks.look(chain: styles.chain(of: style), styles: styles, state: state).look
        try StyleStacks.replace(.defaults, with: look.stack, state: state, builder: &builder)
        var props = Wiretuner_Doc_V1_NodeProps()
        props.settings.defaults.style.id = style.proto
        builder.append(Ops.set(WellKnown.settings, [RegisterPath([2, 10, 2])], values: props))
    }
}

/// The plus signs of the Styles panel (styles.adoc, "Overrides", "Modifying and redefining
/// styles").
public enum GraphicStyleDefaults {
    /// The style the default attributes mirror (unset, dangling or not a graphic style: Normal).
    public static func style(in state: EngineState) -> OpID? {
        let styles = GraphicStyleResolver(state)
        let stored = state.props(WellKnown.settings).settings.defaults
        if stored.hasStyle, styles.isGraphic(OpID(stored.style.id)), styles.isLive(OpID(stored.style.id)) { return OpID(stored.style.id) }
        return styles.normal
    }

    /// Whether the default attributes differ from the style they mirror: the plus sign beside
    /// that style with nothing selected.
    public static func isModified(in state: EngineState) -> Bool {
        guard let style = style(in: state) else { return false }
        let styles = GraphicStyleResolver(state)
        let look = StyleStacks.look(chain: styles.chain(of: style), styles: styles, state: state).look
        let defaults = StyleStacks.canonical(StyleStacks.entries(.defaults, in: state), source: WellKnown.settings)
        return defaults.map(StyleStacks.content) != look.stack.map(StyleStacks.content)
    }

    /// Whether `object` overrides its style (the plus sign beside the style with the object
    /// selected, the Object panel's dots): the categories it overrides.
    public static func overrides(of object: OpID, in state: EngineState) -> Set<StyleCategory> {
        let styles = GraphicStyleResolver(state)
        guard let style = styles.style(of: object, in: state) else { return [] }
        return styles.ownCategories(of: object, in: state).intersection(styles.resolved(style)?.governs ?? [])
    }
}
