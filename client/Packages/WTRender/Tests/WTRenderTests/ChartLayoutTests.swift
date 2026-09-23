import CoreGraphics
import Foundation
import Testing
import WTGeometry
@testable import WTRender

/// DRAW-032: the chart layout engine.
@Suite struct ChartLayoutTests {
    typealias F = FeatureCorpus

    static func spec(_ type: ChartType, series: Int = 2, options: ChartOptions = ChartOptions(), size: Size = Size(width: 110, height: 70)) -> ChartSpec {
        ChartSpec(chart: F.id(400), type: type, size: size, table: F.table(series: series), options: options, decimalPrecision: 1)
    }

    static func elements(_ spec: ChartSpec) -> [ChartElement] {
        ChartLayout(spec: spec, typesetter: F.labels).elements()
    }

    static func roles(_ elements: [ChartElement], _ role: ChartRole) -> [ChartElement] {
        elements.filter { $0.id.role == role }
    }

    @Test(arguments: ChartType.allCases)
    func everyTypeLaysOutWithUniqueStableIDs(type: ChartType) {
        let spec = Self.spec(type, series: 4, options: ChartOptions(dataNumbers: true, dropShadow: true, gridlinesX: true, gridlinesY: true))
        let first = Self.elements(spec)
        let second = Self.elements(spec)
        #expect(first == second, "deterministic")
        #expect(Set(first.map(\.id)).count == first.count, "ids are unique")
        #expect(first.allSatisfy { $0.id.chart == F.id(400) })
        #expect(!first.isEmpty)
        #expect(first.allSatisfy { $0.item.bounds != nil })
    }

    @Test func groupedColumnsOneBarPerCellGroupedByRow() throws {
        let elements = Self.elements(Self.spec(.groupedColumn))
        let columns = Self.roles(elements, .column)
        #expect(columns.count == 6)
        // Q1 North (4) and Q1 South (7): South is taller, both sit on the baseline.
        let north = try #require(columns.first { $0.id.series == F.id(200) && $0.id.index == F.id(300) }?.item.ownBounds)
        let south = try #require(columns.first { $0.id.series == F.id(201) && $0.id.index == F.id(300) }?.item.ownBounds)
        #expect(south.height > north.height)
        #expect(approx(north.maxY, 70) && approx(south.maxY, 70))
        #expect(north.maxX <= south.minX)
        // Default gray ramp: the first series 90% black.
        guard case .path(let path) = columns[0].item else { return }
        #expect(path.appearance.fills.first?.paint == .solid(Color(white: 1 - 0.9)))
        #expect(ChartLayout.gray(series: 1, of: 2) == Color(white: 1 - 0.45))
        #expect(Self.roles(elements, .categoryLabel).count == 3)
        #expect(Self.roles(elements, .legendLabel).count == 2)
        #expect(Self.roles(elements, .axis).count == 2)
    }

    @Test func stackedColumnsStackPositivesUpAndNegativesDown() throws {
        var table = F.table(series: 2)
        table.values[0] = [4, -3]
        let spec = ChartSpec(chart: F.id(400), type: .stackedColumn, size: Size(width: 90, height: 60), table: table, options: ChartOptions(dataNumbers: true))
        let elements = Self.elements(spec)
        let segments = Self.roles(elements, .segment)
        #expect(segments.count == 6)
        let up = try #require(segments.first { $0.id.series == F.id(200) && $0.id.index == F.id(300) }?.item.ownBounds)
        let down = try #require(segments.first { $0.id.series == F.id(201) && $0.id.index == F.id(300) }?.item.ownBounds)
        #expect(approx(up.maxY, down.minY), "the negative segment hangs from the baseline")
        #expect(Self.roles(elements, .dataNumber).count == 6)
    }

    @Test func linesAndMarkers() {
        let elements = Self.elements(Self.spec(.line, options: ChartOptions(markers: .triangle, dataNumbers: true)))
        #expect(Self.roles(elements, .line).count == 2)
        #expect(Self.roles(elements, .marker).count == 6)
        #expect(Self.roles(elements, .dataNumber).count == 6)
        let none = Self.elements(Self.spec(.line, options: ChartOptions(markers: .none)))
        #expect(Self.roles(none, .marker).isEmpty)
        for marker in ChartMarker.allCases {
            #expect((ChartLayout.marker(marker, at: .zero, size: 4) == nil) == (marker == .none))
        }
    }

    @Test func areasStackBandsOnThePreviousTotals() throws {
        let elements = Self.elements(Self.spec(.area, options: ChartOptions(dataNumbers: true, dropShadow: true)))
        let areas = Self.roles(elements, .area)
        #expect(areas.count == 2)
        #expect(Self.roles(elements, .dataNumber).isEmpty, "no data numbers on areas")
        #expect(Self.roles(elements, .shadow).count == 2)
        let lower = try #require(areas[0].item.ownBounds)
        let upper = try #require(areas[1].item.ownBounds)
        #expect(upper.minY < lower.minY)
        var single = Self.spec(.area)
        single.table = ChartTable(series: single.table.series, categories: [ChartKey(id: F.id(300), label: "")], values: [[3, 4]])
        #expect(!Self.roles(Self.elements(single), .area).isEmpty)
        var empty = Self.spec(.area)
        empty.table = ChartTable(series: empty.table.series, categories: [], values: [])
        #expect(Self.roles(Self.elements(empty), .area).isEmpty)
        #expect(!Self.roles(Self.elements(empty), .axis).isEmpty)
    }

