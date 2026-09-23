import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Why a chart command could not build its change.
public enum ChartError: Error, Equatable, Sendable {
    case notAChart(OpID)
    /// A row or column that is not a live element of the chart.
    case unknownElement(OpID)
    /// An import larger than one change may be (charts.adoc, "Offline behavior": 10,000 ops).
    case tooLarge(ops: Int)
}

/// Shared checks and element writes of the chart commands.
enum ChartEditing {
    /// The op limit of one change (crdt-model.adoc).
    static let opLimit = 10_000

    static func chart(_ node: OpID, in state: EngineState) throws -> Chart {
        guard state.isLive(node), case .chart(let props)? = state.props(node).kind else { throw ChartError.notAChart(node) }
        return Chart(props)
    }

    static func values(_ build: (inout Wiretuner_Doc_V1_ChartProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
        var props = Wiretuner_Doc_V1_NodeProps()
        build(&props.chart)
        return props
    }

    /// `count` new elements appended to (or inserted after `after` in) the sequence `sequence`.
    static func keys(_ node: OpID, _ sequence: RegisterPath, after: OpID?, count: Int, in state: EngineState) throws -> [[UInt8]] {
        let live = state.liveElements(node, sequence)
        let anchor = after ?? live.last
        let lo = anchor.flatMap { state.position(node, sequence, $0) }
        let next = anchor.flatMap { live.firstIndex(of: $0) }.flatMap { live.indices.contains($0 + 1) ? live[$0 + 1] : nil }
        let hi = after == nil ? nil : next.flatMap { state.position(node, sequence, $0) }
        return try PathEditing.keys(between: lo, and: hi, count: count)
    }
}

/// The Chart tool's drag (charts.adoc, "Creating a chart"): an empty chart of `size` placed by
/// `transform` on top of the active layer, grouped columns, two decimals.
public struct CreateChart: Command {
    public var size: Size
    public var transform: AffineTransform
    public var type: ChartType
    public var layer: OpID?
    public var label: String { "Chart" }

    public init(size: Size, transform: AffineTransform = .identity, type: ChartType = .groupedColumn, layer: OpID? = nil) {
        self.size = size
        self.transform = transform
        self.type = type
        self.layer = layer
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { throw ObjectEditError.invalidValue("size") }
        let layer = try PathEditing.ensureLayer(&builder, state: state, preferred: self.layer)
        let props = ChartEditing.values { chart in
            chart.size.width = size.width
            chart.size.height = size.height
            chart.type = Chart.proto(type)
            chart.decimalPrecision = 2
            if !transform.isIdentity { chart.common.transform = PathEditing.proto(transform) }
        }
        builder.append(Ops.create(parent: layer, position: try PathEditing.topPosition(in: layer, state: state), props: props))
    }
}

/// A cell commit in the Chart sheet ("Edit Chart Data"): the winning cell's `text` register, or
/// a new cell in the row for the column when the slot has none.
public struct SetChartCell: Command {
    public var chart: OpID
    public var row: OpID
    public var column: OpID
    public var text: String
    public var label: String { "Edit Chart Data" }

    public init(_ chart: OpID, row: OpID, column: OpID, text: String) {
        self.chart = chart
        self.row = row
        self.column = column
        self.text = text
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let model = try ChartEditing.chart(chart, in: state)
        guard model.rows.contains(row) else { throw ChartError.unknownElement(row) }
        guard model.columns.contains(column) else { throw ChartError.unknownElement(column) }
        var cell = Wiretuner_Doc_V1_ChartCell()
        cell.text = String(text.prefix(1024))
        var row = Wiretuner_Doc_V1_ChartRow()
        if let existing = model.cells[self.row]?[column] {
            guard existing.text != cell.text else { return }
            row.cells = [cell]
            builder.append(Ops.set(chart, [ChartFields.cellText(self.row, existing.id)], values: ChartEditing.values { $0.rows = [row] }))
        } else {
            guard !cell.text.isEmpty else { return }
            cell.column = column.elementID
            row.cells = [cell]
            let keys = try ChartEditing.keys(chart, ChartFields.cells(self.row), after: nil, count: 1, in: state)
            builder.append(Ops.elementInsert(chart, ChartFields.cells(self.row), positions: keys, values: ChartEditing.values { $0.rows = [row] }))
        }
    }
}

/// Inserts `count` empty rows or columns after `after` (at the end when nil): "Insert Row",
/// "Insert 3 Columns".
public struct InsertChartLines: Command {
    public enum Axis: Hashable, Sendable {
        case rows, columns
    }

