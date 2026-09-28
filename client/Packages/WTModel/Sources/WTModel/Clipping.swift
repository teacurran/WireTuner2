import WTCRDT
import WTGeometry
import WTProto

/// Reading clip groups (OBJ-027, clipping-paths.adoc "Data model"): a `GroupProps` of kind CLIP
/// whose `clip_path` names the clipping shape among its children.
public enum ClipGroups {
    /// `GroupProps.clip_path` (field 4 of `GroupProps`).
    public static let clipPathField = RegisterPath([NodeKind.group.rawValue, 4])

    /// Whether `node` can be a clipping path: a live path whose contours are all closed (a
    /// composite path joined before), or a rectangle, ellipse (not an open arc) or polygon.  Open
    /// paths, text and bitmaps cannot.
    public static func canClip(_ node: OpID, in state: EngineState) -> Bool {
        guard state.isLive(node) else { return false }
        switch state.nodeKind(node) {
        case .rect?, .polygon?:
            return true
        case .ellipse?:
            // An open arc has no inside (DRAW-061).
            let arc = EllipseArc(state.props(node).ellipse)
            return arc.isWhole || !arc.open
        case .path?:
            let contours = VectorPath(state.props(node).path, node: node, state: state).contours.filter(\.isRenderable)
            return !contours.isEmpty && contours.allSatisfy(\.closed)
        default:
            return false
        }
    }

    /// Whether `node` is a live group of kind CLIP.
    public static func isClipGroup(_ node: OpID, in state: EngineState) -> Bool {
        state.isLive(node) && state.nodeKind(node) == .group && state.props(node).group.kind == .clip
    }

    /// The clip path the group clips with, as read (clipping-paths.adoc, "Read-time
    /// normalizations"): nil -- contents unclipped -- when `clip_path` is unset or dangling, or
    /// names a node that is not a live child of the group able to clip.
    public static func clipPath(of group: OpID, in state: EngineState) -> OpID? {
        guard isClipGroup(group, in: state) else { return nil }
        let props = state.props(group).group
        guard props.hasClipPath else { return nil }
        let clip = OpID(props.clipPath.id)
        guard Objects.parent(of: clip, in: state) == group, canClip(clip, in: state) else { return nil }
        return clip
    }

    /// The live children of a clip group other than its clip path, bottom first.
    public static func contents(of group: OpID, in state: EngineState) -> [OpID] {
        let clip = clipPath(of: group, in: state)
        return state.liveChildren(group).filter { $0 != clip }
    }

    /// The clip group `node` pastes contents into: `node` itself when it is a clip group, or the
    /// group whose clip path `node` is; nil otherwise.
    static func target(_ node: OpID, in state: EngineState) -> OpID? {
        if isClipGroup(node, in: state) { return node }
        if let parent = Objects.parent(of: node, in: state), clipPath(of: parent, in: state) == node { return parent }
        return nil
    }
}

/// menu:Edit[Paste Contents] (OBJ-027, clipping-paths.adoc "Data model"): pastes the payload's
/// objects inside a closed path at their copied pasteboard positions.  On a plain path `P`: a clip
/// group created at `P`'s slot (identity transform, `clip_path` = `P`), `P` moved into it as its
/// first child, then the contents after `P`.  On a clip group (or its clip path): the contents
/// only, on top of the existing ones.  One change "Paste contents".  Refused (no change) for an
/// open path, text, a bitmap, a locked target or an empty payload.
public struct PasteContents: Command {
    public var payload: ClipboardPayload
    public var target: OpID
    public var label: String { "Paste contents" }

    public init(_ payload: ClipboardPayload, into target: OpID) {
        self.payload = payload
        self.target = target
    }

    /// Whether Paste Contents is enabled for `node`.
    public static func accepts(_ node: OpID, in state: EngineState) -> Bool {
        guard !Objects.editable([node], in: state).isEmpty else { return false }
        return ClipGroups.target(node, in: state) != nil || ClipGroups.canClip(node, in: state)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !payload.isEmpty, Self.accepts(target, in: state) else { return }
        let group: OpID
        let space: AffineTransform
        let lowest: [UInt8]?
        if let existing = ClipGroups.target(target, in: state) {
            group = existing
            space = Objects.pasteboardTransform(ofSpace: existing, in: state)
            lowest = state.store.children(existing).last.flatMap { state.store.placement($0)?.position }
        } else {
            let parent = Objects.parent(of: target, in: state)!
            var props = Wiretuner_Doc_V1_NodeProps()
            props.group.kind = .clip
            props.group.clipPath.id = target.proto
            let key = try Arranging.keys(next: target, above: true, count: 1, in: state)[0]
            group = builder.append(Ops.create(parent: parent, position: key, props: props))
            let first = try PathEditing.keys(between: nil, and: nil, count: 1)[0]
            builder.append(Ops.move(target, parent: group, position: first))
            space = Objects.pasteboardTransform(ofSpace: parent, in: state)
            lowest = first
        }
        let keys = try PathEditing.keys(between: lowest, and: nil, count: payload.nodes.count)
        var mapping: [OpID: OpID] = [:]
        let toGroup = space.inverse
        let placed = payload.nodes.map { tree -> NodeTree in
            var copy = tree
            copy.transform = tree.transform.concatenating(toGroup)
            return copy
        }
        for (tree, key) in zip(placed, keys) {
            _ = try NodeCopier.create(tree, parent: group, position: key, schema: state.schema, builder: &builder, mapping: &mapping)
        }
        NodeCopier.rewriteReferences(in: placed, mapping: mapping, builder: &builder)
    }
}