    @Test func scatterPlotsPairsAndNeedsTwoColumns() {
        let elements = Self.elements(Self.spec(.scatter, series: 4, options: ChartOptions(markers: .none, dataNumbers: true, gridlinesY: true)))
        #expect(Self.roles(elements, .point).count == 6, "two pairs × three rows; markers none reads as squares")
        #expect(Self.roles(elements, .legendLabel).count == 2, "one legend entry per pair")
        let short = Self.elements(Self.spec(.scatter, series: 1))
        #expect(Self.roles(short, .point).isEmpty)
        #expect(!Self.roles(short, .axis).isEmpty, "axes are still drawn")
    }

    @Test func piesOnePerRowWithSeparation() throws {
        let elements = Self.elements(Self.spec(.pie, options: ChartOptions(pieSeparation: 20, dataNumbers: true, dropShadow: true)))
        let wedges = Self.roles(elements, .wedge)
        #expect(wedges.count == 6)
        #expect(Self.roles(elements, .axis).isEmpty)
        #expect(Self.roles(elements, .dataNumber).count == 6)
        var zero = Self.spec(.pie)
        zero.table.values[0] = [0, 0]
        zero.table.values[1] = [5, 0]
        let one = Self.elements(zero)
        #expect(Self.roles(one, .wedge).count == 3, "empty rows and zero cells draw no wedge")
        let full = ChartLayout.wedge(center: .zero, radius: 10, from: 0, sweep: 2 * .pi)
        #expect(full.controlBounds.map { approx($0.width, 20, tolerance: 0.5) } == true)
        var empty = Self.spec(.pie)
        empty.table = ChartTable(series: [], categories: [], values: [])
        #expect(Self.roles(Self.elements(empty), .wedge).isEmpty)
    }

    @Test func legendsSitRightOrAcrossTheTop() throws {
        let right = Self.elements(Self.spec(.groupedColumn, options: ChartOptions(axisDisplay: .both)))
        let rightSwatch = try #require(Self.roles(right, .legendSwatch).first?.item.ownBounds)
        #expect(rightSwatch.minX > 110 + 12, "beyond the right axis labels")
        let top = Self.elements(Self.spec(.groupedColumn, options: ChartOptions(legendsAcrossTop: true)))
        let swatches = Self.roles(top, .legendSwatch).compactMap(\.item.ownBounds)
        #expect(swatches.allSatisfy { $0.maxY < 0 })
        #expect(swatches[1].minX > swatches[0].maxX)
        var unlabelled = Self.spec(.groupedColumn)
        unlabelled.table.series = unlabelled.table.series.map { ChartKey(id: $0.id, label: "") }
        #expect(Self.roles(Self.elements(unlabelled), .legendSwatch).isEmpty)
    }

    @Test func axesTicksAndGridlines() {
        let axis = ChartAxis(manual: ChartAxisRange(minimum: 0, maximum: 10, between: 2.5), major: .across, minor: .outside, minorCount: 1, prefix: "$", suffix: "k")
        var spec = Self.spec(.line, options: ChartOptions(axisDisplay: .right, gridlinesX: true))
        spec.yAxis = axis
        spec.xAxis = ChartAxis(major: .inside)
        let elements = Self.elements(spec)
        #expect(Self.roles(elements, .gridline).count == 5)
        #expect(Self.roles(elements, .valueLabel).count == 5)
        #expect(Self.roles(elements, .tick).count == 5 + 4 + 4)
        let none = Self.elements({ var s = spec; s.yAxis = ChartAxis(major: .none); s.xAxis = ChartAxis(major: .none); return s }())
        #expect(Self.roles(none, .tick).isEmpty)
        let layout = ChartLayout(spec: spec, typesetter: F.labels)
        #expect(layout.decimals(for: 2.5) == 1)
        #expect(layout.decimals(for: 2) == 0)
    }

    @Test func scalesPickRoundStepsAndHonourManualRanges() {
        let auto = ChartScale(auto: [3, 47])
        #expect(auto.minimum == 0 && auto.maximum == 50 && auto.step == 10)
        #expect(auto.ticks == [0, 10, 20, 30, 40, 50])
        let negative = ChartScale(auto: [-12, 4])
        #expect(negative.minimum == -15 && negative.maximum == 5 && negative.step == 5)
        let flat = ChartScale(auto: [])
        #expect(flat.minimum == 0 && flat.maximum == 1)
        #expect(ChartScale(auto: [0, 1.5]).step == 0.5)
        #expect(ChartScale(auto: [0, 7]).step == 2)
        #expect(ChartScale(auto: [0, 900]).step == 200)
        let reversed = ChartScale(manual: ChartAxisRange(minimum: 0, maximum: 100, between: -25))!
        #expect(reversed.reversed && reversed.fraction(0) == 1 && reversed.fraction(100) == 0)
        #expect(ChartScale(manual: ChartAxisRange(minimum: 5, maximum: 5, between: 1)) == nil)
        #expect(ChartScale(manual: ChartAxisRange(minimum: 0, maximum: 10, between: 0))?.step == 2)
        #expect(auto.minorTicks(count: 1).first == 5)
        #expect(auto.minorTicks(count: 0).isEmpty)
        #expect(auto.clamped(80) == 50)
    }

