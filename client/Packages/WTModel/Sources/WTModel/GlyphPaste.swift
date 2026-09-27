import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Paste into a glyph canvas (typeface-documents.adoc, "Paste into a glyph canvas"; FONT-004): the
/// pasteboard's objects arrive at one unit per point, and text blocks are converted to paths
/// first.  Laying text out needs the window's engine, so the app pastes the payload into a scratch
/// document (`scratch`), captures `TextToPaths.conversion` for its `textNodes`, and `outlined`
/// rebuilds the payload with each text block replaced by the group Convert to Paths would make --
/// then an ordinary `Paste` writes it, one change.
public enum GlyphPaste {
    /// `payload` pasted into an empty document at its copied position: the state and the pasted
    /// roots, in order.  The carried colours are left out, so references keep the source's ids
    /// (the real paste maps them).
    public static func scratch(_ payload: ClipboardPayload) throws -> (state: EngineState, roots: [OpID]) {
        var bare = payload
        bare.colors = []
        var core = DocumentCore(state: EngineState(), replica: 1)
        let outcome = try core.perform(Paste(bare), recording: DocumentCore.Recording(limit: 1, now: Date(timeIntervalSince1970: 0)))
        return (core.state, outcome?.change?.createdRoots ?? [])
    }

    /// The text blocks among `roots` of `state` and their descendants, in stacking order.
    public static func textNodes(_ roots: [OpID], in state: EngineState) -> [OpID] {
        var result: [OpID] = []
        func visit(_ node: OpID) {
            if state.nodeKind(node) == .text {
                result.append(node)
                return
            }
            state.liveChildren(node).forEach(visit)
        }
        roots.forEach(visit)
        return result
    }

    /// The payload rebuilt from `state`'s `roots` with each text block that has a conversion
    /// replaced by a group of its outlines (named after its first words) holding its inline
    /// graphics; everything else as copied.  With no conversion, `payload` itself.
    public static func outlined(_ payload: ClipboardPayload, scratch state: EngineState, roots: [OpID],
                                conversions: [OpID: TextConversion]) -> ClipboardPayload {
        guard !conversions.isEmpty else { return payload }
        func tree(_ node: OpID) -> NodeTree {
            if let conversion = conversions[node] { return group(conversion, in: state) }
            var copy = NodeTree(node, state: state)
            if !TextFields.isText(node, in: state) {
                copy.children = state.liveChildren(node).map(tree)
            }
            return copy
        }
        var result = payload
        result.nodes = roots.map(tree)
        return result
    }

    /// The group Convert to Paths makes of `conversion`, in the text's parent space.
    static func group(_ conversion: TextConversion, in state: EngineState) -> NodeTree {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.group.kind = .group
        props.group.common.name = conversion.name
        props.group.common.note = AccessibilityCheck.outlinedTextNote
        var children: [NodeTree] = []
        if let corners = conversion.block {
            var outline = DisplayPath()
            outline.move(to: corners[0])
            for corner in corners.dropFirst() { outline.addLine(to: corner) }
            outline.close()
            var appearance = state.props(conversion.node).text.blockAppearance
            appearance.effects = []
            children.append(path(ConvertedShape(path: outline, appearance: appearance)))
        }
        children += conversion.shapes.map(path)
        for (graphic, transform) in conversion.graphics where state.isLive(graphic) {
            var copy = NodeTree(graphic, state: state)
            copy.transform = transform
            children.append(copy)
        }
        return NodeTree(props: props, children: children)
    }

    /// A converted shape as a path node.
    static func path(_ shape: ConvertedShape) -> NodeTree {
        var props = Wiretuner_Doc_V1_NodeProps()
        props.path.contours = InlineShapes.contours(shape.path)
        props.path.appearance = shape.appearance
        return NodeTree(props: props)
    }
}

extension TextFields {
    /// Whether `node` is a text block (its children -- a path it follows, inline graphics -- go
    /// with it).
    static func isText(_ node: OpID, in state: EngineState) -> Bool { state.nodeKind(node) == .text }
}
