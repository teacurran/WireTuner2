import WTCRDT
import WTGeometry
import WTProto

// Linked text flows (TYPE-007, text-blocks.adoc, "Linking text blocks", "Merge semantics",
// "Read-time normalizations").  `TextProps.next_link` and `prev_link` are written on both nodes in
// one change; the chain is read from them with the normalizations below, never repaired.

/// Register paths of the link fields.
public enum TextLinkFields {
    /// `TextProps.next_link`.
    public static let next = RegisterPath([NodeKind.text.rawValue, 4])
    /// `TextProps.prev_link`.
    public static let previous = RegisterPath([NodeKind.text.rawValue, 5])
}

/// Reading linked flows.  A link X → Y holds when X's `next_link` names a live text node Y (not X)
/// whose `prev_link` names X back: a `next_link` to a deleted, unknown or non-text node reads
/// unset, and so does one whose target's `prev_link` names someone else (after two concurrent links
/// to the same block, the target follows the block its `prev_link` won for, and a target whose
/// `prev_link` names a block that no longer links to it is a head).  Every block then has at most
/// one link in and one out, so the links form simple chains and cycles; a cycle is cut by reading
/// the link out of its member with the smallest node id as unset.
public enum TextChains {
    /// The node `node`'s `next_link` names, when it is a live text node other than `node`.
    static func storedNext(_ node: OpID, in state: EngineState) -> OpID? {
        target(state.props(node).text.nextLink, from: node, in: state)
    }

    /// The node `node`'s `prev_link` names, when it is a live text node other than `node`.
    static func storedPrevious(_ node: OpID, in state: EngineState) -> OpID? {
        target(state.props(node).text.prevLink, from: node, in: state)
    }

    static func target(_ ref: Wiretuner_Doc_V1_NodeRef, from node: OpID, in state: EngineState) -> OpID? {
        guard ref.hasID else { return nil }
        let id = OpID(ref.id)
        guard id != node, state.isLive(id), state.nodeKind(id) == .text else { return nil }
        return id
    }

    /// The reciprocal link out of `node`, before cycles are cut.
    static func reciprocalNext(_ node: OpID, in state: EngineState) -> OpID? {
        guard state.nodeKind(node) == .text, let next = storedNext(node, in: state), storedPrevious(next, in: state) == node else { return nil }
        return next
    }

    /// The members of the cycle through `node`, or nil when `node` is on no cycle.
    static func cycle(through node: OpID, in state: EngineState) -> [OpID]? {
        var members = [node]
        var current = node
        while let next = reciprocalNext(current, in: state) {
            if next == node { return members }
            // In-degree is at most one, so a walk that leaves `node` never meets a cycle without it;
            // the bound is a guard only.
            guard members.count < 100_000 else { return nil }
            members.append(next)
            current = next
        }
        return nil
    }

    /// The block `node`'s text flows on into, as read (the normalizations above).
    public static func next(_ node: OpID, in state: EngineState) -> OpID? {
        guard let next = reciprocalNext(node, in: state) else { return nil }
        if let members = cycle(through: node, in: state), members.min() == node { return nil }
        return next
    }

    /// The block whose text flows into `node`, as read.
    public static func previous(_ node: OpID, in state: EngineState) -> OpID? {
        guard state.nodeKind(node) == .text, let previous = storedPrevious(node, in: state), next(previous, in: state) == node else { return nil }
        return previous
    }

    /// Whether `node`'s own link out was cut to break a cycle (it shows the overflow dot).
    public static func isCut(_ node: OpID, in state: EngineState) -> Bool {
        reciprocalNext(node, in: state) != nil && next(node, in: state) == nil
    }

    /// The head of `node`'s chain: the block that owns the flow's text.
    public static func head(of node: OpID, in state: EngineState) -> OpID {
        var current = node
        while let previous = previous(current, in: state) { current = previous }
        return current
    }

