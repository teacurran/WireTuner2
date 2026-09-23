// The chart layout engine (DRAW-032; docs/_includes/drawing/charts.adoc, "Layout engine"): a
// pure function of a `ChartSpec` producing synthetic elements -- axes, ticks, gridlines, value
// and category labels, the legend, series geometry, data numbers, drop shadows and pictograph
// copies -- in chart-local units (the plot area is 0...width × 0...height, y down), each with a
// stable id `(chart, series, index, role)`.  The display list draws them like child nodes; they
// are never in the tree.  Series are drawn in a grayscale ramp: 90% black for the first,
// lightening in equal steps.  Labels are shaped by the `LabelTypesetter`.

import Foundation
import WTGeometry

public struct ChartLayout: Sendable {
    public let spec: ChartSpec
    public let typesetter: LabelTypesetter

    /// Length of a major tick, local units; minor ticks are half.
    public static let tickLength = 4.0
    /// Gap between an axis and its labels.
    public static let labelGap = 6.0
    /// How far the drop shadow sits behind and to the right.
    public static let shadowOffset = 3.0
    /// Legend swatch edge.
    public static let swatchSize = 8.0
    /// Default outline width of bars, wedges, bands and markers.
    public static let outlineWidth = 0.5

    /// Each series' default filled and line appearances, built once.
    let filledAppearances: [Appearance]
    let lineAppearances: [Appearance]

    public init(spec: ChartSpec, typesetter: LabelTypesetter = CoreTextLabels()) {
        self.spec = spec
        self.typesetter = typesetter
        let count = spec.table.series.count
        let outline = StrokePaint(paint: .solid(.black), style: StrokeStyle(width: ChartLayout.outlineWidth))
        filledAppearances = (0..<count).map { Appearance([.fill(FillPaint(paint: .solid(ChartLayout.gray(series: $0, of: count)))), .stroke(outline)]) }
        lineAppearances = (0..<count).map { Appearance([.stroke(StrokePaint(paint: .solid(ChartLayout.gray(series: $0, of: count)), style: StrokeStyle(width: 1, join: .round)))]) }
    }

    /// The series gray: 90% black for the first of `count`, lightening in equal steps.
    public static func gray(series index: Int, of count: Int) -> Color {
        let n = max(count, 1)
        return Color(white: 1 - 0.9 * Double(n - min(max(index, 0), n - 1)) / Double(n))
    }

    /// The chart as one group placed by `transform` (chart-local → pasteboard).
    public func displayItem(transform: AffineTransform = .identity) -> DisplayItem {
        .group(GroupItem(children: elements().map { $0.item.transformed(by: transform) }))
    }

    /// Every element, back to front: shadows, gridlines, series geometry, axes and ticks,
    /// labels and legend, data numbers.
    public func elements() -> [ChartElement] {
        guard spec.size.width > 0, spec.size.height > 0 else {
            return []
        }
        var output = Output(chart: spec.chart)
        switch spec.type {
        case .groupedColumn, .stackedColumn:
            layoutColumns(into: &output)
        case .line:
            layoutLine(into: &output)
        case .area:
            layoutArea(into: &output)
        case .scatter:
            layoutScatter(into: &output)
        case .pie:
            layoutPies(into: &output)
        }
        layoutLegend(into: &output)
        return output.shadows + output.grid + output.series + output.axes + output.labels + output.numbers
    }

    // MARK: Output

    struct Output {
        let chart: NodeID
        var shadows: [ChartElement] = []
        var grid: [ChartElement] = []
        var series: [ChartElement] = []
        var axes: [ChartElement] = []
        var labels: [ChartElement] = []
        var numbers: [ChartElement] = []

        func id(_ role: ChartRole, series: NodeID? = nil, index: NodeID? = nil, ordinal: Int = 0) -> ChartElementID {
            ChartElementID(chart: chart, series: series, index: index, role: role, ordinal: ordinal)
        }
    }

    // MARK: Styles

    var seriesCount: Int { spec.table.series.count }
    var categoryCount: Int { spec.table.categories.count }

