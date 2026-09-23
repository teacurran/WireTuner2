import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

enum ChartFixture {
    /// A chart holding `table` (imported), returned with its node.
    static func chart(_ table: [[String]], on replica: inout Replica, type: ChartType = .groupedColumn) throws -> OpID {
        let chart = try replica.perform(CreateChart(size: Size(width: 200, height: 100), transform: .translation(x: 10, y: 10), type: type))!.createdObjects[0]
        try replica.perform(ImportChartData(chart, table: table))
        return chart
    }

    static func model(_ chart: OpID, _ replica: Replica) -> Chart {
        Chart(replica.state.props(chart).chart)
    }
}

@Suite struct ChartModelTests {
    @Test func theTableReadsLabelsValuesAndTransposition() throws {
        var a = Replica(0xA)
        let chart = try ChartFixture.chart([["", "North", "South"], ["\"2024\"", "1,200", "x"], ["\"2025\"", "3", ""]], on: &a)
        let model = ChartFixture.model(chart, a)
        #expect(model.rows.count == 3 && model.columns.count == 3)
        #expect(model.grid == [["", "North", "South"], ["\"2024\"", "1,200", "x"], ["\"2025\"", "3", ""]])
        var table = model.table
        #expect(table.series.map(\.label) == ["North", "South"] && table.series.map(\.id) == model.columns.dropFirst().map(NodeID.init))
        #expect(table.categories.map(\.label) == ["2024", "2025"], "quoted numbers are labels")
        #expect(table.values == [[1200, 0], [3, 0]], "non-numeric and missing cells read 0")
        // A first column of plain numbers is data, not labels.
        let numbers = try ChartFixture.chart([["1", "2"], ["3", "4"]], on: &a)
        table = ChartFixture.model(numbers, a).table
        #expect(table.series.map(\.label) == ["", ""] && table.values == [[1, 2], [3, 4]])
        // Transposed: the sheet's rows become series, keyed by the row ids.
        try a.perform(SetChartFields(chart, .init(transposed: true)))
        let flipped = ChartFixture.model(chart, a)
        table = flipped.table
        #expect(table.series.map(\.label) == ["2024", "2025"] && table.series.map(\.id) == flipped.rows.dropFirst().map(NodeID.init))
        #expect(table.categories.map(\.label) == ["North", "South"] && table.values == [[1200, 3], [0, 0]])
        #expect(Chart.number("  ") == nil && Chart.label(" \"a\" ") == "a" && !Chart.isLabel(""))
    }

    @Test func switchXYSwapsScatterPairs() throws {
        var a = Replica(0xA)
        let chart = try ChartFixture.chart([["1", "10", "2", "20", "9"]], on: &a, type: .scatter)
        try a.perform(SetChartFields(chart, .init(switchXY: true)))
        let table = ChartFixture.model(chart, a).table
        #expect(table.values == [[10, 1, 20, 2, 9]])
        try a.perform(SetChartFields(chart, .init(type: .line)))
        #expect(ChartFixture.model(chart, a).table.values == [[1, 10, 2, 20, 9]], "only scatter charts switch")
    }

    @Test func duplicateCellsAndDeletedColumnsFollowTheReadRules() throws {
        var pair = Pair()
        let chart = try ChartFixture.chart([["1", ""]], on: &pair.a)
        pair.sync()
        let model = ChartFixture.model(chart, pair.a)
        let (row, column) = (model.rows[0], model.columns[1])
        try pair.a.perform(SetChartCell(chart, row: row, column: column, text: "5"))
        try pair.b.perform(SetChartCell(chart, row: row, column: column, text: "7"))
        pair.sync()
        let a = ChartFixture.model(chart, pair.a)
        let b = ChartFixture.model(chart, pair.b)
        #expect(pair.a.state.props(chart).chart.rows[0].cells.count == 3)
        #expect(a.text(row: row, column: column) == b.text(row: row, column: column))
        // A cell inserted before the others with the greatest id still wins.
        var early = Wiretuner_Doc_V1_ChartRow()
        var cell = Wiretuner_Doc_V1_ChartCell()
        cell.column = column.elementID
        cell.text = "9"
        early.cells = [cell]
        var values = Wiretuner_Doc_V1_NodeProps()
        values.chart.rows = [early]
        try pair.b.perform(OpsCommand("Early", ops: [Ops.elementInsert(chart, ChartFields.cells(row), positions: [[0x01]], values: values)]))
        #expect(ChartFixture.model(chart, pair.b).text(row: row, column: column) == "9")
        let winner = pair.a.state.props(chart).chart.rows[0].cells.filter { OpID(element: $0.column) == column }.compactMap { OpID(element: $0.id) }.max()
        #expect(a.cells[row]?[column]?.id == winner, "the greatest cell id wins")
        // A deleted column's cells are not read; a remote edit to them applies and stays hidden.
        try pair.a.perform(DeleteChartLines(chart, .columns, [column]))
        try pair.b.perform(SetChartCell(chart, row: row, column: column, text: "8"))
        pair.sync()
        #expect(ChartFixture.model(chart, pair.b).grid == [["1"]])
    }

