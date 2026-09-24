import WTCRDT
import WTProto
import WTRender

// Text and block colour (TYPE-029; type/text-color.adoc): the glyph fill and stroke are marks
// (`TextMarkValue.fill`, `.stroke`), written with `ApplyMark` through the helpers here; the block's
// own fills and strokes are `TextProps.block_appearance`, an attribute stack of SEQUENCEs exactly as
// on a path, edited by the commands below and drawn by WTText behind (fills) and around (strokes,
// rules) the text.

/// Register paths and reading of a text block's `block_appearance`.
public enum TextBlockAppearance {
    /// `TextProps.block_appearance`.
    public static let path = RegisterPath([130, 7])
    /// `TextBlockProps.display_border`.
    public static let displayBorder = RegisterPath([130, 3, 6])

    /// The SEQUENCE of `list` (fills 1, strokes 2, effects 3).
    public static func sequence(_ list: AppearanceList) -> RegisterPath { path.child(list.rawValue) }

    /// The block's live rows, bottom first: the lists share one position space, so the stack is
    /// their elements sorted by position, then element id (attribute-stack.adoc).
    public static func rows(_ node: OpID, in state: EngineState) -> [AppearanceRow] {
        var keyed: [(position: [UInt8], row: AppearanceRow)] = []
        for list in AppearanceList.allCases {
            for id in state.liveElements(node, sequence(list)) {
                keyed.append((state.position(node, sequence(list), id) ?? [], AppearanceRow(list, id)))
            }
        }
        return keyed.sorted { a, b in
            // Element ids are unique across the three lists: they break a tie of positions.
            if a.position != b.position { return FractionalIndex.less(a.position, b.position) }
            return a.row.element < b.row.element
        }.map(\.row)
    }

    /// The block's appearance for drawing, in stack order (hidden rows left out by the stack).
    public static func appearance(_ node: OpID, in state: EngineState) -> Appearance {
        let props = state.props(node).text.blockAppearance
        guard !props.fills.isEmpty || !props.strokes.isEmpty else { return Appearance() }
        return Appearances.resolve(props, order: rows(node, in: state))
    }

    /// A sparse `NodeProps` whose block appearance `build` fills.
    static func values(_ build: (inout Wiretuner_Doc_V1_AppearanceProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.text.blockAppearance)
        return props
    }

    /// `node` as a text node, or throws.
    static func check(_ node: OpID, in state: EngineState) throws {
        guard state.store.kind(node) == TextFields.kind else { throw TextEditError.notText(node) }
    }

    /// `row` as a live row of `node`, or throws.
    static func check(_ node: OpID, _ row: AppearanceRow, in state: EngineState) throws {
        try check(node, in: state)
        guard state.liveElements(node, sequence(row.list)).contains(row.element) else { throw TextEditError.invalidValue("row") }
    }
}

/// The glyph colour commands (the Text row's Fill and Stroke sub-rows): each an `ApplyMark` over a
/// range, one change per commit.
public enum TextColor {
    /// The stroke btn:[Add Stroke] gives characters: 1 pt black.
    public static var defaultStroke: Wiretuner_Doc_V1_BasicStroke {
        var stroke = Wiretuner_Doc_V1_BasicStroke()
        stroke.color = Appearances.inline(red: 0, green: 0, blue: 0)
        stroke.width = 1
        return stroke
    }

    /// Fills the characters with `color` (a swatch reference caches its colour).  "Text Color".
    public static func fill(node: OpID, from start: Anchor, to end: Anchor, _ color: Wiretuner_Doc_V1_ColorRef) -> ApplyMark {
        ApplyMark(node: node, from: start, to: end, value: .with { $0.fill = color })
    }

    /// Removes the glyph fill (btn:[Delete] on the Fill sub-row): a fill of *None*, so the text is
    /// invisible but still there.  "Text Color".
    public static func removeFill(node: OpID, from start: Anchor, to end: Anchor) -> ApplyMark {
        var none = Wiretuner_Doc_V1_ColorRef()
        none.none = true
        return fill(node: node, from: start, to: end, none)
    }

    /// Strokes the characters (btn:[Add Stroke], or an edit of the Stroke sub-row): the whole
    /// `BasicStroke` is one mark value.  "Text Stroke".
    public static func stroke(node: OpID, from start: Anchor, to end: Anchor, _ stroke: Wiretuner_Doc_V1_BasicStroke = defaultStroke) -> ApplyMark {
        ApplyMark(node: node, from: start, to: end, value: .with { $0.stroke = stroke })
    }

    /// Removes the glyph stroke.  "Text Stroke".
    public static func removeStroke(node: OpID, from start: Anchor, to end: Anchor) -> ApplyMark {
        ApplyMark.remove(node: node, from: start, to: end, attribute: .with { $0.stroke = .init() })
    }
}