    /// The style for series `s` at category `c`: the element's, else the series', else none.
    func style(series s: Int, category c: Int?) -> ChartStyle? {
        guard !spec.seriesStyles.isEmpty || !spec.elementStyles.isEmpty else {
            return nil
        }
        let series = spec.table.series[s].id
        if let c, let element = spec.elementStyles[ChartElementKey(series: series, index: spec.table.categories[c].id)] {
            return element
        }
        return spec.seriesStyles[series]
    }

    /// A filled, outlined shape in series `s`'s gray, or its style's appearance, with its
    /// style's transform about the shape's centre.
    func shape(_ path: DisplayPath, series s: Int, category c: Int?, filled: Bool = true) -> DisplayItem {
        let style = style(series: s, category: c)
        let appearance = style?.appearance ?? (filled ? filledAppearances[s] : lineAppearances[s])
        return .path(PathItem(path: path, appearance: appearance, transform: extraTransform(style, about: path.controlBounds)))
    }

    func extraTransform(_ style: ChartStyle?, about bounds: @autoclosure () -> Rect?) -> AffineTransform {
        guard let transform = style?.transform, let bounds = bounds() else {
            return .identity
        }
        return AffineTransform.translation(x: -bounds.midX, y: -bounds.midY).concatenating(transform).concatenating(.translation(x: bounds.midX, y: bounds.midY))
    }

    static func line(_ from: Point, _ to: Point, width: Double = ChartLayout.outlineWidth, color: Color = .black) -> DisplayItem {
        .path(PathItem(path: DisplayPath(polygon: [from, to], closed: false), appearance: Appearance([.stroke(StrokePaint(paint: .solid(color), style: StrokeStyle(width: width)))])))
    }

    func label(_ text: String, at anchor: Point, alignment: LabelAlignment) -> DisplayItem? {
        let items = typesetter.label(text, at: anchor, alignment: alignment, color: .black)
        guard !items.isEmpty else {
            return nil
        }
        return items.count == 1 ? items[0] : .group(GroupItem(children: items))
    }

    /// A label whose line is vertically centred on `y`.
    func centeredBaseline(_ y: Double) -> Double {
        y - typesetter.lineHeight / 2 + typesetter.ascent
    }

    // MARK: Numbers

    /// `value` with the chart's decimal precision and thousands separator.
    public func format(_ value: Double, decimals: Int? = nil) -> String {
        ChartLayout.format(value, decimals: decimals ?? spec.decimalPrecision, thousandsSeparator: spec.thousandsSeparator)
    }