    @Test func overridesAndPictographsStyleTheLayout() throws {
        var a = Replica(0xA)
        let chart = try ChartFixture.chart([["", "A", "B"], ["x", "1", "2"], ["y", "3", "4"]], on: &a)
        let model = ChartFixture.model(chart, a)
        let (series, category) = (model.columns[1], model.rows[1])
        var appearance = Wiretuner_Doc_V1_AppearanceProps()
        appearance.fills = [Appearances.basicFill(red: 1, green: 0, blue: 0)]
        appearance.strokes = [Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 2)]
        let style = try #require(try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: series), appearance: appearance)))
        #expect(style.label == "Style chart element")
        try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: series, index: category), transform: .translation(x: 0, y: -5), repeating: true))
        // A pictograph source is a child of the chart.
        let picture = try a.perform(OpsCommand("Pictograph", ops: [Ops.create(parent: chart, position: [0x80], props: ShapeFixture.rect())]))!.createdNodes[0]
        try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: series, index: category), pictograph: .some(picture)))
        #expect(ChartFixture.model(chart, a).spec(node: chart)?.elementStyles.values.first?.pictograph == nil, "no source given")
        var spec = try #require(ChartFixture.model(chart, a).spec(node: chart) { $0 == picture ? [.group(GroupItem(children: []))] : nil })
        #expect(spec.seriesStyles[NodeID(series)]?.appearance?.items.count == 2)
        let element = try #require(spec.elementStyles[ChartElementKey(series: NodeID(series), index: NodeID(category))])
        #expect(element.transform == .translation(x: 0, y: -5) && element.repeating && element.pictograph?.count == 1)
        // Restyling replaces the stack; clearing the pictograph unsets it.
        try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: series), appearance: Wiretuner_Doc_V1_AppearanceProps()))
        try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: series, index: category), pictograph: .some(nil)))
        spec = try #require(ChartFixture.model(chart, a).spec(node: chart))
        #expect(spec.seriesStyles[NodeID(series)]?.appearance == nil)
        // An element override whose index is not a category is ignored.
        var stray = Wiretuner_Doc_V1_NodeProps()
        var strayEntry = Wiretuner_Doc_V1_ChartOverride()
        strayEntry.series = series.elementID
        strayEntry.index = model.columns[2].elementID
        stray.chart.overrides = [strayEntry]
        try a.perform(OpsCommand("Stray", ops: [Ops.elementInsert(chart, ChartFields.overrides, positions: [[0x30]], values: stray)]))
        #expect(ChartFixture.model(chart, a).liveOverrides(for: ChartFixture.model(chart, a).table).count == 2)
        #expect(spec.elementStyles[ChartElementKey(series: NodeID(series), index: NodeID(category))]?.pictograph == nil)
        #expect(throws: ChartError.unknownElement(category)) { try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: category))) }
        #expect(throws: ChartError.unknownElement(series)) { try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: series, index: series))) }
        #expect(throws: ChartError.unknownElement(chart)) { try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: series), pictograph: .some(chart))) }
        // An override of a deleted series is ignored; of two for one key the greater id wins.
        try a.perform(DeleteChartLines(chart, .columns, [series]))
        #expect(ChartFixture.model(chart, a).liveOverrides(for: ChartFixture.model(chart, a).table).isEmpty)
        let other = model.columns[2]
        var duplicate = Wiretuner_Doc_V1_NodeProps()
        var entry = Wiretuner_Doc_V1_ChartOverride()
        entry.series = other.elementID
        entry.repeating = true
        duplicate.chart.overrides = [entry]
        try a.perform(OpsCommand("One", ops: [Ops.elementInsert(chart, ChartFields.overrides, positions: [[0x10]], values: duplicate)]))
        entry.repeating = false
        duplicate.chart.overrides = [entry]
        try a.perform(OpsCommand("Two", ops: [Ops.elementInsert(chart, ChartFields.overrides, positions: [[0x05]], values: duplicate)]))
        let live = ChartFixture.model(chart, a)
        #expect(live.liveOverrides(for: live.table)[ChartElementKeyRef(series: other)]?.repeating == false)
    }

    @Test func readDefaultsForOptionsAndAxes() {
        var options = Wiretuner_Doc_V1_ChartOptions()
        var read = Chart.options(options)
        #expect(read.columnWidth == 80 && read.clusterWidth == 80 && read.markers == .square && read.axisDisplay == .left)
        options.columnWidth = 120
        options.clusterWidth = 50
        options.markers = .circle
        options.axisDisplay = .both
        options.pieSeparation = 90
        read = Chart.options(options)
        #expect(read.columnWidth == 120 && read.clusterWidth == 50 && read.markers == .circle && read.axisDisplay == .both && read.pieSeparation == 50)
        var axis = Wiretuner_Doc_V1_AxisOptions()
        #expect(Chart.axis(axis).manual == nil && Chart.axis(axis).major == .outside && Chart.axis(axis).minor == ChartTickStyle.none)
        axis.manual = true
        axis.minimum = 0
        axis.maximum = 100
        axis.between = 25
        axis.major = .across
        axis.minor = .inside
        axis.minorCount = 4
        axis.prefix = "$"
        let manual = Chart.axis(axis)
        #expect(manual.manual == ChartAxisRange(minimum: 0, maximum: 100, between: 25) && manual.major == .across && manual.minor == .inside)
        #expect(manual.minorCount == 4 && manual.prefix == "$")
        axis.between = 0
        #expect(Chart.axis(axis).manual == nil)
        for type in ChartType.allCases {
            #expect(Chart.type(Chart.proto(type)) == type)
        }
        #expect(Chart.type(.unspecified) == .groupedColumn)
    }
}