    public var chart: OpID
    public var axis: Axis
    public var count: Int
    public var after: OpID?
    public var label: String {
        let noun = axis == .rows ? "Row" : "Column"
        return count == 1 ? "Insert \(noun)" : "Insert \(count) \(noun)s"
    }

    public init(_ chart: OpID, _ axis: Axis, count: Int = 1, after: OpID? = nil) {
        self.chart = chart
        self.axis = axis
        self.count = count
        self.after = after
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let model = try ChartEditing.chart(chart, in: state)
        guard count > 0 else { return }
        let sequence = axis == .rows ? ChartFields.rows : ChartFields.columns
        if let after, !(axis == .rows ? model.rows : model.columns).contains(after) { throw ChartError.unknownElement(after) }
        let keys = try ChartEditing.keys(chart, sequence, after: after, count: count, in: state)
        let values = ChartEditing.values { chart in
            if axis == .rows { chart.rows = Array(repeating: Wiretuner_Doc_V1_ChartRow(), count: count) } else {
                chart.columns = Array(repeating: Wiretuner_Doc_V1_ChartColumn(), count: count)
            }
        }
        builder.append(Ops.elementInsert(chart, sequence, positions: keys, values: values))
    }
}

/// Deletes rows or columns: "Delete Row", "Delete 2 Columns".  A deleted column's cells stay in
/// their rows and are not read.
public struct DeleteChartLines: Command {
    public var chart: OpID
    public var axis: InsertChartLines.Axis
    public var lines: [OpID]
    public var label: String {
        let noun = axis == .rows ? "Row" : "Column"
        return lines.count == 1 ? "Delete \(noun)" : "Delete \(lines.count) \(noun)s"
    }

    public init(_ chart: OpID, _ axis: InsertChartLines.Axis, _ lines: [OpID]) {
        self.chart = chart
        self.axis = axis
        self.lines = lines
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let model = try ChartEditing.chart(chart, in: state)
        let live = axis == .rows ? model.rows : model.columns
        let sequence = axis == .rows ? ChartFields.rows : ChartFields.columns
        for line in lines where !live.contains(line) { throw ChartError.unknownElement(line) }
        guard !lines.isEmpty else { return }
        builder.append(Ops.elementDelete(chart, lines.map { sequence.element($0) }))
    }
}

/// btn:[Import…] and pasting a whole table (charts.adoc, "Import vs. edit"): deletes every row
/// and column and inserts the table's in one change, a cell per non-empty slot.  Refused when the
/// change would pass the op limit.
public struct ImportChartData: Command {
    public var chart: OpID
    public var table: [[String]]
    public var label: String { "Import Chart Data" }

    public init(_ chart: OpID, table: [[String]]) {
        self.chart = chart
        self.table = table
    }