    static func format(_ value: Double, decimals: Int, thousandsSeparator: Bool) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.hasPrefix("-"), Double(text) == 0 {
            text.removeFirst()
        }
        guard thousandsSeparator else {
            return text
        }
        let negative = text.hasPrefix("-")
        let unsigned = negative ? String(text.dropFirst()) : text
        let parts = unsigned.split(separator: ".", maxSplits: 1).map(String.init)
        var integer = Array(parts[0])
        var grouped: [Character] = []
        while integer.count > 3 {
            grouped = [","] + integer.suffix(3) + grouped
            integer.removeLast(3)
        }
        grouped = integer + grouped
        return (negative ? "-" : "") + String(grouped) + (parts.count > 1 ? "." + parts[1] : "")
    }

    /// The decimals an axis label needs to show `step` (at most the chart's precision).
    func decimals(for step: Double) -> Int {
        var decimals = 0
        var scaled = abs(step)
        while decimals < spec.decimalPrecision, abs(scaled - scaled.rounded()) > 1e-9 {
            scaled *= 10
            decimals += 1
        }
        return decimals
    }

    // MARK: Value axis

    /// The value axis over `values` (the axis options' range when manual).
    func valueScale(_ values: [Double], axis: ChartAxis) -> ChartScale {
        if let manual = axis.manual, let scale = ChartScale(manual: manual) {
            return scale
        }
        return ChartScale(auto: values)
    }

    func y(_ value: Double, _ scale: ChartScale) -> Double {
        spec.size.height * (1 - scale.fraction(value))
    }

    /// The value axis lines, ticks, labels and horizontal gridlines at `scale`.
    func layoutValueAxis(_ scale: ChartScale, into output: inout Output) {
        let width = spec.size.width
        let sides: [(x: Double, direction: Double, ordinal: Int)]
        switch spec.options.axisDisplay {
        case .left: sides = [(0, -1, 0)]
        case .right: sides = [(width, 1, 1)]
        case .both: sides = [(0, -1, 0), (width, 1, 1)]
        }
        let axis = spec.yAxis
        let decimals = decimals(for: scale.step)
        for side in sides {
            output.axes.append(ChartElement(id: output.id(.axis, ordinal: side.ordinal), item: ChartLayout.line(Point(x: side.x, y: 0), Point(x: side.x, y: spec.size.height))))
            for (ordinal, value) in scale.ticks.enumerated() {
                let y = y(value, scale)
                if let tick = tick(at: Point(x: side.x, y: y), outward: Vector(side.direction, 0), style: axis.major, length: ChartLayout.tickLength) {
                    output.axes.append(ChartElement(id: output.id(.tick, ordinal: side.ordinal * 100_000 + ordinal), item: tick))
                }
                let text = axis.prefix + format(value, decimals: decimals) + axis.suffix
                let anchor = Point(x: side.x + side.direction * ChartLayout.labelGap, y: centeredBaseline(y))
                if let item = label(text, at: anchor, alignment: side.direction < 0 ? .trailing : .leading) {
                    output.labels.append(ChartElement(id: output.id(.valueLabel, ordinal: side.ordinal * 100_000 + ordinal), item: item))
                }
            }
            for (ordinal, value) in scale.minorTicks(count: axis.minorCount).enumerated() {
                if let tick = tick(at: Point(x: side.x, y: y(value, scale)), outward: Vector(side.direction, 0), style: axis.minor, length: ChartLayout.tickLength / 2) {
                    output.axes.append(ChartElement(id: output.id(.tick, ordinal: 50_000 + side.ordinal * 100_000 + ordinal), item: tick))
                }
            }
        }
        if spec.options.gridlinesX {
            for (ordinal, value) in scale.ticks.enumerated() {
                let y = y(value, scale)
                output.grid.append(ChartElement(id: output.id(.gridline, ordinal: ordinal), item: ChartLayout.line(Point(x: 0, y: y), Point(x: width, y: y), color: Color(white: 0.6))))
            }
        }
    }

    /// A tick at `point` perpendicular to its axis, `outward` pointing away from the plot.
    func tick(at point: Point, outward: Vector, style: ChartTickStyle, length: Double) -> DisplayItem? {
        let out = point + outward * length
        let inward = point - outward * length
        switch style {
        case .none: return nil
        case .outside: return ChartLayout.line(point, out)
        case .inside: return ChartLayout.line(point, inward)
        case .across: return ChartLayout.line(inward, out)
        }
    }

    // MARK: Category axis

    /// The bottom axis at the value 0 (clamped into the plot), category ticks at the slot
    /// boundaries, vertical gridlines there, and the category labels under each slot.
    func layoutCategoryAxis(baseline: Double, into output: inout Output) {
        let width = spec.size.width
        let n = categoryCount
        output.axes.append(ChartElement(id: output.id(.axis, ordinal: 2), item: ChartLayout.line(Point(x: 0, y: baseline), Point(x: width, y: baseline))))
        guard n > 0 else { return }
        let slot = width / Double(n)
        for boundary in 0...n {
            let x = Double(boundary) * slot
            if let tick = tick(at: Point(x: x, y: baseline), outward: Vector(0, 1), style: spec.xAxis.major, length: ChartLayout.tickLength) {
                output.axes.append(ChartElement(id: output.id(.tick, ordinal: 200_000 + boundary), item: tick))
            }
            if spec.options.gridlinesY, boundary > 0, boundary < n {
                output.grid.append(ChartElement(id: output.id(.gridline, ordinal: 100_000 + boundary), item: ChartLayout.line(Point(x: x, y: 0), Point(x: x, y: spec.size.height), color: Color(white: 0.6))))
            }
        }
        layoutCategoryLabels(centers: (0..<n).map { (Double($0) + 0.5) * slot }, into: &output)
    }

    func layoutCategoryLabels(centers: [Double], into output: inout Output) {
        let baseline = spec.size.height + ChartLayout.labelGap + typesetter.ascent
        for (index, center) in centers.enumerated() where index < categoryCount {
            let category = spec.table.categories[index]
            if let item = label(category.label, at: Point(x: center, y: baseline), alignment: .center) {
                output.labels.append(ChartElement(id: output.id(.categoryLabel, index: category.id), item: item))
            }
        }
    }

    // MARK: Columns

    func layoutColumns(into output: inout Output) {
        let n = categoryCount, m = seriesCount
        let stacked = spec.type == .stackedColumn
        var extent: [Double] = [0]
        for c in 0..<n {
            if stacked {
                extent.append((0..<m).map { max(spec.table.value(c, $0), 0) }.reduce(0, +))
                extent.append((0..<m).map { min(spec.table.value(c, $0), 0) }.reduce(0, +))
            } else {
                extent += (0..<m).map { spec.table.value(c, $0) }
            }
        }
        let scale = valueScale(extent, axis: spec.yAxis)
        let baseline = y(scale.clamped(0), scale)
        layoutValueAxis(scale, into: &output)
        layoutCategoryAxis(baseline: baseline, into: &output)
        guard n > 0, m > 0 else { return }
        let slot = spec.size.width / Double(n)
        for c in 0..<n {
            let start = Double(c) * slot
            if stacked {
                let barWidth = slot * spec.options.columnWidth / 100
                let x = start + (slot - barWidth) / 2
                var above = 0.0, below = 0.0
                for s in 0..<m {
                    let value = spec.table.value(c, s)
                    let from = value >= 0 ? above : below
                    let to = from + value
                    if value >= 0 { above = to } else { below = to }
                    addColumn(x: x, width: barWidth, from: y(scale.clamped(from), scale), to: y(scale.clamped(to), scale), value: value, series: s, category: c, role: .segment, into: &output)
                }
            } else {
                let cluster = slot * spec.options.clusterWidth / 100
                let lane = cluster / Double(m)
                let barWidth = lane * spec.options.columnWidth / 100
                for s in 0..<m {
                    let x = start + (slot - cluster) / 2 + Double(s) * lane + (lane - barWidth) / 2
                    let value = spec.table.value(c, s)
                    addColumn(x: x, width: barWidth, from: baseline, to: y(scale.clamped(value), scale), value: value, series: s, category: c, role: .column, into: &output)
                }
            }
        }
    }

    /// One column (or stacked segment) between `from` and `to` (y), its shadow, pictograph and
    /// data number.
    func addColumn(x: Double, width: Double, from: Double, to: Double, value: Double, series s: Int, category c: Int, role: ChartRole, into output: inout Output) {
        let seriesID = spec.table.series[s].id
        let categoryID = spec.table.categories[c].id
        let rect = Rect(x: x, y: min(from, to), width: width, height: abs(to - from))
        let style = style(series: s, category: c)
        if spec.options.dropShadow {
            // Offset behind and to the right, but not past the baseline the column stands on.
            let offset = ChartLayout.shadowOffset
            let upward = to <= from
            let cast = upward
                ? Rect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height - offset, 0))
                : Rect(x: rect.minX, y: rect.minY - offset, width: rect.width, height: rect.height + offset)
            output.shadows.append(ChartElement(id: output.id(.shadow, series: seriesID, index: categoryID), item: shadow(DisplayPath(rect: cast))))
        }
        let item: DisplayItem
        if let pictograph = style?.pictograph, let artwork = ChartLayout.pictograph(pictograph, in: rect, repeating: style?.repeating ?? false, upward: to <= from) {
            item = artwork.transformed(by: extraTransform(style, about: rect))
        } else {
            item = shape(DisplayPath(rect: rect), series: s, category: c)
        }
        output.series.append(ChartElement(id: output.id(role, series: seriesID, index: categoryID), item: item))
        if spec.options.dataNumbers {
            let anchor = role == .segment
                ? Point(x: rect.midX, y: centeredBaseline(rect.midY))
                : Point(x: rect.midX, y: (to <= from ? rect.minY - ChartLayout.labelGap / 2 : rect.maxY + ChartLayout.labelGap / 2 + typesetter.ascent))
            if let number = label(format(value), at: anchor, alignment: .center) {
                output.numbers.append(ChartElement(id: output.id(.dataNumber, series: seriesID, index: categoryID), item: number))
            }
        }
    }

    /// A shape's drop shadow: its outline filled 50% gray, offset behind and to the right.
    func shadow(_ path: DisplayPath) -> DisplayItem {
        .path(PathItem(
            path: path,
            appearance: Appearance([.fill(FillPaint(paint: .solid(Color(white: 0.5))))]),
            transform: .translation(x: ChartLayout.shadowOffset, y: ChartLayout.shadowOffset)
        ))
    }

    /// `artwork` fitted to the column `rect`: stretched, or with `repeating` stacked in copies
    /// scaled to the column's width from its base (the bottom when `upward`), the last copy
    /// clipped.  Nil when the artwork has no area.
    public static func pictograph(_ artwork: [DisplayItem], in rect: Rect, repeating: Bool, upward: Bool = true) -> DisplayItem? {
        guard let source = DisplayList.union(of: artwork.compactMap(\.geometricBounds)), source.width > 0, source.height > 0, rect.width > 0 else {
            return nil
        }
        func placed(_ transform: AffineTransform) -> [DisplayItem] {
            artwork.map { $0.transformed(by: AffineTransform.translation(x: -source.minX, y: -source.minY).concatenating(transform)) }
        }
        guard repeating else {
            let scale = AffineTransform.scale(x: rect.width / source.width, y: rect.height / source.height)
            return .group(GroupItem(children: placed(scale.concatenating(.translation(x: rect.minX, y: rect.minY)))))
        }
        let factor = rect.width / source.width
        let copyHeight = source.height * factor
        let count = Int((rect.height / copyHeight).rounded(.up))
        var children: [DisplayItem] = []
        for copy in 0..<max(count, 0) {
            let top = upward ? rect.maxY - Double(copy + 1) * copyHeight : rect.minY + Double(copy) * copyHeight
            children += placed(AffineTransform.scale(factor).concatenating(.translation(x: rect.minX, y: top)))
        }
        return .group(GroupItem(children: children, clip: DisplayPath(rect: rect)))
    }

    // MARK: Line and area

    func layoutLine(into output: inout Output) {
        let n = categoryCount, m = seriesCount
        let scale = valueScale((0..<n).flatMap { c in (0..<m).map { spec.table.value(c, $0) } }, axis: spec.yAxis)
        layoutValueAxis(scale, into: &output)
        layoutCategoryAxis(baseline: y(scale.clamped(0), scale), into: &output)
        guard n > 0 else { return }
        let slot = spec.size.width / Double(n)
        for s in 0..<m {
            let seriesID = spec.table.series[s].id
            let points = (0..<n).map { Point(x: (Double($0) + 0.5) * slot, y: y(scale.clamped(spec.table.value($0, s)), scale)) }
            output.series.append(ChartElement(id: output.id(.line, series: seriesID), item: shape(DisplayPath(polygon: points, closed: false), series: s, category: nil, filled: false)))
            for (c, point) in points.enumerated() {
                addMarker(at: point, series: s, category: c, role: .marker, into: &output)
                addPointNumber(spec.table.value(c, s), at: point, series: s, category: c, into: &output)
            }
        }
    }

    func addMarker(at point: Point, series s: Int, category c: Int, role: ChartRole, marker: ChartMarker? = nil, into output: inout Output) {
        guard let path = ChartLayout.marker(marker ?? spec.options.markers, at: point, size: 5) else {
            return
        }
        output.series.append(ChartElement(id: output.id(role, series: spec.table.series[s].id, index: spec.table.categories[c].id), item: shape(path, series: s, category: c)))
    }

    func addPointNumber(_ value: Double, at point: Point, series s: Int, category c: Int, into output: inout Output) {
        guard spec.options.dataNumbers, let number = label(format(value), at: Point(x: point.x, y: point.y - ChartLayout.labelGap), alignment: .center) else {
            return
        }
        output.numbers.append(ChartElement(id: output.id(.dataNumber, series: spec.table.series[s].id, index: spec.table.categories[c].id), item: number))
    }

    /// A data marker of edge `size` centred on `point`; nil for none.
    public static func marker(_ marker: ChartMarker, at point: Point, size: Double) -> DisplayPath? {
        let h = size / 2
        switch marker {
        case .none:
            return nil
        case .square:
            return DisplayPath(rect: Rect(x: point.x - h, y: point.y - h, width: size, height: size))
        case .diamond:
            return DisplayPath(polygon: [Point(x: point.x, y: point.y - h), Point(x: point.x + h, y: point.y), Point(x: point.x, y: point.y + h), Point(x: point.x - h, y: point.y)])
        case .triangle:
            return DisplayPath(polygon: [Point(x: point.x, y: point.y - h), Point(x: point.x + h, y: point.y + h), Point(x: point.x - h, y: point.y + h)])
        case .circle:
            return DisplayPath(ellipseIn: Rect(x: point.x - h, y: point.y - h, width: size, height: size))
        }
    }

    func layoutArea(into output: inout Output) {
        let n = categoryCount, m = seriesCount
        var totals = [Double](repeating: 0, count: n)
        var extent: [Double] = [0]
        for c in 0..<n {
            totals[c] = (0..<m).map { spec.table.value(c, $0) }.reduce(0, +)
            var running = 0.0
            for s in 0..<m {
                running += spec.table.value(c, s)
                extent.append(running)
            }
        }
        let scale = valueScale(extent, axis: spec.yAxis)
        layoutValueAxis(scale, into: &output)
        guard n > 0 else {
            layoutCategoryAxis(baseline: y(scale.clamped(0), scale), into: &output)
            return
        }
        let xs = (0..<n).map { n > 1 ? Double($0) * spec.size.width / Double(n - 1) : spec.size.width / 2 }
        output.axes.append(ChartElement(id: output.id(.axis, ordinal: 2), item: ChartLayout.line(Point(x: 0, y: y(scale.clamped(0), scale)), Point(x: spec.size.width, y: y(scale.clamped(0), scale)))))
        layoutCategoryLabels(centers: xs, into: &output)
        var lower = [Double](repeating: 0, count: n)
        for s in 0..<m {
            let upper = (0..<n).map { lower[$0] + spec.table.value($0, s) }
            let top = (0..<n).map { Point(x: xs[$0], y: y(scale.clamped(upper[$0]), scale)) }
            let bottom = (0..<n).reversed().map { Point(x: xs[$0], y: y(scale.clamped(lower[$0]), scale)) }
            let band = DisplayPath(polygon: top + bottom)
            let seriesID = spec.table.series[s].id
            if spec.options.dropShadow {
                output.shadows.append(ChartElement(id: output.id(.shadow, series: seriesID), item: shadow(band)))
            }
            output.series.append(ChartElement(id: output.id(.area, series: seriesID), item: shape(band, series: s, category: nil)))
            lower = upper
        }
    }

    // MARK: Scatter

    /// One point per row per pair of columns: x from the first, y from the second.
    func layoutScatter(into output: inout Output) {
        let n = categoryCount, pairs = seriesCount / 2
        var xs: [Double] = [], ys: [Double] = []
        for c in 0..<n {
            for pair in 0..<pairs {
                xs.append(spec.table.value(c, 2 * pair))
                ys.append(spec.table.value(c, 2 * pair + 1))
            }
        }
        let yScale = valueScale(ys, axis: spec.yAxis)
        let xScale = valueScale(xs, axis: spec.xAxis)
        layoutValueAxis(yScale, into: &output)
        let baseline = y(yScale.clamped(0), yScale)
        output.axes.append(ChartElement(id: output.id(.axis, ordinal: 2), item: ChartLayout.line(Point(x: 0, y: baseline), Point(x: spec.size.width, y: baseline))))
        let decimals = decimals(for: xScale.step)
        let labelBaseline = spec.size.height + ChartLayout.labelGap + typesetter.ascent
        for (ordinal, value) in xScale.ticks.enumerated() {
            let x = spec.size.width * xScale.fraction(value)
            if let tick = tick(at: Point(x: x, y: baseline), outward: Vector(0, 1), style: spec.xAxis.major, length: ChartLayout.tickLength) {
                output.axes.append(ChartElement(id: output.id(.tick, ordinal: 200_000 + ordinal), item: tick))
            }
            if let item = label(spec.xAxis.prefix + format(value, decimals: decimals) + spec.xAxis.suffix, at: Point(x: x, y: labelBaseline), alignment: .center) {
                output.labels.append(ChartElement(id: output.id(.valueLabel, ordinal: 200_000 + ordinal), item: item))
            }
            if spec.options.gridlinesY {
                output.grid.append(ChartElement(id: output.id(.gridline, ordinal: 100_000 + ordinal), item: ChartLayout.line(Point(x: x, y: 0), Point(x: x, y: spec.size.height), color: Color(white: 0.6))))
            }
        }
        for pair in 0..<pairs {
            for c in 0..<n {
                let point = Point(x: spec.size.width * xScale.fraction(xScale.clamped(spec.table.value(c, 2 * pair))), y: y(yScale.clamped(spec.table.value(c, 2 * pair + 1)), yScale))
                let marker = spec.options.markers == .none ? ChartMarker.square : spec.options.markers
                addMarker(at: point, series: 2 * pair, category: c, role: .point, marker: marker, into: &output)
                addPointNumber(spec.table.value(c, 2 * pair + 1), at: point, series: 2 * pair, category: c, into: &output)
            }
        }
    }

    // MARK: Pie

    /// One pie per category, one wedge per series, clockwise from twelve o'clock.
    func layoutPies(into output: inout Output) {
        let n = categoryCount, m = seriesCount
        guard n > 0, m > 0 else { return }
        let slot = spec.size.width / Double(n)
        let separation = min(max(spec.options.pieSeparation, 0), 50) / 100
        let outer = min(slot, spec.size.height) / 2
        let radius = outer / (1 + separation)
        var centers: [Double] = []
        for c in 0..<n {
            let center = Point(x: (Double(c) + 0.5) * slot, y: spec.size.height / 2)
            centers.append(center.x)
            let total = (0..<m).map { abs(spec.table.value(c, $0)) }.reduce(0, +)
            guard total > 0 else { continue }
            var angle = -Double.pi / 2
            for s in 0..<m {
                let sweep = 2 * Double.pi * abs(spec.table.value(c, s)) / total
                guard sweep > 0 else { continue }
                let middle = angle + sweep / 2
                let offset = Vector(cos(middle), sin(middle)) * (radius * separation)
                let wedge = ChartLayout.wedge(center: center + offset, radius: radius, from: angle, sweep: sweep)
                let seriesID = spec.table.series[s].id, categoryID = spec.table.categories[c].id
                if spec.options.dropShadow {
                    output.shadows.append(ChartElement(id: output.id(.shadow, series: seriesID, index: categoryID), item: shadow(wedge)))
                }
                output.series.append(ChartElement(id: output.id(.wedge, series: seriesID, index: categoryID), item: shape(wedge, series: s, category: c)))
                if spec.options.dataNumbers {
                    let at = center + offset + Vector(cos(middle), sin(middle)) * (radius * 0.6)
                    if let number = label(format(spec.table.value(c, s)), at: Point(x: at.x, y: centeredBaseline(at.y)), alignment: .center) {
                        output.numbers.append(ChartElement(id: output.id(.dataNumber, series: seriesID, index: categoryID), item: number))
                    }
                }
                angle += sweep
            }
        }
        layoutCategoryLabels(centers: centers, into: &output)
    }

    /// A pie wedge: the centre, then the arc from `start` through `sweep` radians (clockwise on
    /// a y-down page), in cubic segments of at most 90°.
    public static func wedge(center: Point, radius: Double, from start: Double, sweep: Double) -> DisplayPath {
        var path = DisplayPath()
        let full = sweep >= 2 * Double.pi - 1e-9
        func point(_ angle: Double) -> Point { center + Vector(cos(angle), sin(angle)) * radius }
        if full {
            path.move(to: point(start))
        } else {
            path.move(to: center)
            path.addLine(to: point(start))
        }
        let segments = max(Int((sweep / (Double.pi / 2)).rounded(.up)), 1)
        let step = sweep / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4) * radius
        for index in 0..<segments {
            let a0 = start + Double(index) * step, a1 = a0 + step
            let p0 = point(a0), p1 = point(a1)
            path.addCubicCurve(
                control1: p0 + Vector(-sin(a0), cos(a0)) * k,
                control2: p1 - Vector(-sin(a1), cos(a1)) * k,
                to: p1
            )
        }
        path.close()
        return path
    }

    // MARK: Legend

    /// One swatch and name per series: at the right of the plot (beyond a right value axis's
    /// labels), or across the top.  Scatter names every pair by its y column; pies name wedges.
    func layoutLegend(into output: inout Output) {
        let step = spec.type == .scatter ? 2 : 1
        let entries = stride(from: 0, to: seriesCount, by: step).filter { !spec.table.series[$0].label.isEmpty }
        guard !entries.isEmpty else { return }
        let rowHeight = max(typesetter.lineHeight, ChartLayout.swatchSize) + 4
        var x: Double
        var y: Double
        if spec.options.legendsAcrossTop {
            x = 0
            y = -rowHeight - ChartLayout.labelGap
        } else {
            let rightLabels = spec.type != .pie && spec.options.axisDisplay != .left
            x = spec.size.width + 12 + (rightLabels ? output.labels.filter { $0.id.role == .valueLabel && $0.id.ordinal >= 100_000 && $0.id.ordinal < 200_000 }.compactMap { $0.item.bounds?.width }.max() ?? 0 : 0)
            y = 0
        }
        for s in entries {
            let key = spec.table.series[s]
            let swatch = DisplayPath(rect: Rect(x: x, y: y + (rowHeight - ChartLayout.swatchSize) / 2, width: ChartLayout.swatchSize, height: ChartLayout.swatchSize))
            output.labels.append(ChartElement(id: output.id(.legendSwatch, series: key.id), item: shape(swatch, series: s, category: nil)))
            let anchor = Point(x: x + ChartLayout.swatchSize + 4, y: y + rowHeight / 2 - typesetter.lineHeight / 2 + typesetter.ascent)
            if let item = label(key.label, at: anchor, alignment: .leading) {
                output.labels.append(ChartElement(id: output.id(.legendLabel, series: key.id), item: item))
            }
            if spec.options.legendsAcrossTop {
                x += ChartLayout.swatchSize + 4 + typesetter.width(of: key.label) + 12
            } else {
                y += rowHeight
            }
        }
    }
}