@Suite struct ChartCommandTests {
    @Test func createEditInsertAndDelete() throws {
        var a = Replica(0xA)
        let create = CreateChart(size: Size(width: 100, height: 60))
        #expect(create.label == "Chart")
        let chart = try a.perform(create)!.createdObjects[0]
        #expect(a.state.nodeKind(chart) == .chart && a.state.props(chart).chart.decimalPrecision == 2)
        #expect(throws: ObjectEditError.invalidValue("size")) { try a.perform(CreateChart(size: Size(width: 0, height: 1))) }
        let rows = InsertChartLines(chart, .rows, count: 2)
        #expect(rows.label == "Insert 2 Rows")
        try a.perform(rows)
        try a.perform(InsertChartLines(chart, .columns))
        #expect(InsertChartLines(chart, .columns).label == "Insert Column")
        var model = ChartFixture.model(chart, a)
        #expect(model.rows.count == 2 && model.columns.count == 1)
        // Insert between: after the first row.
        try a.perform(InsertChartLines(chart, .rows, after: model.rows[0]))
        let middle = ChartFixture.model(chart, a).rows[1]
        #expect(!model.rows.contains(middle))
        #expect(try a.perform(InsertChartLines(chart, .rows, count: 0)) == nil)
        #expect(throws: ChartError.unknownElement(chart)) { try a.perform(InsertChartLines(chart, .rows, after: chart)) }
        model = ChartFixture.model(chart, a)
        let edit = SetChartCell(chart, row: model.rows[0], column: model.columns[0], text: "4")
        #expect(edit.label == "Edit Chart Data")
        try a.perform(edit)
        #expect(ChartFixture.model(chart, a).text(row: model.rows[0], column: model.columns[0]) == "4")
        let rewrite = try #require(try a.perform(SetChartCell(chart, row: model.rows[0], column: model.columns[0], text: "5")))
        #expect(rewrite.ops.count == 1 && rewrite.ops[0].set.paths.count == 1, "an existing cell's text register")
        #expect(try a.perform(SetChartCell(chart, row: model.rows[0], column: model.columns[0], text: "5")) == nil)
        #expect(try a.perform(SetChartCell(chart, row: model.rows[1], column: model.columns[0], text: "")) == nil)
        #expect(throws: ChartError.unknownElement(chart)) { try a.perform(SetChartCell(chart, row: chart, column: model.columns[0], text: "1")) }
        #expect(throws: ChartError.unknownElement(chart)) { try a.perform(SetChartCell(chart, row: model.rows[0], column: chart, text: "1")) }
        #expect(throws: ChartError.notAChart(model.rows[0])) { try a.perform(SetChartCell(model.rows[0], row: model.rows[0], column: model.columns[0], text: "1")) }
        let delete = DeleteChartLines(chart, .rows, [model.rows[0], model.rows[1]])
        #expect(delete.label == "Delete 2 Rows" && DeleteChartLines(chart, .columns, [model.columns[0]]).label == "Delete Column")
        try a.perform(delete)
        #expect(ChartFixture.model(chart, a).rows == [model.rows[2]])
        a.undo()
        #expect(ChartFixture.model(chart, a).rows == model.rows, "undo restores the rows with their cells")
        #expect(ChartFixture.model(chart, a).text(row: model.rows[0], column: model.columns[0]) == "5")
        #expect(try a.perform(DeleteChartLines(chart, .rows, [])) == nil)
        #expect(throws: ChartError.unknownElement(chart)) { try a.perform(DeleteChartLines(chart, .columns, [chart])) }
    }

