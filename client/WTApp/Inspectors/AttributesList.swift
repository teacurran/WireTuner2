import AppKit
import Observation
import WTCRDT
import WTModel
import WTProto

/// One stack row of one object: what a command writes.
struct AttributeTarget: Hashable, Sendable {
    var node: OpID
    var row: AppearanceRow

    var pair: (node: OpID, row: AppearanceRow) { (node, row) }
}

/// The Attributes list's own state, kept across document revisions (attribute-stack.adoc, "The
/// Attributes list"): the selected row, remembered by the element of the first target so a remote
/// insert above or below it does not move the selection (or the focused editor) to another row.
@MainActor
@Observable
final class AttributesState {
    /// The selected row of the first target; nil selects the object's own row.
    var selected: AppearanceRow?
    /// The targets `selected` was chosen for; another selection resets it.
    private(set) var targets: [OpID] = []
    /// Where the canvas learns which row is edited (effect centre and gradient handles).
    @ObservationIgnored let focus: InspectorFocus

    init(focus: InspectorFocus = .shared) {
        self.focus = focus
    }

    /// The selection for `targets`: cleared when they changed.
    func selection(for targets: [OpID]) -> AppearanceRow? {
        guard targets == self.targets else { return nil }
        return selected
    }

    func select(_ row: AppearanceRow?, targets: [OpID]) {
        self.targets = targets
        selected = row
        focus.set(row, targets: targets)
    }
}

/// One row of the Attributes list: the stack element at `index` (0 = bottom) of every target.
struct AttributeRowItem: Identifiable, Equatable {
    var index: Int
    var list: AppearanceList
    /// The live kind, nil when the targets' rows differ.
    var kind: AttributeKind?
    /// "Basic, 2 pt"; "Mixed" when the targets' descriptions differ.
    var summary: String
    var hidden: MixedState
    /// This row on each target, in target order.
    var targets: [AttributeTarget]

    var id: AppearanceRow { targets[0].row }

    /// The SF Symbol of the row's kind.
    var icon: String {
        switch list {
        case .fills: "square.fill"
        case .strokes: "square"
        case .effects: "sparkles"
        }
    }
}

/// What the Attributes list shows for the front window's selection (ATTR-003), and the commands
/// its controls perform.  With nothing selected it lists the document's default attributes (the
/// settings node's `defaults.appearance`).  With several objects selected a row appears only
/// where every object has an element of the same list at the same stack position; otherwise the
/// list shows the root row alone and the buttons add to every object.
@MainActor
struct AttributesListModel {
    let document: DocumentHandle
    /// The nodes whose stacks are edited: the selected objects, or the settings node.
    let targets: [OpID]
    /// Each target's stack, bottom first.
    let stacks: [[AttributeEntry]]
    /// The common rows, bottom first; empty when the stacks differ.
    let rows: [AttributeRowItem]

    init(document: DocumentHandle, selection: Selection) {
        self.document = document
        let state = document.state
        let targets = Self.targets(selection, in: state)
        self.targets = targets
        let stacks = targets.map { AppearanceEditing.entries($0, in: state) }
        self.stacks = stacks
        rows = Self.common(targets, stacks)
    }

    /// The selected objects that carry a stack; the settings node when nothing is selected.
    static func targets(_ selection: Selection, in state: EngineState) -> [OpID] {
        guard !selection.isEmpty else { return [WellKnown.settings] }
        return selection.ids.map(\.opID).filter { Objects.isObject($0, in: state) }
    }

    static func common(_ targets: [OpID], _ stacks: [[AttributeEntry]]) -> [AttributeRowItem] {
        guard let first = stacks.first, stacks.allSatisfy({ $0.map(\.row.list) == first.map(\.row.list) }) else { return [] }
        return first.indices.map { index in
            let entries = stacks.map { $0[index] }
            let kinds = Set(entries.map(\.kind))
            let summaries = Set(entries.map(\.summary))
            return AttributeRowItem(
                index: index, list: first[index].row.list, kind: kinds.count == 1 ? kinds.first : nil,
                summary: summaries.count == 1 ? summaries.first! : "Mixed", hidden: MixedState(entries.map(\.hidden)),
                targets: zip(targets, entries).map { AttributeTarget(node: $0.0, row: $0.1.row) }
            )
        }
    }

