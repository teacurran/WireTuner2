import Foundation
import WTCRDT
import WTGeometry
import WTProto
import WTRender

/// Register paths of `ChartProps` (kind `chart` = 24; charts.adoc, "Data model").
public enum ChartFields {
    static let kind = NodeKind.chart.rawValue
    public static let size = RegisterPath([kind, 2])
    public static let columns = RegisterPath([kind, 3])
    public static let rows = RegisterPath([kind, 4])
    public static let transposed = RegisterPath([kind, 5])
    public static let switchXY = RegisterPath([kind, 6])
    public static let decimalPrecision = RegisterPath([kind, 7])
    public static let thousandsSeparator = RegisterPath([kind, 8])
    public static let type = RegisterPath([kind, 9])
    public static let options = RegisterPath([kind, 10])
    public static let xAxis = RegisterPath([kind, 11])
    public static let yAxis = RegisterPath([kind, 12])
    public static let overrides = RegisterPath([kind, 13])

    public static func cells(_ row: OpID) -> RegisterPath { rows.element(row).child(2) }
    public static func cellText(_ row: OpID, _ cell: OpID) -> RegisterPath { cells(row).element(cell).child(3) }
    public static func override(_ element: OpID) -> RegisterPath { overrides.element(element) }
}

/// A chart as read (DRAW-032, `WTModel.Chart`; charts.adoc "Read-time normalizations"): the live
/// columns and rows in sequence order and, per row, the winning cell of each live column (of
/// several, the greatest cell id; cells of deleted columns are not read).
public struct Chart: Hashable, Sendable {
    public var columns: [OpID]
    public var rows: [OpID]
    /// Row → column → (cell element, text).
    public var cells: [OpID: [OpID: Cell]]
    public var props: Wiretuner_Doc_V1_ChartProps

    public struct Cell: Hashable, Sendable {
        public var id: OpID
        public var text: String
    }

    public init(_ props: Wiretuner_Doc_V1_ChartProps) {
        self.props = props
        columns = props.columns.map { Self.id($0.id) }
        rows = props.rows.map { Self.id($0.id) }
        let live = Set(columns)
        var cells: [OpID: [OpID: Cell]] = [:]
        for row in props.rows {
            var byColumn: [OpID: Cell] = [:]
            for cell in row.cells where live.contains(Self.id(cell.column)) {
                let id = Self.id(cell.id)
                if let existing = byColumn[Self.id(cell.column)], existing.id > id { continue }
                byColumn[Self.id(cell.column)] = Cell(id: id, text: cell.text)
            }
            cells[Self.id(row.id)] = byColumn
        }
        self.cells = cells
    }

    /// An element id as read (every stored element carries one).
    static func id(_ element: Wiretuner_Doc_V1_ElementId) -> OpID {
        OpID(counter: element.counter, replica: element.replica)
    }

    /// The text of the cell at `row`, `column` ("" where there is none).
    public func text(row: OpID, column: OpID) -> String {
        cells[row]?[column]?.text ?? ""
    }

    /// The table as the sheet shows it, rows by columns (transposition not applied).
    public var grid: [[String]] {
        rows.map { row in columns.map { text(row: row, column: $0) } }
    }

    // MARK: Normalized table

