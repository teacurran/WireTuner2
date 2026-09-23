// A chart's layout input (DRAW-032; docs/_includes/drawing/charts.adoc, "Layout engine"): the
// render-side mirror of `ChartProps` after WTModel's read-time normalizations (cells deduped,
// transposition applied, missing cells 0, dangling overrides dropped, widths of 0 read as 80).
// Series and categories keep the element ids of the table's columns and rows, which are the
// stable keys of synthetic elements and style overrides.

import WTGeometry

/// `ChartType`.
public enum ChartType: Hashable, Sendable, CaseIterable {
    case groupedColumn
    case stackedColumn
    case line
    case pie
    case area
    case scatter
}

/// `ChartMarker`.
public enum ChartMarker: Hashable, Sendable, CaseIterable {
    case none
    case square
    case diamond
    case triangle
    case circle
}

/// `ChartAxisDisplay`: where the value axis is drawn.
public enum ChartAxisDisplay: Hashable, Sendable {
    case left
    case right
    case both
}

/// `ChartTickStyle`.
public enum ChartTickStyle: Hashable, Sendable {
    case none
    case across
    case inside
    case outside
}

/// `ChartOptions`.
public struct ChartOptions: Hashable, Sendable {
    /// Percent of the space a column may take; over 100 overlaps.
    public var columnWidth: Double
    /// Percent of a category's space its group takes (grouped columns).
    public var clusterWidth: Double
    /// Pie: gap between wedges, 0...50.
    public var pieSeparation: Double
    public var markers: ChartMarker
    public var dataNumbers: Bool
    public var dropShadow: Bool
    public var legendsAcrossTop: Bool
    public var axisDisplay: ChartAxisDisplay
    /// Horizontal lines across the plot at the value ticks.
    public var gridlinesX: Bool
    /// Vertical lines across the plot at the category boundaries (or x ticks).
    public var gridlinesY: Bool

    public init(
        columnWidth: Double = 80,
        clusterWidth: Double = 80,
        pieSeparation: Double = 0,
        markers: ChartMarker = .square,
        dataNumbers: Bool = false,
        dropShadow: Bool = false,
        legendsAcrossTop: Bool = false,
        axisDisplay: ChartAxisDisplay = .left,
        gridlinesX: Bool = false,
        gridlinesY: Bool = false
    ) {
        self.columnWidth = columnWidth
        self.clusterWidth = clusterWidth
        self.pieSeparation = pieSeparation
        self.markers = markers
        self.dataNumbers = dataNumbers
        self.dropShadow = dropShadow
        self.legendsAcrossTop = legendsAcrossTop
        self.axisDisplay = axisDisplay
        self.gridlinesX = gridlinesX
        self.gridlinesY = gridlinesY
    }
}

/// A hand-set axis range (`AxisOptions` with `manual`).
public struct ChartAxisRange: Hashable, Sendable {
    public var minimum: Double
    public var maximum: Double
    /// The step between labelled values; negative runs the axis from high to low.
    public var between: Double

    public init(minimum: Double, maximum: Double, between: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.between = between
    }
}

/// `AxisOptions`.
public struct ChartAxis: Hashable, Sendable {
    /// Minimum, maximum and step set by hand; nil calculates them from the data.
    public var manual: ChartAxisRange?
    public var major: ChartTickStyle
    public var minor: ChartTickStyle
    /// Minor ticks per major interval.
    public var minorCount: Int
    public var prefix: String
    public var suffix: String

    public init(manual: ChartAxisRange? = nil, major: ChartTickStyle = .outside, minor: ChartTickStyle = .none, minorCount: Int = 0, prefix: String = "", suffix: String = "") {
        self.manual = manual
        self.major = major
        self.minor = minor
        self.minorCount = max(minorCount, 0)
        self.prefix = prefix
        self.suffix = suffix
    }
}

/// A series (a table column, or a row where the type plots rows) or a category.
public struct ChartKey: Hashable, Sendable {
    public var id: NodeID
    public var label: String

    public init(id: NodeID, label: String) {
        self.id = id
        self.label = label
    }
}

/// The normalized data table: `values[category][series]`.
public struct ChartTable: Hashable, Sendable {
    public var series: [ChartKey]
    public var categories: [ChartKey]
    public var values: [[Double]]

    public init(series: [ChartKey], categories: [ChartKey], values: [[Double]]) {
        self.series = series
        self.categories = categories
        self.values = values
    }

