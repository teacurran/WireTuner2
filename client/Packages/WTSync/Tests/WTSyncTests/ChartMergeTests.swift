import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WTSync

/// DRAW-032's merge suite (charts.adoc, "Merge semantics"): each case played as a reconnect --
/// this Mac's offline change against the others' -- converging on both sides, with what the
/// review lists.
@Suite struct ChartMergeTests {
    /// A shared chart holding `table`, on both sides.
    static func chart(_ table: [[String]], _ world: inout Reconnect) throws -> OpID {
        let chart = try #require(try world.shared(CreateChart(size: Size(width: 200, height: 100), transform: .translation(x: 10, y: 10)))).createdObjects[0]
        try world.shared(ImportChartData(chart, table: table))
        return chart
    }

    static func model(_ chart: OpID, _ core: DocumentCore) -> Chart { Chart(core.state.props(chart).chart) }

    static let sample = [["", "North", "South"], ["\"Q1\"", "1", "2"], ["\"Q2\"", "3", "4"]]

    /// Measures, uploads (asserting both sides converge) and answers the chart's review entry.
    static func settle(_ world: inout Reconnect, chart: OpID) -> (divergence: Divergence, entry: ReviewEntry?) {
        let divergence = world.measure()
        world.upload()
        return (divergence, divergence.entries.first { $0.node == chart })
    }

