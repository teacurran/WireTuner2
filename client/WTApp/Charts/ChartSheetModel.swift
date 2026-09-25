import AppKit
import Observation
import WTCRDT
import WTModel
import WTProto
import WTRender

/// The Chart sheet's model (charts.adoc, "Creating a chart", "Chart types and options"; DRAW-033):
/// the *Data* tab's grid read live from the chart -- so a collaborator's cell arrives without
/// disturbing the entry field, which holds its draft until kbd:[Return] -- with the active cell,
/// the sheet's own Undo, Import, Transpose, Switch XY, Cut, Copy and Paste of cells, and column
/// widths (view state); the *Type* tab's type, options and axes held as a draft until btn:[Apply]
/// or btn:[OK].  Each cell commit is one change; Apply writes only the registers that changed.
@MainActor
@Observable
final class ChartSheetModel {
    enum Tab: String, CaseIterable, Identifiable {
        case data, type
        var id: String { rawValue }
        var title: String { self == .data ? "Data" : "Type" }
    }

    /// A cell position in the sheet's grid.
    struct Position: Hashable {
        var row: Int
        var column: Int
    }

    static let types: [(type: Wiretuner_Doc_V1_ChartType, title: String)] = [
        (.groupedColumn, "Grouped column"), (.stackedColumn, "Stacked column"), (.line, "Line"), (.pie, "Pie"), (.area, "Area"), (.scatter, "Scatter"),
    ]

    @ObservationIgnored let document: DocumentHandle
    @ObservationIgnored let sink: any CommandSink
    let chart: OpID
    var tab: Tab
    var active = Position(row: 0, column: 0) {
        didSet { if active != oldValue { entry = text(at: active) } }
    }
    /// The cells selected for Cut, Copy and Paste (the active one when empty).
    var selected: Set<Position> = []
    /// The entry field's draft.
    var entry = ""
    /// Column widths in the sheet, points (view state only).
    var columnWidths: [Int: Double] = [:]
    // The Type tab's draft.
    var type: Wiretuner_Doc_V1_ChartType
    var options: Wiretuner_Doc_V1_ChartOptions
    var xAxis: Wiretuner_Doc_V1_AxisOptions
    var yAxis: Wiretuner_Doc_V1_AxisOptions
    var decimalPrecision: Int
    var thousandsSeparator: Bool
    /// The sheet's Undo: the cells as they were before each commit.
    private(set) var history: [(position: Position, text: String)] = []
    /// The change the last commit performed (tests await it).
    @ObservationIgnored private(set) var last: Task<Void, Never>?
    /// The pasteboard Cut, Copy and Paste use.
    @ObservationIgnored var pasteboard: NSPasteboard = .general
    private(set) var message: String?

    static let defaultColumnWidth = 60.0

    init(chart: OpID, document: DocumentHandle, sink: any CommandSink, tab: Tab = .data) {
        self.chart = chart
        self.document = document
        self.sink = sink
        self.tab = tab
        let props = document.state.props(chart).chart
        type = Self.storedType(props)
        options = props.options
        xAxis = props.xAxis
        yAxis = props.yAxis
        decimalPrecision = Int(props.decimalPrecision)
        thousandsSeparator = props.thousandsSeparator
        entry = text(at: active)
    }

    /// The chart as merged now.
    var model: Chart { Chart(document.state.props(chart).chart) }
    var isLive: Bool { document.state.isLive(chart) && document.state.nodeKind(chart) == .chart }

    /// The grid shown: the table plus an empty row and column to type into.
    var grid: [[String]] {
        let table = model.grid
        let columns = max(model.columns.count, 1) + 1
        return (table + [[]]).map { row in (0..<columns).map { $0 < row.count ? row[$0] : "" } }
    }

    func text(at position: Position) -> String {
        let chart = model
        guard chart.rows.indices.contains(position.row), chart.columns.indices.contains(position.column) else { return "" }
        return chart.text(row: chart.rows[position.row], column: chart.columns[position.column])
    }