    /// The chain `node` is in, from its head, in flow order; `[node]` for a block in no chain.
    public static func chain(of node: OpID, in state: EngineState) -> [OpID] {
        var members = [head(of: node, in: state)]
        while let next = next(members.last!, in: state) { members.append(next) }
        return members
    }

    /// Whether `node` is in a chain of two or more blocks.
    public static func isLinked(_ node: OpID, in state: EngineState) -> Bool {
        next(node, in: state) != nil || previous(node, in: state) != nil
    }

    /// Whether `node` is a chain member other than the head, whose own text is dormant.
    public static func isDormant(_ node: OpID, in state: EngineState) -> Bool {
        previous(node, in: state) != nil
    }

    // MARK: Writing

    /// A `SetFields` of `node`'s link field `path` to `target` (nil clears it).
    static func set(_ node: OpID, _ path: RegisterPath, to target: OpID?) -> Wiretuner_Doc_V1_Op {
        var values = Wiretuner_Doc_V1_NodeProps()
        values.text = Wiretuner_Doc_V1_TextProps()
        if let target {
            if path == TextLinkFields.next { values.text.nextLink.id = target.proto } else { values.text.prevLink.id = target.proto }
        }
        return Ops.set(node, [path], values: values)
    }

    /// The ops that close the gaps deleting `deleted` leaves (text-blocks.adoc, "Deleting a block
    /// in the middle of a chain closes the gap"): for each run of deleted members with a surviving
    /// block before it, that block links to the next surviving block after the run (both
    /// registers), or its link is cleared when none survives after.  A deleted head needs nothing:
    /// its successor's `prev_link` names a deleted node and reads unset.
    static func splice(deleting deleted: Set<OpID>, in state: EngineState) -> [Wiretuner_Doc_V1_Op] {
        var ops: [Wiretuner_Doc_V1_Op] = []
        for node in deleted.sorted() {
            guard let before = previous(node, in: state), !deleted.contains(before) else { continue }
            var after = next(node, in: state)
            while let current = after, deleted.contains(current) { after = next(current, in: state) }
            ops.append(set(before, TextLinkFields.next, to: after))
            if let after { ops.append(set(after, TextLinkFields.previous, to: before)) }
        }
        return ops
    }

    /// The text nodes at or under `node`.
    static func textNodes(at node: OpID, in state: EngineState) -> [OpID] {
        (state.nodeKind(node) == .text ? [node] : []) + state.liveChildren(node).flatMap { textNodes(at: $0, in: state) }
    }
}

/// Why a link command refused.
public enum TextLinkError: Error, Equatable {
    /// Not a live, editable text block (text on a path cannot start a link).
    case notABlock(OpID)
    /// The target is not an empty text block or a path that can hold text.
    case invalidTarget(OpID)
    /// The link would close a loop.
    case loop(OpID)
}

/// Dragging from a block's link box onto another block or a path (text-blocks.adoc, "Linking text
/// blocks"): `from`'s overflow flows on into `to`.  One change "Link text blocks": `from.next_link
/// = to` and `to.prev_link = from`; the block `from` linked to before (if any) has its
/// `prev_link` cleared, and the block that linked to `to` before (if any) its `next_link`.  The
/// target must be an empty text block, or a path: then a new text node takes the path's slot with
/// the path moved under it and `on_path` set to flow inside it, and that node is linked (the path
/// keeps the text settings it acquires).  A target already upstream of `from` is refused (it would
/// close a loop).
public struct LinkTextBlocks: Command {
    public var from: OpID
    public var to: OpID

    public init(from: OpID, to: OpID) {
        self.from = from
        self.to = to
    }

    public var label: String { "Link text blocks" }

    /// Whether `from` can link onward: a live, editable text block that is not on a path.
    public static func canStart(_ from: OpID, in state: EngineState) -> Bool {
        guard state.nodeKind(from) == .text, Objects.editable([from], in: state) == [from], let text = TextNode(from, in: state) else { return false }
        // Text along a path has no link box; text flowing inside one does.
        return text.props.onPath.mode == .inside || TextLayoutReading.path(of: text, in: state) == nil
    }