/// menu:Edit[Cut Contents] (OBJ-027, clipping-paths.adoc "Data model"): the document half -- the
/// caller first puts `payload(of:in:)` on the pasteboard.  The clip path moves back to the
/// group's slot in the group's parent with the group's matrix baked into its own (`P.transform`
/// followed by `G.transform`), the group and every content node are deleted.  With no live clip
/// path the contents and the group are deleted.  One change "Cut contents"; refused for anything
/// that is not an unlocked clip group (or its clip path).
public struct CutContents: Command {
    public var group: OpID
    public var label: String { "Cut contents" }

    public init(_ group: OpID) {
        self.group = group
    }

    /// The clipboard payload of the contents `node`'s clip group holds (what Cut Contents puts on
    /// the pasteboard); nil when `node` is not a clip group or its clip path.
    public static func payload(of node: OpID, in state: EngineState, document: String = "") -> ClipboardPayload? {
        guard let group = ClipGroups.target(node, in: state) else { return nil }
        return ClipboardPayload(copying: ClipGroups.contents(of: group, in: state), from: state, document: document)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let group = ClipGroups.target(group, in: state), !Objects.editable([group], in: state).isEmpty,
              let parent = Objects.parent(of: group, in: state) else { return }
        if let clip = ClipGroups.clipPath(of: group, in: state) {
            let key = try Arranging.keys(next: group, above: true, count: 1, in: state)[0]
            builder.append(Ops.move(clip, parent: parent, position: key))
            let baked = Objects.transform(of: clip, in: state).concatenating(Objects.transform(of: group, in: state))
            builder.append(Objects.setTransform(clip, kind: state.nodeKind(clip)!, baked))
        }
        builder.append(Ops.setDeleted(group))
        for content in ClipGroups.contents(of: group, in: state) {
            builder.append(Ops.setDeleted(content))
        }
    }
}

/// menu:Modify[Clipping > Release Contents] (OBJ-060, clipping-paths.adoc "To take the contents
/// out"): puts a clip group's contents back on the page without the clipboard.  The clip path
/// moves to the group's slot in its parent as a plain path and the contents follow above it in
/// their stacking order, each with the group's transform baked into its own (`child × G`); the
/// group is deleted.  With no usable clip path every live child is released the same way.  One
/// change "Release Contents" over every selected clip group (or clip path); anything else is
/// skipped, and locked groups are left alone.
public struct ReleaseContents: Command {
    public var nodes: [OpID]
    public var label: String { "Release Contents" }

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    /// The clip groups `nodes` release: each clip group, or the group of a clip path, once.
    public static func groups(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        var seen = Set<OpID>()
        return nodes.compactMap { ClipGroups.target($0, in: state) }.filter { seen.insert($0).inserted }
    }

    /// Whether Release Contents has anything to do for `nodes`.
    public static func canPerform(_ nodes: [OpID], in state: EngineState) -> Bool {
        !Objects.editable(groups(nodes, in: state), in: state).isEmpty
    }

    /// The nodes the release puts on the page, bottom first (the clip path, then the contents).
    public static func released(_ group: OpID, in state: EngineState) -> [OpID] {
        let clip = ClipGroups.clipPath(of: group, in: state)
        return (clip.map { [$0] } ?? []) + state.liveChildren(group).filter { $0 != clip && state.nodeKind($0) != .layer }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for group in Objects.editable(Self.groups(nodes, in: state), in: state) {
            guard let parent = Objects.parent(of: group, in: state) else { continue }
            let members = Self.released(group, in: state)
            let groupTransform = Objects.transform(of: group, in: state)
            let keys = try Arranging.keys(next: group, above: true, count: max(members.count, 1), in: state)
            for (member, key) in zip(members, keys) {
                guard let kind = state.nodeKind(member) else { continue }
                builder.append(Objects.setTransform(member, kind: kind, Objects.transform(of: member, in: state).concatenating(groupTransform)))
                builder.append(Ops.move(member, parent: parent, position: key))
            }
            builder.append(Ops.setDeleted(group))
        }
    }
}

/// *Choose clip path…* (OBJ-027, clipping-paths.adoc "Merge semantics", Delete P): names a live
/// child of a clip group that can clip as its clip path -- one register write, "Choose clip
/// path".  Refused for anything else.
public struct ChooseClipPath: Command {
    public var group: OpID
    public var path: OpID
    public var label: String { "Choose clip path" }

    public init(_ group: OpID, path: OpID) {
        self.group = group
        self.path = path
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard ClipGroups.isClipGroup(group, in: state), !Objects.editable([group], in: state).isEmpty,
              Objects.parent(of: path, in: state) == group, ClipGroups.canClip(path, in: state) else { return }
        var props = Wiretuner_Doc_V1_NodeProps()
        props.group.clipPath.id = path.proto
        builder.append(Ops.set(group, [ClipGroups.clipPathField], values: props))
    }
}