    @Test func cellEditVersusCellEditKeepsOneValueAndIsListed() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        let model = Self.model(chart, world.mine)
        let (row, column) = (model.rows[1], model.columns[1])
        try world.byThem(SetChartCell(chart, row: row, column: column, text: "7"))
        try world.byMe(SetChartCell(chart, row: row, column: column, text: "5"))
        let (_, entry) = Self.settle(&world, chart: chart)
        #expect(Self.model(chart, world.mine).text(row: row, column: column) == Self.model(chart, world.theirs).text(row: row, column: column))
        #expect(entry?.kinds.contains(.sameRegister) == true)
    }

    @Test func twoPeopleCreatingTheSameCellReadTheGreatestCell() throws {
        var world = Reconnect()
        let chart = try Self.chart([["1", ""]], &world)
        let model = Self.model(chart, world.mine)
        let (row, column) = (model.rows[0], model.columns[1])
        #expect(model.cells[row]?[column] == nil || model.text(row: row, column: column).isEmpty)
        try world.byThem(SetChartCell(chart, row: row, column: column, text: "7"))
        try world.byMe(SetChartCell(chart, row: row, column: column, text: "5"))
        _ = Self.settle(&world, chart: chart)
        let merged = Self.model(chart, world.mine)
        let cells = world.mine.state.props(chart).chart.rows.flatMap(\.cells).filter { OpID(element: $0.column) == column && !$0.text.isEmpty }
        #expect(cells.count == 2, "both cells are kept")
        let winner = try #require(cells.max { OpID(element: $0.id)! < OpID(element: $1.id)! })
        #expect(merged.text(row: row, column: column) == winner.text)
    }

    @Test func aColumnAndARowAddedConcurrentlyReadAnEmptyCell() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        try world.byThem(InsertChartLines(chart, .columns))
        try world.byMe(InsertChartLines(chart, .rows))
        let (divergence, _) = Self.settle(&world, chart: chart)
        let merged = Self.model(chart, world.mine)
        #expect(merged.columns.count == 4 && merged.rows.count == 4)
        #expect(merged.text(row: merged.rows[3], column: merged.columns[3]).isEmpty, "the new row has no cell in the new column")
        #expect(merged.grid.count == 4 && merged.grid.allSatisfy { $0.count == 4 })
        #expect(divergence.entries.allSatisfy { !$0.kinds.contains(.sameRegister) })
    }

    @Test func typingInADeletedColumnIsHidden() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        let model = Self.model(chart, world.mine)
        try world.byThem(DeleteChartLines(chart, .columns, [model.columns[2]]))
        try world.byMe(SetChartCell(chart, row: model.rows[1], column: model.columns[2], text: "9"))
        let (_, entry) = Self.settle(&world, chart: chart)
        #expect(Self.model(chart, world.mine).grid == [["", "North"], ["\"Q1\"", "1"], ["\"Q2\"", "3"]])
        #expect(entry != nil, "the chart is listed")
    }

    @Test func transposeNeverConflictsWithCellsAndTwoTransposesCollapse() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        let model = Self.model(chart, world.mine)
        try world.byThem(SetChartCell(chart, row: model.rows[1], column: model.columns[1], text: "8"))
        try world.byMe(SetChartFields(chart, .init(transposed: true)))
        var (_, entry) = Self.settle(&world, chart: chart)
        var merged = Self.model(chart, world.mine)
        #expect(merged.props.transposed && merged.text(row: model.rows[1], column: model.columns[1]) == "8")
        #expect(entry?.kinds.contains(.sameRegister) != true)
        // Two concurrent transposes back write the same value and collapse to one.
        try world.byThem(SetChartFields(chart, .init(transposed: false)))
        try world.byMe(SetChartFields(chart, .init(transposed: false)))
        (_, entry) = Self.settle(&world, chart: chart)
        merged = Self.model(chart, world.mine)
        #expect(!merged.props.transposed && entry?.kinds.contains(.sameRegister) == true)
    }

    @Test func importVersusEditListsTheEditAndRestoreBringsTheRowBack() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        let model = Self.model(chart, world.mine)
        try world.byThem(ImportChartData(chart, table: [["", "East"], ["\"Q3\"", "5"]]))
        try world.byMe(SetChartCell(chart, row: model.rows[1], column: model.columns[1], text: "6"))
        let divergence = world.measure()
        #expect(Self.model(chart, world.mine).grid == [["", "East"], ["\"Q3\"", "5"]], "the edited row is deleted with the import")
        #expect(divergence.entries.contains { $0.node == chart }, "the chart is listed")
        // Restoring the row and its column re-inserts the edited cell.
        try world.byMe(OpsCommand("Restore", ops: [Ops.elementDelete(chart, [ChartFields.rows.element(model.rows[1]), ChartFields.columns.element(model.columns[1])],
                                                                     deleted: false)]))
        world.upload()
        let restored = Self.model(chart, world.mine)
        #expect(restored.rows.contains(model.rows[1]) && restored.text(row: model.rows[1], column: model.columns[1]) == "6")
    }

    @Test func typeAndOptionsAreIndependentOfData() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        let model = Self.model(chart, world.mine)
        try world.byThem(SetChartCell(chart, row: model.rows[2], column: model.columns[2], text: "40"))
        try world.byMe(SetChartFields(chart, .init(type: .line, decimalPrecision: 1)))
        let (_, entry) = Self.settle(&world, chart: chart)
        let merged = Self.model(chart, world.mine)
        #expect(merged.props.type == .line && merged.props.decimalPrecision == 1 && merged.text(row: model.rows[2], column: model.columns[2]) == "40")
        #expect(entry?.kinds.contains(.sameRegister) != true)
    }

    @Test func overridesDangleWithTheirSeriesAndTheGreatestOfTwoWins() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        let model = Self.model(chart, world.mine)
        let (north, south) = (model.columns[1], model.columns[2])
        // A style for a series the other side deletes dangles and is ignored.
        try world.byThem(DeleteChartLines(chart, .columns, [south]))
        try world.byMe(SetChartOverride(chart, key: ChartElementKeyRef(series: south), repeating: true))
        _ = Self.settle(&world, chart: chart)
        var merged = Self.model(chart, world.mine)
        #expect(merged.liveOverrides(for: merged.table).isEmpty)
        #expect(world.mine.state.props(chart).chart.overrides.count == 1, "kept in the log")
        // Two styles for one key: both live, the greater element id shows, listed as both edited.
        try world.byThem(SetChartOverride(chart, key: ChartElementKeyRef(series: north), repeating: true))
        try world.byMe(SetChartOverride(chart, key: ChartElementKeyRef(series: north), repeating: false))
        let (_, entry) = Self.settle(&world, chart: chart)
        merged = Self.model(chart, world.mine)
        let overrides = world.mine.state.props(chart).chart.overrides.filter { OpID(element: $0.series) == north }
        #expect(overrides.count == 2)
        let winner = try #require(overrides.max { OpID(element: $0.id)! < OpID(element: $1.id)! })
        #expect(merged.liveOverrides(for: merged.table)[ChartElementKeyRef(series: north)]?.repeating == winner.repeating)
        #expect(entry != nil, "the chart is listed")
    }

    @Test func aPictographSetAgainstItsRemovalDangles() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        let model = Self.model(chart, world.mine)
        let key = ChartElementKeyRef(series: model.columns[1])
        var star = Wiretuner_Doc_V1_NodeProps()
        star.rect.size = .with { $0.width = 10; $0.height = 10 }
        try world.shared(SetChartPictograph(chart, key: key, artwork: [NodeTree(props: star)], repeating: true))
        let source = try #require(RemoveChartPictograph.source(chart, key: key, in: world.mine.state))
        // Remove deletes the source; a concurrent re-set of the same source dangles.
        try world.byThem(RemoveChartPictograph(chart, key: key))
        try world.byMe(SetChartOverride(chart, key: key, pictograph: .some(source)))
        _ = Self.settle(&world, chart: chart)
        #expect(!world.mine.state.isLive(source))
        // The scene draws only live sources (the chart's live children).
        let state = world.mine.state
        let spec = try #require(Self.model(chart, world.mine).spec(node: chart) { state.isLive($0) ? [.group(GroupItem(children: []))] : nil })
        #expect(spec.seriesStyles[NodeID(model.columns[1])]?.pictograph == nil, "reads as no pictograph")
    }

    @Test func ungroupVersusEditIsListedAndRestoreBringsTheChartBack() throws {
        var world = Reconnect()
        let chart = try Self.chart(Self.sample, &world)
        let model = Self.model(chart, world.mine)
        try world.byThem(UngroupChart(chart, item: .group(GroupItem(children: []))))
        try world.byMe(SetChartCell(chart, row: model.rows[1], column: model.columns[1], text: "12"))
        let divergence = world.measure()
        let entry = try #require(divergence.entries.first { $0.node == chart })
        #expect(entry.kind == .editVsDelete && !world.mine.state.isLive(chart))
        try world.byMe(ReviewModel.restore(entry))
        world.upload()
        #expect(world.theirs.state.isLive(chart) && Self.model(chart, world.theirs).text(row: model.rows[1], column: model.columns[1]) == "12")
    }
}
