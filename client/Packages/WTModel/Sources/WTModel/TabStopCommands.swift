import WTCRDT
import WTProto

// Tab stops on paragraphs (tabs-indents.adoc, "Setting tabs", "Merge semantics"; TYPE-023): a
// paragraph's `ParagraphProps.tabs` is a SEQUENCE of `TabStop` elements whose order at read time
// is by `position`.  Placing a stop inserts an element on every paragraph the selection touches;
// moving one writes its `position` register, editing its kind or leader their registers, and
// removing it deletes the element.  A stop is found in each paragraph by where it stands, so one
// ruler gesture acts on the matching stop of every selected paragraph.  Indents are ordinary
// paragraph registers (`SetParagraph`, fields 4, 5 and 6).

/// Reading tab stops.
public enum TextTabs {
    /// The `TabStop` fields.
    public enum Field: UInt32, Sendable {
        case kind = 2, position = 3, leader = 4
    }

    /// How close two positions must be to name the same stop.
    public static let tolerance = 0.001

    /// The tabs sequence of `paragraph`.
    static func sequence(_ paragraph: TextParagraph) -> RegisterPath {
        (paragraph.terminator.map(TextFields.paragraph) ?? TextFields.tailParagraph).child(TextFields.tabsField)
    }

    /// The stops of `paragraph` sorted by position (equal positions keep sequence order), each
    /// with its element id; a negative position reads as 0.
    public static func stops(_ paragraph: TextParagraph) -> [(id: OpID, stop: Wiretuner_Doc_V1_TabStop)] {
        let listed = paragraph.props.tabs.enumerated().compactMap { index, stop -> (Int, OpID, Wiretuner_Doc_V1_TabStop)? in
            guard let id = OpID(element: stop.id) else { return nil }
            var read = stop
            read.position = max(stop.position, 0)
            return (index, id, read)
        }
        return listed.sorted { ($0.2.position, $0.0) < ($1.2.position, $1.0) }.map { ($0.1, $0.2) }
    }

    /// The paragraphs of `node` the anchors touch.
    static func paragraphs(_ node: OpID, _ start: Anchor, _ end: Anchor, in state: EngineState) throws -> (TextNode, [TextParagraph]) {
        let text = try TextEditing.text(node, in: state)
        return (text, text.paragraphs(touching: try text.range(start, end)))
    }

    /// The stops of `paragraph` standing at `position`.
    static func matching(_ paragraph: TextParagraph, at position: Double) -> [OpID] {
        stops(paragraph).filter { abs($0.stop.position - position) < tolerance }.map(\.id)
    }
}

/// Places `stop` on every paragraph the anchors touch (the caret's paragraph for an empty
/// range): one `ElementInsert` per paragraph, after its last element.  "Add Tab".
public struct AddTabStop: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var stop: Wiretuner_Doc_V1_TabStop
    public var label: String { "Add Tab" }

    public init(node: OpID, from start: Anchor, to end: Anchor, stop: Wiretuner_Doc_V1_TabStop) {
        self.node = node
        self.start = start
        self.end = end
        self.stop = stop
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard stop.position.isFinite else { throw TextEditError.invalidValue("position") }
        let (_, paragraphs) = try TextTabs.paragraphs(node, start, end, in: state)
        var copy = stop
        copy.clearID()
        copy.position = max(copy.position, 0)
        if copy.kind == .wrapping { copy.leader = "" }
        for paragraph in paragraphs {
            let sequence = TextTabs.sequence(paragraph)
            let last = state.liveElements(node, sequence).last.flatMap { state.position(node, sequence, $0) }
            let keys = try PathEditing.keys(between: last, and: nil, count: 1)
            builder.append(Ops.elementInsert(node, sequence, positions: keys,
                                             values: TextEditing.paragraphValues(.with { $0.tabs = [copy] }, newline: paragraph.terminator != nil)))
        }
    }
}

/// Edits the stop at `position` in every paragraph the anchors touch: writes the fields named
/// (`kind`, `position`, `leader`) from `stop`.  A leader on a wrapping stop is refused.  "Move
/// Tab" for a position alone, else "Edit Tab".
public struct SetTabStop: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var position: Double
    public var stop: Wiretuner_Doc_V1_TabStop
    public var fields: [TextTabs.Field]

    public init(node: OpID, from start: Anchor, to end: Anchor, at position: Double, stop: Wiretuner_Doc_V1_TabStop, fields: [TextTabs.Field]) {
        self.node = node
        self.start = start
        self.end = end
        self.position = position
        self.stop = stop
        self.fields = fields
    }

    public var label: String { fields == [.position] ? "Move Tab" : "Edit Tab" }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard !fields.isEmpty, stop.position.isFinite else { throw TextEditError.invalidValue("fields") }
        let (_, paragraphs) = try TextTabs.paragraphs(node, start, end, in: state)
        var value = stop
        value.clearID()
        value.position = max(value.position, 0)
        for paragraph in paragraphs {
            let sequence = TextTabs.sequence(paragraph)
            for id in TextTabs.matching(paragraph, at: position) {
                let kind = fields.contains(.kind) ? value.kind : TextTabs.stops(paragraph).first { $0.id == id }?.stop.kind
                if fields.contains(.leader), kind == .wrapping, !value.leader.isEmpty { throw TextEditError.invalidValue("leader") }
                builder.append(Ops.set(node, fields.map { sequence.element(id).child($0.rawValue) },
                                       values: TextEditing.paragraphValues(.with { $0.tabs = [value] }, newline: paragraph.terminator != nil)))
            }
        }
    }
}

/// Removes the stop at `position` from every paragraph the anchors touch.  "Delete Tab".
public struct DeleteTabStop: Command {
    public var node: OpID
    public var start: Anchor
    public var end: Anchor
    public var position: Double
    public var label: String { "Delete Tab" }

    public init(node: OpID, from start: Anchor, to end: Anchor, at position: Double) {
        self.node = node
        self.start = start
        self.end = end
        self.position = position
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let (_, paragraphs) = try TextTabs.paragraphs(node, start, end, in: state)
        for paragraph in paragraphs {
            let ids = TextTabs.matching(paragraph, at: position)
            guard !ids.isEmpty else { continue }
            let sequence = TextTabs.sequence(paragraph)
            builder.append(Ops.elementDelete(node, ids.map { sequence.element($0) }))
        }
    }
}
