import WTCRDT
import WTGeometry
import WTProto

// TYPE-041: attaching text to a path, flowing it inside one and detaching (type/text-on-path.adoc,
// "Data model", "Merge semantics").  The path becomes the text node's child -- `MoveNode(path
// under text)` plus a whole-STRUCT write of `TextProps.on_path` -- so the pair moves, deletes,
// copies and stacks as one object; detaching moves it back out beside the text and clears
// `on_path`.  How it draws is `TextLayoutReading.pathText`.

/// Register paths of `TextOnPathProps`.
public enum TextOnPathFields {
    /// `TextProps.on_path` (STRUCT).
    public static let onPath = RegisterPath([TextFields.kind, 6])
    /// `TextProps.block.width` and `auto_width`.
    static let blockWidth = RegisterPath([TextFields.kind, 3, 3])
    static let blockAutoWidth = RegisterPath([TextFields.kind, 3, 1])
}

/// Why a text-on-path command refused.
public enum TextOnPathError: Error, Equatable, Sendable {
    /// Not a live, editable text node.
    case notText(OpID)
    /// Not a live, editable `path` node (rectangles, ellipses and polygons are converted to paths
    /// first, menu:Modify[Ungroup]).
    case notAPath(OpID)
    /// The text is already on a path: detach it first.
    case alreadyOnPath(OpID)
    /// The text is not on a path.
    case notOnPath(OpID)
}

/// menu:Text[Attach to Path] (kbd:[Cmd+Shift+Y]) and menu:Text[Flow Inside Path]: path `path`
/// moves under text `text` (keeping its place on the page) and `on_path` is written whole --
/// `mode`, rotated glyphs, both runs on the baseline, the path hidden, no offsets -- so any
/// settings left from an earlier attachment are cleared.  One change, labelled "Attach to path" or
/// "Flow inside path".
public struct AttachTextToPath: Command {
    public var text: OpID
    public var path: OpID
    public var mode: Wiretuner_Doc_V1_PathTextMode

    public init(text: OpID, path: OpID, mode: Wiretuner_Doc_V1_PathTextMode = .along) {
        self.text = text
        self.path = path
        self.mode = mode
    }

    /// The text and path of a two-object selection, whichever order; nil unless it is one text
    /// node and one path.
    public static func pair(_ nodes: [OpID], in state: EngineState) -> (text: OpID, path: OpID)? {
        guard nodes.count == 2 else { return nil }
        let kinds = nodes.map { state.nodeKind($0) }
        if kinds == [.text, .path] { return (nodes[0], nodes[1]) }
        if kinds == [.path, .text] { return (nodes[1], nodes[0]) }
        return nil
    }

    public var label: String { mode == .inside ? "Flow inside path" : "Attach to path" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard state.nodeKind(text) == .text, Objects.editable([text], in: state) == [text] else { throw TextOnPathError.notText(text) }
        guard state.nodeKind(path) == .path, Objects.editable([path], in: state) == [path] else { throw TextOnPathError.notAPath(path) }
        if let node = TextNode(text, in: state), TextLayoutReading.path(of: node, in: state) != nil { throw TextOnPathError.alreadyOnPath(text) }
        // The path keeps its place on the page: its chain to the pasteboard is re-expressed under
        // the text.
        let flattened = Objects.transform(of: path, in: state).concatenating(Objects.parentTransform(of: path, in: state))
            .concatenating(Objects.pasteboardTransform(of: text, in: state).inverse)
        if flattened != Objects.transform(of: path, in: state) { builder.append(Objects.setTransform(path, kind: .path, flattened)) }
        builder.append(Ops.move(path, parent: text, position: try PathEditing.topPosition(in: text, state: state)))
        var values = Wiretuner_Doc_V1_NodeProps()
        values.text.onPath.mode = mode
        values.text.onPath.orientation = .rotate
        values.text.onPath.top = .baseline
        values.text.onPath.bottom = .baseline
        builder.append(Ops.set(text, [TextOnPathFields.onPath], values: values))
    }
}

/// menu:Text[Detach from Path]: for each selected text on a path (or its path), the path -- and
/// any further `path` children a concurrent attach left -- moves out beside the text, just below
/// it, keeping its place on the page, and `on_path` is cleared.  The text becomes a block as wide
/// as the path; transformations applied while joined are removed from it (it keeps only its
/// position).  One change, labelled "Detach from path".
public struct DetachTextFromPath: Command {
    public var nodes: [OpID]

    public init(_ nodes: [OpID]) {
        self.nodes = nodes
    }

    public var label: String { "Detach from path" }

    /// The texts `nodes` name: a text node itself, or the text a path is attached to.
    static func texts(_ nodes: [OpID], in state: EngineState) -> [OpID] {
        var seen: Set<OpID> = []
        return nodes.compactMap { node -> OpID? in
            if state.nodeKind(node) == .text { return node }
            guard state.nodeKind(node) == .path, let parent = Objects.parent(of: node, in: state), state.nodeKind(parent) == .text else { return nil }
            return parent
        }.filter { seen.insert($0).inserted }
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        for text in Self.texts(nodes, in: state) {
            guard Objects.editable([text], in: state) == [text], let node = TextNode(text, in: state) else { throw TextOnPathError.notText(text) }
            guard node.props.hasOnPath else { throw TextOnPathError.notOnPath(text) }
            let parent = Objects.parent(of: text, in: state)!
            let textTransform = Objects.transform(of: text, in: state)
            let paths = state.liveChildren(text).filter { state.nodeKind($0) == .path }
            let keys = try Arranging.keys(next: text, above: false, count: paths.count, in: state)
            var width: Double?
            for (path, key) in zip(paths, keys) {
                let moved = Objects.transform(of: path, in: state).concatenating(textTransform)
                if moved != Objects.transform(of: path, in: state) { builder.append(Objects.setTransform(path, kind: .path, moved)) }
                builder.append(Ops.move(path, parent: parent, position: key))
                if width == nil, let bounds = Self.bounds(path, transform: moved, in: state) { width = bounds.width }
            }
            // Only the translation stays; the block takes the path's width.
            let placed = AffineTransform.translation(x: textTransform.tx, y: textTransform.ty)
            if placed != textTransform { builder.append(Objects.setTransform(text, kind: .text, placed)) }
            if let width, width > 0 {
                var values = Wiretuner_Doc_V1_NodeProps()
                values.text.block.width = width
                builder.append(Ops.set(text, [TextOnPathFields.blockWidth, TextOnPathFields.blockAutoWidth], values: values))
            }
            builder.append(Ops.set(text, [TextOnPathFields.onPath], values: Wiretuner_Doc_V1_NodeProps.with { $0.text = Wiretuner_Doc_V1_TextProps() }))
        }
    }

    /// The path's control bounds under `transform` (in its new parent's space).
    static func bounds(_ path: OpID, transform: AffineTransform, in state: EngineState) -> Rect? {
        guard let local = Objects.localPath(path, in: state)?.controlBounds else { return nil }
        return local.applying(transform)
    }
}