    /// A tab-delimited UTF-8 text (one line per row).
    public init(_ chart: OpID, tabDelimited text: String) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let trimmed = lines.last == "" ? Array(lines.dropLast()) : lines
        self.init(chart, table: trimmed.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) })
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let model = try ChartEditing.chart(chart, in: state)
        let width = table.map(\.count).max() ?? 0
        let filledRows = table.filter { $0.contains { !$0.isEmpty } }.count
        let ops = 2 + (width > 0 ? 1 : 0) + (table.isEmpty ? 0 : 1) + filledRows
        guard ops <= ChartEditing.opLimit else { throw ChartError.tooLarge(ops: ops) }
        if !model.rows.isEmpty { builder.append(Ops.elementDelete(chart, model.rows.map { ChartFields.rows.element($0) })) }
        if !model.columns.isEmpty { builder.append(Ops.elementDelete(chart, model.columns.map { ChartFields.columns.element($0) })) }
        guard !table.isEmpty else { return }
        let lastColumn = state.liveElements(chart, ChartFields.columns).last.flatMap { state.position(chart, ChartFields.columns, $0) }
        var columns: [OpID] = []
        if width > 0 {
            let keys = try PathEditing.keys(between: lastColumn, and: nil, count: width)
            let first = builder.append(Ops.elementInsert(chart, ChartFields.columns, positions: keys,
                                                         values: ChartEditing.values { $0.columns = Array(repeating: Wiretuner_Doc_V1_ChartColumn(), count: width) }))
            columns = (0..<width).map { OpID(counter: first.counter + UInt64($0), replica: first.replica) }
        }
        let lastRow = state.liveElements(chart, ChartFields.rows).last.flatMap { state.position(chart, ChartFields.rows, $0) }
        let rowKeys = try PathEditing.keys(between: lastRow, and: nil, count: table.count)
        let first = builder.append(Ops.elementInsert(chart, ChartFields.rows, positions: rowKeys,
                                                     values: ChartEditing.values { $0.rows = Array(repeating: Wiretuner_Doc_V1_ChartRow(), count: table.count) }))
        for (index, texts) in table.enumerated() {
            let cells = texts.enumerated().filter { !$0.element.isEmpty }.map { column, text -> Wiretuner_Doc_V1_ChartCell in
                var cell = Wiretuner_Doc_V1_ChartCell()
                cell.column = columns[column].elementID
                cell.text = String(text.prefix(1024))
                return cell
            }
            guard !cells.isEmpty else { continue }
            let row = OpID(counter: first.counter + UInt64(index), replica: first.replica)
            var value = Wiretuner_Doc_V1_ChartRow()
            value.cells = cells
            let keys = try PathEditing.keys(between: nil, and: nil, count: cells.count)
            builder.append(Ops.elementInsert(chart, ChartFields.cells(row), positions: keys, values: ChartEditing.values { $0.rows = [value] }))
        }
    }
}

/// The Chart sheet's btn:[Apply] for everything but cells: every register given that differs from
/// the stored value, in one change ("Transpose", "Switch XY", "Change Chart Type", "Change Chart").
public struct SetChartFields: Command {
    public struct Values: Hashable, Sendable {
        public var transposed: Bool?
        public var switchXY: Bool?
        public var type: ChartType?
        public var decimalPrecision: Int?
        public var thousandsSeparator: Bool?
        public var size: Size?
        public var options: Wiretuner_Doc_V1_ChartOptions?
        public var xAxis: Wiretuner_Doc_V1_AxisOptions?
        public var yAxis: Wiretuner_Doc_V1_AxisOptions?

        public init(transposed: Bool? = nil, switchXY: Bool? = nil, type: ChartType? = nil, decimalPrecision: Int? = nil, thousandsSeparator: Bool? = nil,
                    size: Size? = nil, options: Wiretuner_Doc_V1_ChartOptions? = nil, xAxis: Wiretuner_Doc_V1_AxisOptions? = nil,
                    yAxis: Wiretuner_Doc_V1_AxisOptions? = nil) {
            self.transposed = transposed
            self.switchXY = switchXY
            self.type = type
            self.decimalPrecision = decimalPrecision
            self.thousandsSeparator = thousandsSeparator
            self.size = size
            self.options = options
            self.xAxis = xAxis
            self.yAxis = yAxis
        }
    }