    func width(of column: Int) -> Double { columnWidths[column] ?? Self.defaultColumnWidth }

    /// Dragging a column's triangle.
    func resize(column: Int, to width: Double) {
        columnWidths[column] = min(max(width, 24), 400)
    }

    /// The arrow keys.
    func move(rows: Int, columns: Int) {
        active = Position(row: max(active.row + rows, 0), column: max(active.column + columns, 0))
        selected = []
    }

    func select(_ position: Position, extending: Bool = false) {
        if extending { selected.insert(active) } else { selected = [] }
        active = position
        if extending { selected.insert(position) }
    }

    // MARK: Cells

    /// kbd:[Return]: the draft into the active cell (rows and columns added first when it lies
    /// past the table), then the cell below becomes active.
    @discardableResult
    func commit() -> Task<Void, Never> {
        let position = active
        let text = entry
        let previous = self.text(at: position)
        let task = write(text, at: position)
        if text != previous { history.append((position, previous)) }
        active = Position(row: position.row + 1, column: position.column)
        return task
    }

    /// Writes `text` at `position`, growing the table as needed.
    @discardableResult
    func write(_ text: String, at position: Position) -> Task<Void, Never> {
        let chart = self.chart
        let sink = sink
        let document = document
        let task = Task { @MainActor in
            var current = Chart(document.state.props(chart).chart)
            if position.row >= current.rows.count {
                _ = await sink.perform(InsertChartLines(chart, .rows, count: position.row - current.rows.count + 1, after: current.rows.last)).value
            }
            current = Chart(document.state.props(chart).chart)
            if position.column >= current.columns.count {
                _ = await sink.perform(InsertChartLines(chart, .columns, count: position.column - current.columns.count + 1, after: current.columns.last)).value
            }
            current = Chart(document.state.props(chart).chart)
            guard current.rows.indices.contains(position.row), current.columns.indices.contains(position.column) else { return }
            _ = await sink.perform(SetChartCell(chart, row: current.rows[position.row], column: current.columns[position.column], text: text)).value
        }
        last = task
        return task
    }

    /// btn:[Undo]: the last commit reverted.
    @discardableResult
    func undo() -> Task<Void, Never>? {
        guard let previous = history.popLast() else { return nil }
        active = previous.position
        entry = previous.text
        return write(previous.text, at: previous.position)
    }

    /// The selected cells (or the active one), in reading order.
    var selection: [Position] {
        (selected.isEmpty ? [active] : Array(selected)).sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    /// btn:[Copy]: the selected cells as tab-delimited text.
    @discardableResult
    func copy() -> String {
        let cells = selection
        let rows = Dictionary(grouping: cells, by: \.row)
        // The selection holds at least the active cell.
        let lowest = cells.map(\.column).min()!, highest = cells.map(\.column).max()!
        let text = rows.keys.sorted().map { row in
            let columns = Set(rows[row]!.map(\.column))
            return (lowest...highest).map { column in columns.contains(column) ? self.text(at: Position(row: row, column: column)) : "" }
                .joined(separator: "\t")
        }.joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }

    /// btn:[Cut]: copied, then emptied (one change each).
    @discardableResult
    func cut() -> Task<Void, Never> {
        copy()
        let cells = selection
        let task = Task { @MainActor in
            for position in cells where !self.text(at: position).isEmpty { await self.write("", at: position).value }
        }
        last = task
        return task
    }

    /// btn:[Paste]: tab-delimited text from the pasteboard, from the active cell.
    @discardableResult
    func paste() -> Task<Void, Never>? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return importText(text)
    }