    /// Editing the document's default attributes (nothing selected).
    var isDefaults: Bool { targets == [WellKnown.settings] }

    /// The root row's title.
    var rootTitle: String {
        if isDefaults { return "Default attributes" }
        switch targets.count {
        case 0: return "No attributes"
        case 1:
            guard let object = document.object(for: SelectionID(targets[0])) else { return "Object" }
            return object.kind == .extrude ? ExtrudeReading.title(targets[0], in: document.state) : Self.kindName(object.kind)
        default: return "\(targets.count) objects"
        }
    }

    static func kindName(_ kind: NodeKind) -> String {
        switch kind {
        case .path: "Path"
        case .rect: "Rectangle"
        case .ellipse: "Ellipse"
        case .polygon: "Polygon"
        case .group: "Group"
        case .layer: "Layer"
        case .chart: "Chart"
        case .symbol: "Symbol"
        case .instance: "Instance"
        case .barcode: "Barcode"
        case .connector: "Connector"
        case .image: "Image"
        case .placedFile: "Placed File"
        case .svgAnimation: "SVG Animation"
        case .text: "Text"
        case .brush: "Brush"
        case .blend: "Blend"
        case .extrude: "Extrusion"
        case .envelope: "Envelope"
        case .perspective: "Perspective Object"
        }
    }

    /// The rows top first, as the list shows them (the top row is drawn in front).
    var displayRows: [AttributeRowItem] { rows.reversed() }

    /// The row whose first target is `row`.
    func item(_ row: AppearanceRow?) -> AttributeRowItem? {
        rows.first { $0.id == row }
    }

    // MARK: Commands (one change each)

    /// btn:[Add Stroke], btn:[Add Fill]: above the selected row of each target, or at the top.
    func add(_ list: AppearanceList, above selected: AttributeRowItem?) -> AddAppearance? {
        guard !targets.isEmpty else { return nil }
        var command = list == .fills ? AddAppearance.fill(targets) : AddAppearance.stroke(targets)
        command.aboveRows = Self.aboveRows(selected)
        return command
    }

    /// btn:[Add Effect] (live-effects.adoc, "To add a live effect"): an effect of `kind` with its
    /// default settings on every target -- attached to the selected fill or stroke, else at the
    /// object level above the selected effect or at the top of the stack.
    func addEffect(_ kind: Wiretuner_Doc_V1_EffectKind, above selected: AttributeRowItem?) -> AddEffect? {
        guard !targets.isEmpty else { return nil }
        guard let selected, selected.list != .effects else { return AddEffect(targets, kind: kind, above: Self.aboveRows(selected)) }
        return AddEffect(targets, kind: kind, attachTo: Self.aboveRows(selected))
    }

    static func aboveRows(_ selected: AttributeRowItem?) -> [OpID: AppearanceRow] {
        Dictionary((selected?.targets ?? []).map { ($0.node, $0.row) }) { first, _ in first }
    }

    /// btn:[Remove Item], kbd:[Delete], *Remove*.
    func remove(_ item: AttributeRowItem) -> any WTModel.Command {
        if item.list == .effects { return RemoveEffect(item.targets.map(\.pair)) }
        return CompositeCommand("Remove \(Self.noun(item.list))", item.targets.map { RemoveAppearance(node: $0.node, row: $0.row) })
    }

    /// *Duplicate*: directly above the original on every target.
    func duplicate(_ item: AttributeRowItem) -> any WTModel.Command {
        CompositeCommand("Duplicate \(Self.noun(item.list))", item.targets.map { DuplicateAppearance(node: $0.node, row: $0.row) })
    }