    /// Whether a cell's text is a label rather than a value: quoted, or not a number.
    static func isLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && (isQuoted(trimmed) || number(trimmed) == nil)
    }

    static func isQuoted(_ text: String) -> Bool {
        text.count >= 2 && text.hasPrefix("\"") && text.hasSuffix("\"")
    }

    /// A label's text: quotes removed.
    static func label(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return isQuoted(trimmed) ? String(trimmed.dropFirst().dropLast()) : trimmed
    }

    /// A value cell's number; nil for text that is not one (commas as thousands separators are
    /// accepted).
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// The normalized table: transposition applied (the sheet's rows become columns), then the
    /// first row taken as the legend when it holds labels and no values, and the first column as
    /// the categories likewise; every other column is a series and every other row a category,
    /// keyed by the element ids of the stored columns and rows.  Missing and non-numeric cells
    /// read 0.  With *Switch XY* each pair of scatter columns swaps.
    public var table: ChartTable {
        var keysAcross = columns
        var keysDown = rows
        var grid = self.grid
        if props.transposed {
            swap(&keysAcross, &keysDown)
            grid = keysDown.indices.map { down in keysAcross.indices.map { across in grid[across][down] } }
        }
        func isLabelLine(_ texts: [String]) -> Bool {
            texts.contains(where: Self.isLabel) && !texts.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !Self.isLabel($0) }
        }
        let legendRow = !grid.isEmpty && isLabelLine(Array(grid[0].dropFirst()))
        let categoryColumn = !keysAcross.isEmpty && isLabelLine(grid.dropFirst(legendRow ? 1 : 0).map { $0[0] })
        let top = legendRow ? 1 : 0
        let left = categoryColumn ? 1 : 0
        var seriesIndices = Array(left..<keysAcross.count)
        if props.switchXy, props.type == .scatter {
            for pair in stride(from: 0, to: seriesIndices.count - 1, by: 2) {
                seriesIndices.swapAt(pair, pair + 1)
            }
        }
        let series = seriesIndices.map { ChartKey(id: NodeID(keysAcross[$0]), label: legendRow ? Self.label(grid[0][$0]) : "") }
        let categories = (top..<keysDown.count).map { ChartKey(id: NodeID(keysDown[$0]), label: categoryColumn ? Self.label(grid[$0][0]) : "") }
        let values = (top..<keysDown.count).map { down in seriesIndices.map { across in Self.number(grid[down][across]) ?? 0 } }
        return ChartTable(series: series, categories: categories, values: values)
    }

    // MARK: Spec

    /// The live overrides after the read-time rules: of several for one `(series, index)` the
    /// greatest element id; one whose series is not a series of `table`, or whose index is set
    /// and not a category, is ignored.
    public func liveOverrides(for table: ChartTable) -> [ChartElementKeyRef: Wiretuner_Doc_V1_ChartOverride] {
        let series = Set(table.series.map(\.id))
        let categories = Set(table.categories.map(\.id))
        var result: [ChartElementKeyRef: Wiretuner_Doc_V1_ChartOverride] = [:]
        for override in props.overrides {
            guard let id = OpID(element: override.id), let seriesID = OpID(element: override.series), series.contains(NodeID(seriesID)) else { continue }
            let index = OpID(element: override.index)
            if let index, !categories.contains(NodeID(index)) { continue }
            let key = ChartElementKeyRef(series: seriesID, index: index)
            if let existing = result[key], let other = OpID(element: existing.id), other > id { continue }
            result[key] = override
        }
        return result
    }

    /// The layout input of the chart `node`; `pictograph` gives a pictograph source node's items
    /// in its own space (nil when it is not a live child of the chart).  Nil when `size` is not
    /// positive (the chart draws nothing).
    public func spec(node: OpID, pictograph: (OpID) -> [DisplayItem]? = { _ in nil }) -> ChartSpec? {
        guard props.size.width > 0, props.size.height > 0, props.size.width.isFinite, props.size.height.isFinite else { return nil }
        let table = self.table
        var seriesStyles: [NodeID: ChartStyle] = [:]
        var elementStyles: [ChartElementKey: ChartStyle] = [:]
        for (key, override) in liveOverrides(for: table) {
            let appearance = override.appearance.fills.isEmpty && override.appearance.strokes.isEmpty ? nil : Appearances.resolve(override.appearance)
            let style = ChartStyle(
                appearance: appearance, transform: override.hasTransform ? PathEditing.transform(override.transform) : nil,
                pictograph: override.hasPictograph ? pictograph(OpID(override.pictograph.id)) : nil, repeating: override.repeating
            )
            if let index = key.index {
                elementStyles[ChartElementKey(series: NodeID(key.series), index: NodeID(index))] = style
            } else {
                seriesStyles[NodeID(key.series)] = style
            }
        }
        return ChartSpec(
            chart: NodeID(node), type: Self.type(props.type), size: Size(width: props.size.width, height: props.size.height), table: table,
            options: Self.options(props.options), xAxis: Self.axis(props.xAxis), yAxis: Self.axis(props.yAxis),
            decimalPrecision: Int(props.decimalPrecision), thousandsSeparator: props.thousandsSeparator,
            seriesStyles: seriesStyles, elementStyles: elementStyles
        )
    }

    static func type(_ type: Wiretuner_Doc_V1_ChartType) -> ChartType {
        switch type {
        case .stackedColumn: .stackedColumn
        case .line: .line
        case .pie: .pie
        case .area: .area
        case .scatter: .scatter
        default: .groupedColumn
        }
    }

    static func proto(_ type: ChartType) -> Wiretuner_Doc_V1_ChartType {
        switch type {
        case .groupedColumn: .groupedColumn
        case .stackedColumn: .stackedColumn
        case .line: .line
        case .pie: .pie
        case .area: .area
        case .scatter: .scatter
        }
    }

    /// Widths of 0 read as 80; unset enums as the defaults (square markers, the axis at the left).
    static func options(_ options: Wiretuner_Doc_V1_ChartOptions) -> ChartOptions {
        let markers: [Wiretuner_Doc_V1_ChartMarker: ChartMarker] = [.none: .none, .diamond: .diamond, .triangle: .triangle, .circle: .circle]
        let display: [Wiretuner_Doc_V1_ChartAxisDisplay: ChartAxisDisplay] = [.right: .right, .both: .both]
        return ChartOptions(
            columnWidth: options.columnWidth > 0 ? options.columnWidth : 80, clusterWidth: options.clusterWidth > 0 ? options.clusterWidth : 80,
            pieSeparation: min(max(options.pieSeparation, 0), 50), markers: markers[options.markers] ?? .square, dataNumbers: options.dataNumbers,
            dropShadow: options.dropShadow, legendsAcrossTop: options.legendsAcrossTop, axisDisplay: display[options.axisDisplay] ?? .left,
            gridlinesX: options.gridlinesX, gridlinesY: options.gridlinesY
        )
    }

    /// Unset tick styles read as outside (major) and none (minor); a manual range with a zero or
    /// non-finite step, or minimum not below maximum, reads as automatic.
    static func axis(_ axis: Wiretuner_Doc_V1_AxisOptions) -> ChartAxis {
        func tick(_ style: Wiretuner_Doc_V1_ChartTickStyle, _ fallback: ChartTickStyle) -> ChartTickStyle {
            let styles: [Wiretuner_Doc_V1_ChartTickStyle: ChartTickStyle] = [.none: .none, .across: .across, .inside: .inside, .outside: .outside]
            return styles[style] ?? fallback
        }
        let valid = axis.manual && [axis.minimum, axis.maximum, axis.between].allSatisfy(\.isFinite) && axis.between != 0 && axis.minimum < axis.maximum
        return ChartAxis(
            manual: valid ? ChartAxisRange(minimum: axis.minimum, maximum: axis.maximum, between: axis.between) : nil,
            major: tick(axis.major, .outside), minor: tick(axis.minor, .none), minorCount: Int(axis.minorCount), prefix: axis.prefix, suffix: axis.suffix
        )
    }
}

/// A style override's key in the model: a series and, for one element, its category.
public struct ChartElementKeyRef: Hashable, Sendable {
    public var series: OpID
    public var index: OpID?

    public init(series: OpID, index: OpID? = nil) {
        self.series = series
        self.index = index
    }
}