/// Adds a fill or stroke to a text block's own appearance (btn:[Add Fill] / btn:[Add Stroke] with
/// the block's root row selected): an `ElementInsert` at the top of `block_appearance`.  Adding the
/// block's first fill or stroke also turns *Display border* on, in the same change.  Defaults: a
/// black basic fill, a 1 pt black basic stroke.  "Add Fill" / "Add Stroke".
public struct AddTextBlockAppearance: Command {
    public var node: OpID
    public var fill: Wiretuner_Doc_V1_Fill?
    public var stroke: Wiretuner_Doc_V1_Stroke?
    public var label: String { stroke == nil ? "Add Fill" : "Add Stroke" }

    /// A fill.
    public static func fill(_ node: OpID, _ value: Wiretuner_Doc_V1_Fill = Appearances.basicFill(red: 0, green: 0, blue: 0)) -> AddTextBlockAppearance {
        AddTextBlockAppearance(node: node, fill: value, stroke: nil)
    }

    /// A stroke.
    public static func stroke(_ node: OpID, _ value: Wiretuner_Doc_V1_Stroke = Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)) -> AddTextBlockAppearance {
        AddTextBlockAppearance(node: node, fill: nil, stroke: value)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try TextBlockAppearance.check(node, in: state)
        let rows = TextBlockAppearance.rows(node, in: state)
        let top = rows.last.flatMap { state.position(node, TextBlockAppearance.sequence($0.list), $0.element) }
        let key = try PathEditing.keys(between: top, and: nil, count: 1)[0]
        let list: AppearanceList = stroke == nil ? .fills : .strokes
        builder.append(Ops.elementInsert(node, TextBlockAppearance.sequence(list), positions: [key], values: TextBlockAppearance.values { stack in
            if let fill { stack.fills = [fill] }
            if let stroke { stack.strokes = [stroke] }
        }))
        let hasPaint = rows.contains { $0.list != .effects }
        if !hasPaint, !state.props(node).text.block.displayBorder {
            var values = Wiretuner_Doc_V1_NodeProps()
            values.text.block.displayBorder = true
            builder.append(Ops.set(node, [TextBlockAppearance.displayBorder], values: values))
        }
    }
}

/// Removes a row of a text block's appearance: an `ElementDelete`.  "Remove Fill" /
/// "Remove Stroke".
public struct RemoveTextBlockAppearance: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var label: String { row.list == .strokes ? "Remove Stroke" : "Remove Fill" }

    public init(node: OpID, row: AppearanceRow) {
        self.node = node
        self.row = row
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try TextBlockAppearance.check(node, row, in: state)
        builder.append(Ops.elementDelete(node, [TextBlockAppearance.sequence(row.list).element(row.element)]))
    }
}

/// Edits a row of a text block's appearance (the ATTR editors on the block): writes the registers
/// `fields` name below the row's `Fill` or `Stroke` from `fill` / `stroke` -- `[3, 2, 1]` a basic
/// fill's or stroke's colour, `[3, 2, 2]` a basic stroke's width, `[2]` hidden.  A drop of a colour
/// on the block's border or interior is one of these.  "Fill" / "Stroke".
public struct SetTextBlockAppearance: Command {
    public var node: OpID
    public var row: AppearanceRow
    public var fill: Wiretuner_Doc_V1_Fill
    public var stroke: Wiretuner_Doc_V1_Stroke
    public var fields: [[UInt32]]
    public var label: String { row.list == .strokes ? "Stroke" : "Fill" }

    public init(node: OpID, row: AppearanceRow, fill: Wiretuner_Doc_V1_Fill = .init(), stroke: Wiretuner_Doc_V1_Stroke = .init(), fields: [[UInt32]]) {
        self.node = node
        self.row = row
        self.fill = fill
        self.stroke = stroke
        self.fields = fields
    }

    /// Sets a basic fill's or stroke's colour.
    public static func color(node: OpID, row: AppearanceRow, _ color: Wiretuner_Doc_V1_ColorRef) -> SetTextBlockAppearance {
        var fill = Wiretuner_Doc_V1_Fill()
        fill.settings.basic.color = color
        var stroke = Wiretuner_Doc_V1_Stroke()
        stroke.settings.basic.color = color
        return SetTextBlockAppearance(node: node, row: row, fill: fill, stroke: stroke, fields: [[3, 2, 1]])
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard row.list != .effects, !fields.isEmpty, fields.allSatisfy({ !$0.isEmpty }) else { throw TextEditError.invalidValue("fields") }
        try TextBlockAppearance.check(node, row, in: state)
        let element = TextBlockAppearance.sequence(row.list).element(row.element)
        var fill = fill
        fill.id = row.element.elementID
        var stroke = stroke
        stroke.id = row.element.elementID
        builder.append(Ops.set(node, fields.map { $0.reduce(element) { $0.child($1) } }, values: TextBlockAppearance.values { stack in
            if row.list == .fills { stack.fills = [fill] } else { stack.strokes = [stroke] }
        }))
    }
}
