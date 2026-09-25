import WTCRDT
import WTProto

/// menu:Edit[Special > Copy Attributes] (OBJ-014, copying.adoc "Copying attributes"): the look of
/// one object -- its attribute stack (fills, strokes and effects, in stack order) and, for text,
/// the type attributes of its first character -- as a value the pasteboard carries.
///
/// On the pasteboard it is a `ClipboardPayload` holding a single `ClipboardNode` whose props carry
/// only the stack and the text attributes (copying.adoc, "Data model"), under its own type
/// `pasteboardType` so an attribute copy never pastes as an object.  The three lists of a
/// stack share one position space, which a typed `AppearanceProps` cannot show, so each copied
/// element's `id` is rewritten to its place in the stack (counter 1 = bottom, replica 0) and an
/// effect's `attached_to` to the place of the element it is attached to; the text attributes ride
/// as `RichText.marks` values without anchors.
public struct AttributePayload: Hashable, Sendable {
    /// The pasteboard type of an attribute copy.
    public static let pasteboardType = "com.villagecompute.wiretuner.attributes"

    /// One stack element, bottom first.
    public enum Element: Hashable, Sendable {
        case fill(Wiretuner_Doc_V1_Fill)
        case stroke(Wiretuner_Doc_V1_Stroke)
        case effect(Wiretuner_Doc_V1_Effect)

        var list: AppearanceList {
            switch self {
            case .fill: .fills
            case .stroke: .strokes
            case .effect: .effects
            }
        }
    }

    /// The stack, bottom first; nil when the source has no stack (a text block), so pasting leaves
    /// the targets' stacks alone.  Effects' `attached_to` name another element by its index + 1.
    public var stack: [Element]?
    /// The type attributes (one value per attribute); nil when the source is not text.
    public var textAttributes: [Wiretuner_Doc_V1_TextMarkValue]?

    public init(stack: [Element]?, textAttributes: [Wiretuner_Doc_V1_TextMarkValue]? = nil) {
        self.stack = stack
        self.textAttributes = textAttributes
    }

    /// The attributes of the object `node` as merged; nil when it has neither a stack nor text.
    public init?(copying node: OpID, from state: EngineState) {
        guard Objects.isObject(node, in: state) else { return nil }
        var stack: [Element]?
        // A text block's look is its type attributes; its block fills and strokes are not copied.
        if state.nodeKind(node) != .text, StackOwner.of(node, in: state) != nil, let appearance = StackOwner.appearance(node, in: state) {
            let rows = AppearanceEditing.stack(node, in: state)
            let place = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.element, UInt64($0.offset + 1)) })
            func renumbered(_ id: Wiretuner_Doc_V1_ElementId) -> Wiretuner_Doc_V1_ElementId {
                OpID(element: id).flatMap { place[$0] }.map { Ops.elementID(OpID(counter: $0, replica: 0)) } ?? .init()
            }
            stack = rows.map { row -> Element in
                switch row.list {
                case .fills:
                    var fill = appearance.fills.first { OpID(element: $0.id) == row.element }!
                    fill.id = renumbered(fill.id)
                    return .fill(fill)
                case .strokes:
                    var stroke = appearance.strokes.first { OpID(element: $0.id) == row.element }!
                    stroke.id = renumbered(stroke.id)
                    return .stroke(stroke)
                case .effects:
                    var effect = appearance.effects.first { OpID(element: $0.id) == row.element }!
                    effect.id = renumbered(effect.id)
                    if effect.hasAttachedTo { effect.attachedTo = renumbered(effect.attachedTo) }
                    return .effect(effect)
                }
            }
        }
        var text: [Wiretuner_Doc_V1_TextMarkValue]?
        if let node = state.textNode(node) {
            text = node.values(at: 0).filter(Self.isTypeAttribute)
        }
        guard stack != nil || text != nil else { return nil }
        self.init(stack: stack, textAttributes: text)
    }

    /// Whether a mark attribute is part of an object's look (what Copy Attributes carries): the
    /// font, size, spacing, colour, stroke, effect and style attributes -- not links, data fields,
    /// mentions, inline graphics, language or line-breaking controls, which belong to the words.
    public static func isTypeAttribute(_ value: Wiretuner_Doc_V1_TextMarkValue) -> Bool {
        switch value.value {
        case .fontFamily?, .fontStyle?, .size?, .leading?, .rangeKerning?, .baselineShift?, .horizontalScale?, .fill?, .stroke?,
             .effect?, .style?, .case?, .overprint?, .axes?, .feature?:
            true
        default:
            false
        }
    }

    // MARK: Pasteboard

    /// The payload as a `ClipboardPayload` (one node: a path's props holding the stack, or a text
    /// node's holding the attributes).
    public func clipboard(sourceDocument: String = "") -> ClipboardPayload {
        var props = Wiretuner_Doc_V1_NodeProps()
        if let textAttributes {
            props.text.text.marks = textAttributes.map { value in
                var mark = Wiretuner_Doc_V1_RichTextMark()
                mark.value = value
                return mark
            }
        }
        if let stack {
            var appearance = Wiretuner_Doc_V1_AppearanceProps()
            for element in stack {
                switch element {
                case .fill(let fill): appearance.fills.append(fill)
                case .stroke(let stroke): appearance.strokes.append(stroke)
                case .effect(let effect): appearance.effects.append(effect)
                }
            }
            if textAttributes != nil {
                props.text.blockAppearance = appearance
            } else {
                props.path.appearance = appearance
            }
        }
        return ClipboardPayload(nodes: [NodeTree(props: props)], sourceDocument: sourceDocument)
    }

    /// The attributes `payload` carries; nil when it is not an attribute copy.  A text node's
    /// `block_appearance` holds the stack of a text source that had one.
    public init?(_ payload: ClipboardPayload) {
        guard payload.nodes.count == 1, payload.nodes[0].children.isEmpty else { return nil }
        let props = payload.nodes[0].props
        let appearance: Wiretuner_Doc_V1_AppearanceProps?
        var text: [Wiretuner_Doc_V1_TextMarkValue]?
        switch props.kind {
        case .path(let path)?:
            appearance = path.appearance
        case .text(let node)?:
            text = node.text.marks.map(\.value)
            appearance = node.hasBlockAppearance ? node.blockAppearance : nil
        default:
            return nil
        }
        var stack: [Element]?
        if let appearance {
            let all: [(UInt64, Element)] = appearance.fills.map { ($0.id.counter, .fill($0)) } + appearance.strokes.map { ($0.id.counter, .stroke($0)) }
                + appearance.effects.map { ($0.id.counter, .effect($0)) }
            stack = all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        self.init(stack: stack, textAttributes: text)
    }
}