    /// btn:[Import…] and Paste: tab-delimited text laid into the grid from the active cell, as one
    /// change (`ImportChartData` with the merged table); a table past the op limit is refused
    /// with a message naming it.
    @discardableResult
    func importText(_ text: String) -> Task<Void, Never> {
        let incoming = ImportChartData(chart, tabDelimited: text).table
        var table = model.grid
        let origin = active
        for (rowOffset, row) in incoming.enumerated() {
            let r = origin.row + rowOffset
            while table.count <= r { table.append([]) }
            for (columnOffset, cell) in row.enumerated() {
                let c = origin.column + columnOffset
                while table[r].count <= c { table[r].append("") }
                table[r][c] = cell
            }
        }
        let width = table.map(\.count).max() ?? 0
        table = table.map { $0 + Array(repeating: "", count: width - $0.count) }
        let command = ImportChartData(chart, table: table)
        let sink = sink
        let task = Task { @MainActor in
            let change = await sink.perform(command).value
            self.message = change == nil && !table.isEmpty ? "The table is too large to import (\(ChartEditingLimits.opLimit) changes at most)." : nil
        }
        last = task
        return task
    }

    /// btn:[Import…]: a tab-delimited UTF-8 file.
    @discardableResult
    func importFile(_ url: URL) -> Task<Void, Never>? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            message = "The file could not be read as text."
            return nil
        }
        return importText(text)
    }

    /// btn:[Transpose]: the view flag, never rewriting cells.
    @discardableResult
    func transpose() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        sink.perform(SetChartFields(chart, .init(transposed: !model.props.transposed)))
    }

    /// btn:[Switch XY] (scatter charts).
    @discardableResult
    func switchXY() -> Task<Wiretuner_Doc_V1_Change?, Never> {
        sink.perform(SetChartFields(chart, .init(switchXY: !model.props.switchXy)))
    }

    var isScatter: Bool { type == .scatter }

    // MARK: Type tab

    /// The Type draft's registers that differ from the chart.
    var pending: SetChartFields.Values {
        let props = model.props
        var values = SetChartFields.Values()
        let stored = Self.storedType(props)
        if type != stored { values.type = Self.renderType(type) }
        if options != props.options { values.options = options }
        if xAxis != props.xAxis { values.xAxis = xAxis }
        if yAxis != props.yAxis { values.yAxis = yAxis }
        if decimalPrecision != Int(props.decimalPrecision) { values.decimalPrecision = min(max(decimalPrecision, 0), 10) }
        if thousandsSeparator != props.thousandsSeparator { values.thousandsSeparator = thousandsSeparator }
        return values
    }

    /// btn:[Apply]: the pending registers and the entry's draft, if it changed.
    @discardableResult
    func apply() -> Task<Void, Never> {
        let values = pending
        let draft = entry != text(at: active) ? commit() : nil
        let sink = sink
        let chart = chart
        let task = Task { @MainActor in
            await draft?.value
            guard values != SetChartFields.Values() else { return }
            _ = await sink.perform(SetChartFields(chart, values)).value
        }
        last = task
        return task
    }

    /// btn:[Cancel]: the drafts discarded (committed cells stay).
    func cancel() {
        let props = model.props
        type = Self.storedType(props)
        options = props.options
        xAxis = props.xAxis
        yAxis = props.yAxis
        decimalPrecision = Int(props.decimalPrecision)
        thousandsSeparator = props.thousandsSeparator
        entry = text(at: active)
    }

    /// Whether the axis buttons are enabled: not for pies.
    var axesEnabled: Bool { type != .pie }

    /// The chart's type as read (unset is grouped columns).
    static func storedType(_ props: Wiretuner_Doc_V1_ChartProps) -> Wiretuner_Doc_V1_ChartType {
        props.type == .unspecified ? .groupedColumn : props.type
    }

    static func renderType(_ type: Wiretuner_Doc_V1_ChartType) -> ChartType {
        switch type {
        case .stackedColumn: .stackedColumn
        case .line: .line
        case .pie: .pie
        case .area: .area
        case .scatter: .scatter
        default: .groupedColumn
        }
    }
}

/// The op limit a chart import is held to (`ChartEditing.opLimit`, WTModel).
enum ChartEditingLimits {
    static let opLimit = 10_000
}