    /// The value at `category`, `series`; 0 where the table is short (a missing cell).
    public func value(_ category: Int, _ series: Int) -> Double {
        guard values.indices.contains(category), values[category].indices.contains(series) else {
            return 0
        }
        let value = values[category][series]
        return value.isFinite ? value : 0
    }
}

/// Styling and a pictograph for one series or one element of it (`ChartOverride`).
public struct ChartStyle: Hashable, Sendable {
    /// Replaces the default gray fill and black stroke; nil keeps them.
    public var appearance: Appearance?
    /// An extra transform about the element's own bounds centre.
    public var transform: AffineTransform?
    /// Artwork (pictograph-local items) drawn in place of the column.
    public var pictograph: [DisplayItem]?
    /// Stack copies to the column's height (a clipped partial last); otherwise stretch one.
    public var repeating: Bool

    public init(appearance: Appearance? = nil, transform: AffineTransform? = nil, pictograph: [DisplayItem]? = nil, repeating: Bool = false) {
        self.appearance = appearance
        self.transform = transform
        self.pictograph = pictograph
        self.repeating = repeating
    }
}

/// Everything the layout reads.
public struct ChartSpec: Hashable, Sendable {
    /// The chart node, the first part of every synthetic id.
    public var chart: NodeID
    public var type: ChartType
    /// The plot area, local units.
    public var size: Size
    public var table: ChartTable
    public var options: ChartOptions
    /// The category (or, for scatter, x) axis.
    public var xAxis: ChartAxis
    /// The value axis.
    public var yAxis: ChartAxis
    public var decimalPrecision: Int
    public var thousandsSeparator: Bool
    /// Series-wide styles by series id.
    public var seriesStyles: [NodeID: ChartStyle]
    /// Element styles by (series id, category id); these win over the series'.
    public var elementStyles: [ChartElementKey: ChartStyle]

    public init(
        chart: NodeID,
        type: ChartType,
        size: Size,
        table: ChartTable,
        options: ChartOptions = ChartOptions(),
        xAxis: ChartAxis = ChartAxis(),
        yAxis: ChartAxis = ChartAxis(),
        decimalPrecision: Int = 2,
        thousandsSeparator: Bool = false,
        seriesStyles: [NodeID: ChartStyle] = [:],
        elementStyles: [ChartElementKey: ChartStyle] = [:]
    ) {
        self.chart = chart
        self.type = type
        self.size = size
        self.table = table
        self.options = options
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.decimalPrecision = min(max(decimalPrecision, 0), 10)
        self.thousandsSeparator = thousandsSeparator
        self.seriesStyles = seriesStyles
        self.elementStyles = elementStyles
    }
}

/// A (series, category) pair: the key of an element style.
public struct ChartElementKey: Hashable, Sendable {
    public var series: NodeID
    public var index: NodeID

    public init(series: NodeID, index: NodeID) {
        self.series = series
        self.index = index
    }
}

/// What a synthetic element is.
public enum ChartRole: String, Hashable, Sendable, CaseIterable {
    case column
    case segment
    case line
    case marker
    case area
    case wedge
    case point
    case shadow
    case axis
    case tick
    case gridline
    case valueLabel
    case categoryLabel
    case legendSwatch
    case legendLabel
    case dataNumber
}

/// The stable synthetic id of a chart element: `(chartNodeId, series, index, role)`, plus an
/// ordinal among elements sharing the rest (the n-th tick).
public struct ChartElementID: Hashable, Sendable, CustomStringConvertible {
    public var chart: NodeID
    public var series: NodeID?
    public var index: NodeID?
    public var role: ChartRole
    public var ordinal: Int

    public init(chart: NodeID, series: NodeID? = nil, index: NodeID? = nil, role: ChartRole, ordinal: Int = 0) {
        self.chart = chart
        self.series = series
        self.index = index
        self.role = role
        self.ordinal = ordinal
    }

    public var description: String {
        "\(chart)/\(series.map(\.description) ?? "-")/\(index.map(\.description) ?? "-")/\(role.rawValue)#\(ordinal)"
    }
}

/// One laid-out element: its id and its drawing in chart-local space.
public struct ChartElement: Hashable, Sendable {
    public var id: ChartElementID
    public var item: DisplayItem

    public init(id: ChartElementID, item: DisplayItem) {
        self.id = id
        self.item = item
    }
}