    @Test func importReplacesTheTableInOneUndoableChange() throws {
        var a = Replica(0xA)
        let chart = try ChartFixture.chart([["a", "1"]], on: &a)
        let first = ChartFixture.model(chart, a)
        let change = try #require(try a.perform(ImportChartData(chart, tabDelimited: "\tX\tY\nq\t1\t2\n\n")))
        #expect(change.label == "Import Chart Data")
        let model = ChartFixture.model(chart, a)
        #expect(model.grid == [["", "X", "Y"], ["q", "1", "2"], ["", "", ""]])
        #expect(Set(model.rows).isDisjoint(with: first.rows))
        a.undo()
        #expect(ChartFixture.model(chart, a).grid == [["a", "1"]])
        #expect(ImportChartData(chart, tabDelimited: "1\t2").table == [["1", "2"]])
        try a.perform(ImportChartData(chart, table: []))
        #expect(ChartFixture.model(chart, a).rows.isEmpty && ChartFixture.model(chart, a).columns.isEmpty)
        try a.perform(ImportChartData(chart, table: [[]]))
        #expect(ChartFixture.model(chart, a).rows.count == 1 && ChartFixture.model(chart, a).columns.isEmpty)
        let huge = Array(repeating: ["1"], count: ChartEditing.opLimit)
        #expect(throws: ChartError.tooLarge(ops: ChartEditing.opLimit + 4)) { try a.perform(ImportChartData(chart, table: huge)) }
    }