/// A value axis: its range, step and direction.
public struct ChartScale: Hashable, Sendable {
    public var minimum: Double
    public var maximum: Double
    public var step: Double
    /// A negative *Between*: the axis runs from high to low.
    public var reversed: Bool

    /// A range over `values` and 0 on round steps (1, 2 or 5 × 10ⁿ, about five intervals).
    public init(auto values: [Double]) {
        var low = min(values.filter(\.isFinite).min() ?? 0, 0)
        var high = max(values.filter(\.isFinite).max() ?? 0, 0)
        if high - low <= 0 {
            high = low + 1
        }
        let raw = (high - low) / 5
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let normalized = raw / magnitude
        let nice: Double = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
        step = nice * magnitude
        low = (low / step).rounded(.down) * step
        high = (high / step).rounded(.up) * step
        minimum = low
        maximum = high
        reversed = false
    }

    /// The hand-set range; nil when it is empty or not finite (the axis then calculates).
    public init?(manual: ChartAxisRange) {
        guard manual.minimum.isFinite, manual.maximum.isFinite, manual.between.isFinite, manual.maximum > manual.minimum else {
            return nil
        }
        minimum = manual.minimum
        maximum = manual.maximum
        let between = abs(manual.between)
        step = between > 0 ? between : (manual.maximum - manual.minimum) / 5
        reversed = manual.between < 0
    }

    /// Where `value` sits, 0 at the bottom (left) and 1 at the top (right).
    public func fraction(_ value: Double) -> Double {
        let t = (value - minimum) / (maximum - minimum)
        return reversed ? 1 - t : t
    }

    /// `value` clamped into the range.
    public func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    /// The labelled values, minimum first (at most 1,000).
    public var ticks: [Double] {
        var result: [Double] = []
        var value = minimum
        while value <= maximum + step * 1e-9, result.count < 1000 {
            result.append(abs(value) < step * 1e-9 ? 0 : value)
            value = minimum + Double(result.count) * step
        }
        return result
    }

    /// `count` values evenly between each pair of labelled values.
    public func minorTicks(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        let majors = ticks
        return zip(majors, majors.dropFirst()).flatMap { low, high in
            (1...count).map { low + (high - low) * Double($0) / Double(count + 1) }
        }
    }
}
