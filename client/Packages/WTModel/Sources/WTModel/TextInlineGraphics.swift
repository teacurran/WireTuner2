import WTCRDT
import WTGeometry
import WTProto
import WTRender
import WTText

// Inline graphics (TYPE-038; type/text-effects.adoc, "Inline graphics" and "Merge semantics"): a
// U+FFFC character with a non-expanding `inline_graphic` mark naming a child node of the text
// node.  The child is an ordinary object parented under the text node, drawn by the text layout
// at the glyph origin and never by the layer pass.

/// What a text node's layout reads besides the node itself (`TextLayoutReading.content`): the
/// document's text styles, its *Small caps size* and the node's inline graphics drawn.
public struct TextReadingContext: Sendable {
    public var styles: TextStyleResolver?
    /// Small capitals' fraction of the size.
    public var smallCapsSize: Double
    /// Each inline graphic child's drawing, in its own space.
    public var graphics: [OpID: InlineGraphic]

    public init(styles: TextStyleResolver? = nil, smallCapsSize: Double = TextAttributes.smallCapsScale, graphics: [OpID: InlineGraphic] = [:]) {
        self.styles = styles
        self.smallCapsSize = smallCapsSize
        self.graphics = graphics
    }

    /// The context of text node `node` in `state`.
    public init(_ node: OpID, in state: EngineState) {
        self.init(styles: TextStyleResolver(state), smallCapsSize: TextCaseSettings(state).smallCapsPercent / 100,
                  graphics: InlineGraphics.graphics(of: node, in: state))
    }
}

/// Reading a text node's inline graphics.
public enum InlineGraphics {
    /// The placeholder character.
    public static let placeholder: Unicode.Scalar = "\u{FFFC}"

    /// The inline graphics of `text`: each live U+FFFC's offset with the node its winning
    /// `inline_graphic` mark names, in text order.
    public static func placements(_ text: TextNode) -> [(offset: Int, graphic: OpID)] {
        var result: [(offset: Int, graphic: OpID)] = []
        for run in text.runs {
            for case .inlineGraphic(let ref)? in run.values.map(\.value) {
                for offset in run.range where text.scalar(at: offset) == placeholder {
                    result.append((offset, OpID(ref.id)))
                }
            }
        }
        return result
    }

    /// The drawing of each live child of `node` an inline graphic names, in the child's own space
    /// (its transform applied); a child the subtree renderer cannot draw, or a deleted one, is left
    /// out and draws the empty box.
    static func graphics(of node: OpID, in state: EngineState) -> [OpID: InlineGraphic] {
        guard let text = TextNode(node, in: state) else { return [:] }
        var result: [OpID: InlineGraphic] = [:]
        for (_, graphic) in placements(text) where result[graphic] == nil {
            guard state.isLive(graphic), state.store.placement(graphic)?.parent == node,
                  let item = SubtreeRendering.item(NodeTree(graphic, state: state), parent: .identity), let bounds = item.bounds else { continue }
            result[graphic] = InlineGraphic(bounds: bounds, items: [item])
        }
        return result
    }

    /// The mark value naming `graphic`.
    static func mark(_ graphic: OpID) -> Wiretuner_Doc_V1_TextMarkValue {
        var value = Wiretuner_Doc_V1_TextMarkValue()
        value.inlineGraphic.id = graphic.proto
        return value
    }

    /// The `TextInsert` of one U+FFFC between `origins` and its `inline_graphic` mark.
    static func insert(_ graphic: OpID, node: OpID, origins: (left: OpID, right: OpID), builder: inout ChangeBuilder) {
        let char = builder.append(Ops.textInsert(node, TextFields.text, String(placeholder), left: origins.left, right: origins.right))
        builder.append(TextEditing.mark(node, mark(graphic), first: char, last: char, next: origins.right))
    }

    /// The graphics whose every live placeholder lies in `range` of `text` -- the children a delete
    /// of the range removes with their characters.
    static func removed(by range: Range<Int>, in text: TextNode) -> [OpID] {
        let placements = placements(text)
        let inside = Set(placements.filter { range.contains($0.offset) }.map(\.graphic))
        let outside = Set(placements.filter { !range.contains($0.offset) }.map(\.graphic))
        return inside.subtracting(outside).sorted()
    }
}