    /// Whether `to` can take `from`'s overflow.
    public static func canLink(from: OpID, to: OpID, in state: EngineState) -> Bool {
        (try? check(from: from, to: to, in: state)) != nil
    }

    static func check(from: OpID, to: OpID, in state: EngineState) throws(TextLinkError) {
        guard canStart(from, in: state) else { throw .notABlock(from) }
        guard to != from, Objects.editable([to], in: state) == [to] else { throw .invalidTarget(to) }
        switch state.nodeKind(to) {
        case .text:
            guard let text = TextNode(to, in: state), text.length == 0 else { throw .invalidTarget(to) }
            var current: OpID? = from
            while let node = current {
                if node == to { throw .loop(to) }
                current = TextChains.previous(node, in: state)
            }
        case .path:
            // A path already holding text is that text's; it cannot take a second flow.
            guard let parent = Objects.parent(of: to, in: state), state.nodeKind(parent) != .text else { throw .invalidTarget(to) }
        default:
            throw .invalidTarget(to)
        }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try Self.check(from: from, to: to, in: state)
        var target = to
        if state.nodeKind(to) == .path {
            target = try Self.container(for: to, state: state, builder: &builder)
        } else if let before = TextChains.storedPrevious(to, in: state), before != from, TextChains.storedNext(before, in: state) == to {
            builder.append(TextChains.set(before, TextLinkFields.next, to: nil))
        }
        if let old = TextChains.storedNext(from, in: state), old != to, TextChains.storedPrevious(old, in: state) == from {
            builder.append(TextChains.set(old, TextLinkFields.previous, to: nil))
        }
        builder.append(TextChains.set(from, TextLinkFields.next, to: target))
        builder.append(TextChains.set(target, TextLinkFields.previous, to: from))
    }

    /// Creates the text node that makes `path` a text container: at the path's slot under its
    /// parent with the identity transform, `on_path` flowing inside, the path moved under it.
    static func container(for path: OpID, state: EngineState, builder: inout ChangeBuilder) throws -> OpID {
        let parent = Objects.parent(of: path, in: state)!
        var props = Wiretuner_Doc_V1_NodeProps()
        props.text.onPath.mode = .inside
        props.text.onPath.orientation = .rotate
        props.text.onPath.top = .baseline
        props.text.onPath.bottom = .baseline
        let key = try Arranging.keys(next: path, above: true, count: 1, in: state)[0]
        let text = builder.append(Ops.create(parent: parent, position: key, props: props))
        builder.append(Ops.move(path, parent: text, position: try PathEditing.keys(between: nil, and: nil, count: 1)[0]))
        return text
    }
}

/// Dragging a link line from its link box to an empty spot (text-blocks.adoc, "To break a link"):
/// `node`'s link out is cleared on both blocks; the text that had flowed on returns to the chain as
/// overflow.  One change "Unlink text blocks"; refused when `node` links nowhere.
public struct UnlinkTextBlocks: Command {
    public var node: OpID

    public init(_ node: OpID) {
        self.node = node
    }

    public var label: String { "Unlink text blocks" }

    /// Whether `node` has a link out to break.
    public static func canUnlink(_ node: OpID, in state: EngineState) -> Bool {
        state.nodeKind(node) == .text && Objects.editable([node], in: state) == [node] && state.props(node).text.hasNextLink
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard Self.canUnlink(node, in: state) else { throw TextLinkError.notABlock(node) }
        if let next = TextChains.storedNext(node, in: state), TextChains.storedPrevious(next, in: state) == node {
            builder.append(TextChains.set(next, TextLinkFields.previous, to: nil))
        }
        builder.append(TextChains.set(node, TextLinkFields.next, to: nil))
    }
}