    @Test func numbersFormatWithPrecisionAndSeparators() {
        #expect(ChartLayout.format(1234567.891, decimals: 2, thousandsSeparator: true) == "1,234,567.89")
        #expect(ChartLayout.format(-1234.5, decimals: 0, thousandsSeparator: true) == "-1,234")
        #expect(ChartLayout.format(-0.001, decimals: 1, thousandsSeparator: false) == "0.0")
        #expect(ChartLayout.format(999, decimals: 0, thousandsSeparator: true) == "999")
        let layout = ChartLayout(spec: Self.spec(.groupedColumn), typesetter: F.labels)
        #expect(layout.format(2.25) == "2.2" || layout.format(2.25) == "2.3")
    }

    @Test func stylesPictographsAndDegenerateSizes() throws {
        let figure = FeatureCorpus.pictographs
        #expect(figure.count == 1)
        let rect = Rect(x: 0, y: 0, width: 10, height: 35)
        let art: [DisplayItem] = [ReferenceCorpus.path(DisplayPath(rect: Rect(x: 0, y: 0, width: 20, height: 20)), [ReferenceCorpus.fill(.black)])]
        let repeating = try #require(ChartLayout.pictograph(art, in: rect, repeating: true))
        guard case .group(let stack) = repeating else { return }
        #expect(stack.children.count == 4, "three whole copies and a clipped partial")
        #expect(stack.clip != nil)
        let downward = try #require(ChartLayout.pictograph(art, in: rect, repeating: true, upward: false))
        #expect(downward.ownBounds?.minY == 0)
        let stretched = try #require(ChartLayout.pictograph(art, in: rect, repeating: false))
        #expect(stretched.ownBounds.map { approx($0, rect) } == true)
        #expect(ChartLayout.pictograph([], in: rect, repeating: false) == nil)
        // Element styles win over series styles.
        var spec = Self.spec(.groupedColumn)
        spec.seriesStyles[F.id(200)] = ChartStyle(appearance: Appearance([ReferenceCorpus.fill(F.red)]))
        spec.elementStyles[ChartElementKey(series: F.id(200), index: F.id(301))] = ChartStyle(appearance: Appearance([ReferenceCorpus.fill(F.blue)]))
        let columns = Self.roles(Self.elements(spec), .column).filter { $0.id.series == F.id(200) }
        let paints = columns.compactMap { element -> Paint? in
            guard case .path(let path) = element.item else { return nil }
            return path.appearance.fills.first?.paint
        }
        #expect(paints == [.solid(F.red), .solid(F.blue), .solid(F.red)])
        #expect(Self.elements(Self.spec(.groupedColumn, size: Size(width: 0, height: 10))).isEmpty)
        let item = ChartLayout(spec: Self.spec(.pie), typesetter: F.labels).displayItem(transform: .translation(x: 5, y: 5))
        #expect(item.bounds != nil)
        #expect(ChartElementID(chart: F.id(1), role: .axis).description == "1:1/-/-/axis#0")
        #expect(ChartElementID(chart: F.id(1), series: F.id(2), index: F.id(3), role: .column, ordinal: 4).description == "1:1/2:1/3:1/column#4")
        #expect(ChartTable(series: [], categories: [], values: [[.nan]]).value(0, 0) == 0)
    }

    /// Layout of a 100 × 20 table runs under 5 ms (a `PerfBudget`: the perf run holds it).
    @Test func aHundredByTwentyTableLaysOutQuickly() {
        let series = (0..<20).map { ChartKey(id: F.id(2000 + UInt64($0)), label: "S\($0)") }
        let categories = (0..<100).map { ChartKey(id: F.id(3000 + UInt64($0)), label: "C\($0)") }
        let values = (0..<100).map { row in (0..<20).map { Double(($0 * 7 + row * 13) % 50) } }
        let spec = ChartSpec(chart: F.id(400), type: .groupedColumn, size: Size(width: 800, height: 400), table: ChartTable(series: series, categories: categories, values: values))
        let layout = ChartLayout(spec: spec, typesetter: F.labels)
        _ = layout.elements()
        let start = Date()
        let elements = layout.elements()
        let milliseconds = Date().timeIntervalSince(start) * 1000
        print("PERF chart layout: 100 × 20 table, \(elements.count) elements in \(String(format: "%.2f", milliseconds)) ms")
        #expect(Self.roles(elements, .column).count == 2000)
        PerfBudget.expect(.milliseconds(milliseconds), within: .milliseconds(5))
    }
}
