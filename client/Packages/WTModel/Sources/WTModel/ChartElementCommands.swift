import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// menu:Extensions[Chart > Pictograph…]'s btn:[OK] (charts.adoc, "Pictographs"; DRAW-034): the
/// artwork becomes a `group` child of the chart -- the source -- and the override for `key` points
/// at it with `repeating`, one change ("Pictograph").  An earlier source of the key is deleted in
/// the same change.
public struct SetChartPictograph: Command {
    public var chart: OpID
    public var key: ChartElementKeyRef
    public var artwork: [NodeTree]
    public var repeating: Bool
    public var label: String { "Pictograph" }

    public init(_ chart: OpID, key: ChartElementKeyRef, artwork: [NodeTree], repeating: Bool) {
        self.chart = chart
        self.key = key
        self.artwork = artwork
        self.repeating = repeating
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let model = try ChartEditing.chart(chart, in: state)
        let table = model.table
        guard table.series.contains(where: { $0.id == NodeID(key.series) }) else { throw ChartError.unknownElement(key.series) }
        if let index = key.index, !table.categories.contains(where: { $0.id == NodeID(index) }) { throw ChartError.unknownElement(index) }
        guard !artwork.isEmpty else { throw ChartError.unknownElement(chart) }
        var group = Wiretuner_Doc_V1_NodeProps()
        group.group.kind = .group
        group.group.common.name = "Pictograph"
        let last = state.liveChildren(chart).last.flatMap { state.store.placement($0)?.position }
        let position = try PathEditing.keys(between: last, and: nil, count: 1)[0]
        let source = try NodeCopier.create(NodeTree(props: group, children: artwork), parent: chart, position: position, schema: state.schema, builder: &builder)
        var value = Wiretuner_Doc_V1_ChartOverride()
        value.pictograph.id = source.proto
        value.repeating = repeating
        if let existing = model.liveOverrides(for: table)[key], let id = OpID(element: existing.id) {
            if existing.hasPictograph, state.isLive(OpID(existing.pictograph.id)), Objects.parent(of: OpID(existing.pictograph.id), in: state) == chart {
                builder.append(Ops.setDeleted(OpID(existing.pictograph.id)))
            }
            builder.append(Ops.set(chart, [ChartFields.override(id).child(6), ChartFields.override(id).child(7)], values: ChartEditing.values { $0.overrides = [value] }))
        } else {
            value.series = key.series.elementID
            if let index = key.index { value.index = index.elementID }
            let keys = try ChartEditing.keys(chart, ChartFields.overrides, after: nil, count: 1, in: state)
            builder.append(Ops.elementInsert(chart, ChartFields.overrides, positions: keys, values: ChartEditing.values { $0.overrides = [value] }))
        }
    }
}

/// menu:Extensions[Chart > Remove Pictograph]: the key's pictograph reference cleared and its
/// source deleted, one change ("Remove Pictograph").  Nothing is written when the key has none.
public struct RemoveChartPictograph: Command {
    public var chart: OpID
    public var key: ChartElementKeyRef
    public var label: String { "Remove Pictograph" }

    public init(_ chart: OpID, key: ChartElementKeyRef) {
        self.chart = chart
        self.key = key
    }

    /// The source node the key's pictograph names, when it has one.
    public static func source(_ chart: OpID, key: ChartElementKeyRef, in state: EngineState) -> OpID? {
        guard let model = try? ChartEditing.chart(chart, in: state), let existing = model.liveOverrides(for: model.table)[key], existing.hasPictograph else { return nil }
        return OpID(existing.pictograph.id)
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard let source = Self.source(chart, key: key, in: state) else { return }
        try SetChartOverride(chart, key: key, pictograph: .some(nil)).execute(&builder, state: state)
        if state.isLive(source), Objects.parent(of: source, in: state) == chart { builder.append(Ops.setDeleted(source)) }
    }
}

/// menu:Modify[Ungroup] on a chart (charts.adoc, "Ungrouping a chart"): the drawing the chart
/// shows -- `item`, its display item in pasteboard space, with its overrides and pictographs -- is
/// baked into plain paths under a new group in the chart's place, and the chart is deleted, one
/// change ("Ungroup").  Labels become outlined paths (the baking expands text as release does).
public struct UngroupChart: Command {
    public var chart: OpID
    public var item: DisplayItem
    public var label: String { "Ungroup" }

    public init(_ chart: OpID, item: DisplayItem) {
        self.chart = chart
        self.item = item
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        _ = try ChartEditing.chart(chart, in: state)
        guard let parent = Objects.parent(of: chart, in: state) else { throw ChartError.notAChart(chart) }
        let above = state.store.placement(chart)?.position
        let next = Arranging.siblingAfter(chart, in: state).flatMap { state.store.placement($0)?.position }
        let position = try PathEditing.keys(between: above, and: next, count: 1)[0]
        var trees = Baking.trees([item])
        if trees.isEmpty {
            var empty = Wiretuner_Doc_V1_NodeProps()
            empty.group.kind = .group
            trees = [NodeTree(props: empty)]
        }
        try Baking.createGroup(trees, parent: parent, position: position, state: state, builder: &builder)
        builder.append(Ops.setDeleted(chart))
    }
}