/// menu:Edit[Special > Paste Attributes] (OBJ-014, copying.adoc "Data model"): replaces the
/// attribute stack of each target with copies of the payload's -- an `ElementDelete` of every live
/// element, then an `ElementInsert` of each copy in stack order under a fresh element id (nested
/// sequences such as gradient stops after their element) -- and, on a text target, sets the
/// payload's type attributes over the whole text, clearing the ones the payload does not name.
/// A target that cannot take a part ignores it (a text block takes no object stack; a path no
/// type attributes).  One change: "Paste attributes" or "Paste attributes to N objects".
/// Locked objects are left alone.
public struct PasteAttributes: Command {
    public var payload: AttributePayload
    public var nodes: [OpID]
    public var label: String

    public init(_ payload: AttributePayload, to nodes: [OpID], in state: EngineState? = nil) {
        self.payload = payload
        self.nodes = nodes
        let count = state.map { state in Objects.editable(nodes, in: state).filter { Self.takes(payload, $0, in: state) }.count } ?? nodes.count
        label = count == 1 ? "Paste attributes" : "Paste attributes to \(count) objects"
    }

    /// Whether `node` takes some part of `payload`.
    static func takes(_ payload: AttributePayload, _ node: OpID, in state: EngineState) -> Bool {
        (payload.stack != nil && takesStack(node, in: state)) || (payload.textAttributes != nil && state.textNode(node) != nil)
    }

    /// Whether `node` takes a payload's stack: an object with one, not a text block.
    static func takesStack(_ node: OpID, in state: EngineState) -> Bool {
        StackOwner.of(node, in: state) != nil && state.nodeKind(node) != .text
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for node in Objects.editable(nodes, in: state) {
            if let stack = payload.stack, Self.takesStack(node, in: state), case .object(let kind)? = StackOwner.of(node, in: state) {
                try replaceStack(of: node, kind: kind, with: stack, state: state, builder: &builder)
            }
            if let attributes = payload.textAttributes, let text = state.textNode(node) {
                replaceTextAttributes(of: text, with: attributes, state: state, builder: &builder)
            }
        }
    }

    private func replaceStack(of node: OpID, kind: NodeKind, with stack: [AttributePayload.Element], state: EngineState,
                              builder: inout ChangeBuilder) throws {
        let owner = StackOwner.object(kind)
        let live = AppearanceEditing.stack(node, in: state).map { owner.sequence($0.list).element($0.element) }
        if !live.isEmpty { builder.append(Ops.elementDelete(node, live)) }
        try Self.insert(stack, into: node, kind: kind, schema: state.schema, builder: &builder)
    }