    public var chart: OpID
    public var values: Values
    public var label: String {
        let given = [values.transposed != nil, values.switchXY != nil, values.type != nil,
                     values.decimalPrecision != nil || values.thousandsSeparator != nil || values.size != nil || values.options != nil
                         || values.xAxis != nil || values.yAxis != nil]
        guard given.filter({ $0 }).count == 1 else { return "Change Chart" }
        if values.transposed != nil { return "Transpose" }
        if values.switchXY != nil { return "Switch XY" }
        return values.type != nil ? "Change Chart Type" : "Change Chart"
    }

    public init(_ chart: OpID, _ values: Values) {
        self.chart = chart
        self.values = values
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let stored = try ChartEditing.chart(chart, in: state).props
        if let precision = values.decimalPrecision, !(0...10).contains(precision) { throw ObjectEditError.invalidValue("decimalPrecision") }
        if let size = values.size, !(size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite) {
            throw ObjectEditError.invalidValue("size")
        }
        var props = Wiretuner_Doc_V1_ChartProps()
        var paths: [RegisterPath] = []
        func write(_ path: RegisterPath, changed: Bool, _ assign: (inout Wiretuner_Doc_V1_ChartProps) -> Void) {
            guard changed else { return }
            assign(&props)
            paths.append(path)
        }
        if let value = values.transposed { write(ChartFields.transposed, changed: value != stored.transposed) { $0.transposed = value } }
        if let value = values.switchXY { write(ChartFields.switchXY, changed: value != stored.switchXy) { $0.switchXy = value } }
        if let value = values.type.map(Chart.proto) { write(ChartFields.type, changed: value != stored.type) { $0.type = value } }
        if let value = values.decimalPrecision.map(UInt32.init) {
            write(ChartFields.decimalPrecision, changed: value != stored.decimalPrecision) { $0.decimalPrecision = value }
        }
        if let value = values.thousandsSeparator {
            write(ChartFields.thousandsSeparator, changed: value != stored.thousandsSeparator) { $0.thousandsSeparator = value }
        }
        if let value = values.size {
            write(ChartFields.size, changed: value.width != stored.size.width || value.height != stored.size.height) {
                $0.size.width = value.width
                $0.size.height = value.height
            }
        }
        // Options and axes are STRUCTs: one register per field that changed.
        if let value = values.options {
            for (number, changed) in Self.changedFields(try value.serializedBytes(), try stored.options.serializedBytes()) where changed {
                write(ChartFields.options.child(number), changed: true) { $0.options = value }
            }
        }
        for (path, value, old) in [(ChartFields.xAxis, values.xAxis, stored.xAxis), (ChartFields.yAxis, values.yAxis, stored.yAxis)] {
            guard let value else { continue }
            for (number, changed) in Self.changedFields(try value.serializedBytes(), try old.serializedBytes()) where changed {
                write(path.child(number), changed: true) { chart in
                    if path == ChartFields.xAxis { chart.xAxis = value } else { chart.yAxis = value }
                }
            }
        }
        guard !paths.isEmpty else { return }
        var values = Wiretuner_Doc_V1_NodeProps()
        values.chart = props
        builder.append(Ops.set(chart, paths, values: values))
    }

    /// Field numbers present in either encoding, and whether their values differ.
    static func changedFields(_ new: [UInt8], _ old: [UInt8]) -> [(UInt32, Bool)] {
        func fields(_ bytes: [UInt8]) -> [UInt32: [UInt8]] {
            var result: [UInt32: [UInt8]] = [:]
            for field in WireReader.fields(bytes) ?? [] { result[field.number] = field.record }
            return result
        }
        let a = fields(new), b = fields(old)
        return Set(a.keys).union(b.keys).sorted().map { ($0, a[$0] != b[$0]) }
    }
}