/// menu:Edit[Special > Paste Special…] > *Inline graphic*: the copied objects become one inline
/// graphic at the caret -- a `CreateNode` of the object (several are grouped) under the text node,
/// the `TextInsert` of U+FFFC and its `inline_graphic` mark, in one change ("Paste").  The objects
/// keep their transformation; the graphic's own bounds decide its size on the line.
public struct PasteInlineGraphic: Command {
    public var node: OpID
    public var at: Anchor
    public var payload: ClipboardPayload
    public var label: String { "Paste" }

    public init(node: OpID, at: Anchor, payload: ClipboardPayload) {
        self.node = node
        self.at = at
        self.payload = payload
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !payload.nodes.isEmpty else { throw TextEditError.invalidValue("payload") }
        let text = try TextEditing.text(node, in: state)
        let offset = try text.offset(of: at)
        var tree: NodeTree
        if payload.nodes.count == 1 {
            tree = payload.nodes[0]
        } else {
            var group = Wiretuner_Doc_V1_NodeProps()
            group.group = Wiretuner_Doc_V1_GroupProps()
            tree = NodeTree(props: group, children: payload.nodes)
        }
        tree.source = nil
        let position = try PathEditing.topPosition(in: node, state: state)
        let graphic = try NodeCopier.create(tree, parent: node, position: position, schema: state.schema, builder: &builder)
        InlineGraphics.insert(graphic, node: node, origins: state.insertionOrigins(node, TextFields.text, at: offset, stableSeq: 0), builder: &builder)
    }
}

/// Pastes an inline graphic that was cut (or moves one between places): a `MoveNode` of the
/// graphic under the text node (restoring it when the cut deleted it) and a new U+FFFC with its
/// mark at the caret, in one change ("Paste").  A concurrent edit of the graphic follows it.
public struct PlaceInlineGraphic: Command {
    public var node: OpID
    public var at: Anchor
    public var graphic: OpID
    public var label: String { "Paste" }

    public init(node: OpID, at: Anchor, graphic: OpID) {
        self.node = node
        self.at = at
        self.graphic = graphic
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        let offset = try text.offset(of: at)
        guard state.store.exists(graphic), graphic != node, state.nodeKind(graphic) != nil else { throw TextEditError.invalidValue("graphic") }
        if state.store.placement(graphic)?.parent != node {
            builder.append(Ops.move(graphic, parent: node, position: try PathEditing.topPosition(in: node, state: state)))
        }
        if !state.isLive(graphic) { builder.append(Ops.setDeleted(graphic, false)) }
        InlineGraphics.insert(graphic, node: node, origins: state.insertionOrigins(node, TextFields.text, at: offset, stableSeq: 0), builder: &builder)
    }
}

/// *Restore* of an inline graphic deleted with its character (the notice, or the review sheet's
/// row, for an edit of a graphic someone deleted): writes `deleted = false` on the graphic and,
/// when no live U+FFFC names it, re-inserts one just after its tombstoned character with the mark,
/// in one change ("Restore").
public struct RestoreInlineGraphic: Command {
    public var node: OpID
    public var graphic: OpID
    public var label: String { "Restore" }

    public init(node: OpID, graphic: OpID) {
        self.node = node
        self.graphic = graphic
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let text = try TextEditing.text(node, in: state)
        guard state.store.placement(graphic)?.parent == node else { throw TextEditError.invalidValue("graphic") }
        if !state.isLive(graphic) { builder.append(Ops.setDeleted(graphic, false)) }
        guard !InlineGraphics.placements(text).contains(where: { $0.graphic == graphic }) else { return }
        let target = InlineGraphics.mark(graphic)
        let original = text.sequence.sortedMarks.last { mark in
            (try? Wiretuner_Doc_V1_TextMarkValue(serializedBytes: mark.value)) == target
        }?.start.char
        guard let original, text.sequence.contains(original) else {
            InlineGraphics.insert(graphic, node: node, origins: state.insertionOrigins(node, TextFields.text, at: text.length, stableSeq: 0),
                                  builder: &builder)
            return
        }
        InlineGraphics.insert(graphic, node: node, origins: (original, text.sequence.successor(of: original)), builder: &builder)
    }
}