    @Test func fieldsWriteOnlyWhatChanged() throws {
        var a = Replica(0xA)
        let chart = try ChartFixture.chart([["1"]], on: &a)
        #expect(SetChartFields(chart, .init(transposed: true)).label == "Transpose")
        #expect(SetChartFields(chart, .init(switchXY: true)).label == "Switch XY")
        #expect(SetChartFields(chart, .init(type: .pie)).label == "Change Chart Type")
        #expect(SetChartFields(chart, .init(decimalPrecision: 1)).label == "Change Chart")
        #expect(SetChartFields(chart, .init(transposed: true, type: .pie)).label == "Change Chart")
        var options = Wiretuner_Doc_V1_ChartOptions()
        options.dropShadow = true
        options.gridlinesX = true
        var axis = Wiretuner_Doc_V1_AxisOptions()
        axis.suffix = "%"
        let change = try #require(try a.perform(SetChartFields(chart, .init(
            type: .area, decimalPrecision: 0, thousandsSeparator: true, size: Size(width: 300, height: 120), options: options, xAxis: axis, yAxis: axis
        ))))
        #expect(change.ops[0].set.paths.count == 8)
        let props = a.state.props(chart).chart
        #expect(props.type == .area && props.decimalPrecision == 0 && props.thousandsSeparator && props.size.width == 300)
        #expect(props.options.dropShadow && props.options.gridlinesX && props.xAxis.suffix == "%" && props.yAxis.suffix == "%")
        #expect(try a.perform(SetChartFields(chart, .init(type: .area, options: options, xAxis: axis))) == nil, "nothing changed")
        options.dropShadow = false
        let unset = try #require(try a.perform(SetChartFields(chart, .init(options: options))))
        #expect(unset.ops[0].set.paths.count == 1 && !a.state.props(chart).chart.options.dropShadow)
        #expect(throws: ObjectEditError.invalidValue("decimalPrecision")) { try a.perform(SetChartFields(chart, .init(decimalPrecision: 11))) }
        #expect(throws: ObjectEditError.invalidValue("size")) { try a.perform(SetChartFields(chart, .init(size: Size(width: -1, height: 1)))) }
        a.undo()
        #expect(a.state.props(chart).chart.options.dropShadow)
        let taller = try #require(try a.perform(SetChartFields(chart, .init(size: Size(width: 300, height: 150)))))
        #expect(taller.ops[0].set.paths.count == 1)
    }

    @Test func chartsRenderAndRepaintWithTheirPictographs() throws {
        var a = Replica(0xA)
        let chart = try ChartFixture.chart([["", "A"], ["x", "3"], ["y", "5"]], on: &a)
        let model = ChartFixture.model(chart, a)
        let picture = try a.perform(OpsCommand("Pictograph", ops: [Ops.create(parent: chart, position: [0x80], props: ShapeFixture.rect())]))!.createdNodes[0]
        try a.perform(SetChartOverride(chart, key: ChartElementKeyRef(series: model.columns[1]), pictograph: .some(picture)))
        var builder = DocumentDisplayListBuilder(canvas: "c")
        let scene = builder.rebuild(a.state)
        let object = try #require(scene.object(chart))
        #expect(object.kind == .chart && object.bounds != nil && scene.object(picture) == nil, "pictograph sources are not drawn as objects")
        #expect(Objects.bounds(of: chart, in: a.state) == Rect(x: 10, y: 10, width: 200, height: 100))
        #expect(builder.dependencies.directDependents(of: NodeID(picture)) == [NodeID(chart)])
        let resize = try #require(try a.perform(SetShapeFieldsForTest.resize(picture)))
        let (_, summary) = builder.apply(resize, state: a.state, origin: .remote)
        #expect(summary.touchedNodes.contains(NodeID(chart)))
        // A pictograph that is not the chart's child reads as none.
        var foreign = Wiretuner_Doc_V1_NodeProps()
        var entry = Wiretuner_Doc_V1_ChartOverride()
        entry.series = model.columns[1].elementID
        entry.index = model.rows[1].elementID
        entry.pictograph.id = chart.proto
        foreign.chart.overrides = [entry]
        try a.perform(OpsCommand("Foreign", ops: [Ops.elementInsert(chart, ChartFields.overrides, positions: [[0xF0]], values: foreign)]))
        #expect(builder.rebuild(a.state).object(chart) != nil)
        // A chart of no size draws nothing.
        let empty = try a.perform(OpsCommand("Empty", ops: [Ops.create(parent: Objects.parent(of: chart, in: a.state)!, position: [0xF0], props: {
            var props = Wiretuner_Doc_V1_NodeProps()
            props.chart = .init()
            return props
        }())]))!.createdNodes[0]
        #expect(builder.rebuild(a.state).object(empty) == nil && Objects.bounds(of: empty, in: a.state) == nil)
        #expect(ChartFixture.model(empty, a).spec(node: empty) == nil)
    }
}

enum SetShapeFieldsForTest {
    /// A resize of the 10 × 10 rectangle `node`.
    static func resize(_ node: OpID) -> SetShapeSize { SetShapeSize(node: node, size: Size(width: 30, height: 30)) }
}