/// Styling one series or one element of a chart (DRAW-034's writes; "Style chart element"): the
/// override for `(series, index)` gets `appearance` (replacing its fills and strokes), `transform`
/// and the pictograph fields that are given, created when the key has none.
public struct SetChartOverride: Command {
    public var chart: OpID
    public var key: ChartElementKeyRef
    public var appearance: Wiretuner_Doc_V1_AppearanceProps?
    public var transform: AffineTransform?
    /// A live child of the chart; `.some(nil)` clears the pictograph.
    public var pictograph: OpID??
    public var repeating: Bool?
    public var label: String { "Style chart element" }

    public init(_ chart: OpID, key: ChartElementKeyRef, appearance: Wiretuner_Doc_V1_AppearanceProps? = nil, transform: AffineTransform? = nil,
                pictograph: OpID?? = nil, repeating: Bool? = nil) {
        self.chart = chart
        self.key = key
        self.appearance = appearance
        self.transform = transform
        self.pictograph = pictograph
        self.repeating = repeating
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        let model = try ChartEditing.chart(chart, in: state)
        let table = model.table
        guard table.series.contains(where: { $0.id == NodeID(key.series) }) else { throw ChartError.unknownElement(key.series) }
        if let index = key.index, !table.categories.contains(where: { $0.id == NodeID(index) }) { throw ChartError.unknownElement(index) }
        if let target = pictograph ?? nil, !(state.isLive(target) && Objects.parent(of: target, in: state) == chart) { throw ChartError.unknownElement(target) }
        var value = Wiretuner_Doc_V1_ChartOverride()
        var fields: [UInt32] = []
        if let transform {
            value.transform = PathEditing.proto(transform)
            fields.append(5)
        }
        if let pictograph {
            if let target = pictograph { value.pictograph.id = target.proto }
            fields.append(6)
        }
        if let repeating {
            value.repeating = repeating
            fields.append(7)
        }
        let element: OpID
        if let existing = model.liveOverrides(for: table)[key], let id = OpID(element: existing.id) {
            element = id
            if !fields.isEmpty {
                builder.append(Ops.set(chart, fields.map { ChartFields.override(id).child($0) }, values: ChartEditing.values { $0.overrides = [value] }))
            }
            if appearance != nil {
                let stale = existing.appearance.fills.compactMap { OpID(element: $0.id) }.map { ChartFields.override(id).child(4).child(1).element($0) }
                    + existing.appearance.strokes.compactMap { OpID(element: $0.id) }.map { ChartFields.override(id).child(4).child(2).element($0) }
                if !stale.isEmpty { builder.append(Ops.elementDelete(chart, stale)) }
            }
        } else {
            value.series = key.series.elementID
            if let index = key.index { value.index = index.elementID }
            let keys = try ChartEditing.keys(chart, ChartFields.overrides, after: nil, count: 1, in: state)
            element = builder.append(Ops.elementInsert(chart, ChartFields.overrides, positions: keys, values: ChartEditing.values { $0.overrides = [value] }))
        }
        guard let appearance else { return }
        let base = ChartFields.override(element).child(4)
        let keys = try PathEditing.keys(between: nil, and: nil, count: appearance.fills.count + appearance.strokes.count)
        func stack(_ build: (inout Wiretuner_Doc_V1_AppearanceProps) -> Void) -> Wiretuner_Doc_V1_NodeProps {
            var override = Wiretuner_Doc_V1_ChartOverride()
            build(&override.appearance)
            return ChartEditing.values { $0.overrides = [override] }
        }
        if !appearance.fills.isEmpty {
            builder.append(Ops.elementInsert(chart, base.child(1), positions: Array(keys.prefix(appearance.fills.count)), values: stack { $0.fills = appearance.fills }))
        }
        if !appearance.strokes.isEmpty {
            builder.append(Ops.elementInsert(chart, base.child(2), positions: Array(keys.suffix(appearance.strokes.count)), values: stack { $0.strokes = appearance.strokes }))
        }
    }
}