    /// Appends the ops inserting copies of `stack` (bottom first; effects' `attached_to` naming
    /// another element by its index + 1) into the empty stack of `node`, a node of `kind` -- possibly
    /// created earlier in the same change: one `ElementInsert` per element with positions in stack
    /// order, nested sequences (a gradient's stops) after their element, then each attached
    /// effect's `attached_to` pointed at the copy of its element.  What Join and Split copy an
    /// input's stack with, since a node copy's lists would each be positioned on their own.
    static func insert(_ stack: [AttributePayload.Element], into node: OpID, kind: NodeKind, schema: Schema,
                       builder: inout ChangeBuilder) throws {
        guard !stack.isEmpty else { return }
        let owner = StackOwner.object(kind)
        let appearanceField = NodeValues.appearanceField(kind)!
        let keys = try PathEditing.keys(between: nil, and: nil, count: stack.count)
        let stackType = schema.field(schema.field(Schema.root, Int(kind.rawValue))!.typeName!, Int(appearanceField))!.typeName!
        var inserted: [UInt64: OpID] = [:]
        var attachments: [(effect: OpID, target: UInt64)] = []
        for (index, (element, key)) in zip(stack, keys).enumerated() {
            var value = Wiretuner_Doc_V1_AppearanceProps()
            let body: [UInt8]
            switch element {
            case .fill(var fill):
                fill.clearID()
                value.fills = [fill]
                body = Wire.bytes { try fill.serializedBytes() }
            case .stroke(var stroke):
                stroke.clearID()
                value.strokes = [stroke]
                body = Wire.bytes { try stroke.serializedBytes() }
            case .effect(var effect):
                effect.clearID()
                effect.clearAttachedTo()
                value.effects = [effect]
                body = Wire.bytes { try effect.serializedBytes() }
            }
            let sequence = owner.sequence(element.list)
            let id = builder.append(Ops.elementInsert(node, sequence, positions: [key], values: owner.values(value)))
            inserted[UInt64(index + 1)] = id
            if case .effect(let effect) = element, effect.hasAttachedTo { attachments.append((id, effect.attachedTo.counter)) }
            let list = element.list.rawValue
            try NodeCopier.copySequences(schema.field(stackType, Int(list))!.typeName!, payload: body, prefix: sequence.element(id), node: node,
                                         schema: schema, wrap: {
                                             Wire.field(kind.rawValue, Wire.field(appearanceField, Wire.field(list, Wire.field(1, Wire.elementID(id)) + $0)))
                                         }, builder: &builder)
        }
        for attachment in attachments {
            guard let target = inserted[attachment.target] else { continue }
            var effect = Wiretuner_Doc_V1_Effect()
            effect.attachedTo = Ops.elementID(target)
            builder.append(Ops.set(node, [owner.sequence(.effects).element(attachment.effect).child(3)],
                                   values: owner.values(Wiretuner_Doc_V1_AppearanceProps.with { $0.effects = [effect] })))
        }
    }

    private func replaceTextAttributes(of text: TextNode, with attributes: [Wiretuner_Doc_V1_TextMarkValue], state: EngineState,
                                       builder: inout ChangeBuilder) {
        guard let first = text.chars.first, let last = text.chars.last else { return }
        let next = state.insertionOrigins(text.id, TextFields.text, at: text.length, stableSeq: 0).right
        // Clear the look attributes the target has and the payload does not name.
        let named = Set(attributes.map(AttributeKey.init))
        var cleared: Set<AttributeKey> = []
        for run in text.runs {
            for value in run.values where AttributePayload.isTypeAttribute(value) {
                let key = AttributeKey(value)
                guard !named.contains(key), cleared.insert(key).inserted else { continue }
                builder.append(TextEditing.mark(text.id, TextMarks.cleared(value), first: first, last: last, next: next))
            }
        }
        for value in attributes where AttributePayload.isTypeAttribute(value) {
            builder.append(TextEditing.mark(text.id, value, first: first, last: last, next: next))
        }
    }

    /// A mark attribute's identity: its case, and a feature's tag.
    private struct AttributeKey: Hashable {
        var field: Int
        var tag: String

        init(_ value: Wiretuner_Doc_V1_TextMarkValue) {
            let cleared = TextMarks.cleared(value)
            let bytes = Wire.bytes { try cleared.serializedBytes() }
            field = Int(WireReader.fields(bytes)!.first!.number)
            if case .feature(let feature)? = value.value { tag = feature.tag } else { tag = "" }
        }
    }
}