    /// The visibility checkbox.
    func setHidden(_ item: AttributeRowItem, _ hidden: Bool) -> any WTModel.Command {
        SetAppearanceHidden(item.targets.map(\.pair), hidden: hidden)
    }

    /// Dragging the row at display position `from` to the insertion point `to` (both top
    /// first, as `List.onMove` reports them); with kbd:[Option] a copy lands there instead.
    func move(fromDisplay from: Int, toDisplay to: Int, duplicate: Bool) -> (any WTModel.Command)? {
        let count = rows.count
        guard (0..<count).contains(from) else { return nil }
        let item = displayRows[from]
        if duplicate {
            let index = count - min(max(to, 0), count)
            return CompositeCommand("Duplicate \(Self.noun(item.list))", item.targets.map { DuplicateAppearance(node: $0.node, row: $0.row, at: index) })
        }
        let landing = to > from ? to - 1 : to
        let index = count - 1 - min(max(landing, 0), count - 1)
        guard index != item.index else { return nil }
        if item.list == .effects { return reorderEffect(item, toStack: index) }
        return ReorderAttribute(item.targets.map(\.pair), to: index)
    }

    /// Where an effect dragged to stack position `index` lands (live-effects.adoc, "To reorder
    /// effects"): among the effects of its own group -- the object level or the fill or stroke it
    /// is attached to -- at the place the drop leaves it.  One change over every target.
    func reorderEffect(_ item: AttributeRowItem, toStack index: Int) -> (any WTModel.Command)? {
        let state = document.state
        let moves = item.targets.compactMap { target -> (any WTModel.Command)? in
            let entries = EffectReading.entries(target.node, in: state)
            guard let entry = entries.first(where: { $0.row == target.row }), entry.attachment != .skipped else { return nil }
            var order = AppearanceEditing.stack(target.node, in: state).filter { $0 != target.row }
            order.insert(target.row, at: min(index, order.count))
            let group = order.filter { row in row == target.row || entries.first { $0.row == row }?.attachment == entry.attachment }
            return ReorderEffect(node: target.node, row: target.row, to: group.firstIndex(of: target.row)!, attachTo: Self.attachedRow(entry.attachment))
        }
        return moves.isEmpty ? nil : CompositeCommand("Reorder effects", moves)
    }

    /// The fill or stroke an attachment names; nil for the object level.
    static func attachedRow(_ attachment: EffectAttachment) -> AppearanceRow? {
        if case .element(let row) = attachment { return row }
        return nil
    }

    /// An effect row dropped on a fill or stroke row (or, `onto` nil, on the object's own row):
    /// the effect moves to the end of that element's effects, attached to it.  Nil when the
    /// dragged row is not an effect or the target is one.
    func attach(fromDisplay from: Int, onto: AttributeRowItem?) -> (any WTModel.Command)? {
        guard (0..<rows.count).contains(from), onto?.list != .effects else { return nil }
        let item = displayRows[from]
        guard item.list == .effects else { return nil }
        let moves = item.targets.enumerated().map { index, target -> any WTModel.Command in
            ReorderEffect(node: target.node, row: target.row, to: Int.max, attachTo: onto?.targets[index].row)
        }
        return CompositeCommand("Reorder effects", moves)
    }

    /// A colour dropped on a row: that element only, on every target.
    func drop(_ color: Wiretuner_Doc_V1_ColorRef, on item: AttributeRowItem) -> (any WTModel.Command)? {
        guard item.list != .effects else { return nil }
        return SetAppearanceColor(item.targets.map(\.pair), color: color)
    }

    static func noun(_ list: AppearanceList) -> String {
        switch list {
        case .fills: "Fill"
        case .strokes: "Stroke"
        case .effects: "Effect"
        }
    }

    /// Performs `command` on the document, if there is one.
    @discardableResult
    func perform(_ command: (any WTModel.Command)?) -> Task<Wiretuner_Doc_V1_Change?, Never>? {
        command.map { document.perform($0) }
    }
}
