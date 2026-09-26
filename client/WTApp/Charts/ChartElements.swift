import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Chart elements picked for styling (charts.adoc, "Styling chart elements"; DRAW-034): the
/// Subselect tool's click on a bar, line, wedge, marker, area or legend swatch picks that element
/// (kbd:[Shift] adds), menu:Edit[Select > Superselect] (kbd:[~]) widens each pick to its whole
/// series.  The window's selection holds the chart; the picks are this window's own state -- the
/// synthetic ids are not in the APP-006 selection nor in presence (deviation), so a collaborator
/// sees the chart selected.  Colour from the Swatches panel and the Object panel's *Chart
/// Element* section write overrides for the picks (`SetChartOverride`).
@MainActor
final class ChartElementPicks {
    /// The chart and its picked keys (a key without an index: the whole series).
    private(set) var chart: OpID?
    private(set) var keys: [ChartElementKeyRef] = []
    /// Redraws the canvas when the picks change.
    var onChange: @MainActor () -> Void = {}

    private static var byDocument: [String: ChartElementPicks] = [:]

    /// The picks of `document` (one per open document).
    static func of(_ document: DocumentHandle) -> ChartElementPicks {
        if let existing = byDocument[document.id] { return existing }
        let made = ChartElementPicks()
        byDocument[document.id] = made
        return made
    }

    var isEmpty: Bool { chart == nil || keys.isEmpty }

    func pick(_ key: ChartElementKeyRef, in chart: OpID, adding: Bool) {
        if adding, self.chart == chart {
            if let index = keys.firstIndex(of: key) { keys.remove(at: index) } else { keys.append(key) }
        } else {
            self.chart = chart
            keys = [key]
        }
        onChange()
    }

    func clear() {
        guard chart != nil else { return }
        chart = nil
        keys = []
        onChange()
    }

    /// Superselect: every pick becomes its series; false when there was nothing to widen.
    @discardableResult
    func superselect() -> Bool {
        guard !isEmpty, keys.contains(where: { $0.index != nil }) else { return false }
        var widened: [ChartElementKeyRef] = []
        for key in keys.map({ ChartElementKeyRef(series: $0.series) }) where !widened.contains(key) { widened.append(key) }
        keys = widened
        onChange()
        return true
    }
}

/// Where a chart's elements are drawn, for hit testing and highlights.
@MainActor
enum ChartElementHits {
    /// The chart's elements in chart-local space and its local → pasteboard transform.
    static func layout(_ chart: OpID, in state: EngineState) -> (elements: [ChartElement], transform: WTGeometry.AffineTransform)? {
        guard state.isLive(chart), case .chart(let props)? = state.props(chart).kind, let spec = Chart(props).spec(node: chart) else { return nil }
        return (ChartLayout(spec: spec).elements(), Objects.pasteboardTransform(of: chart, in: state))
    }

    /// The roles a pick can land on: the series' drawing and its legend swatch.
    static let pickable: Set<ChartRole> = [.column, .segment, .line, .marker, .area, .wedge, .point, .legendSwatch]

    /// The key of the element under `point` (pasteboard) in `chart`: the topmost pickable
    /// element whose painted bounds hold it; a legend swatch or a line picks the series.
    static func key(at point: Point, in chart: OpID, state: EngineState, slop: Double = 2) -> ChartElementKeyRef? {
        guard let (elements, transform) = layout(chart, in: state), let local = transform.inverted()?.apply(point) else { return nil }
        for element in elements.reversed() where pickable.contains(element.id.role) {
            guard let series = element.id.series, let bounds = element.item.bounds, bounds.expanded(by: slop).contains(local) else { continue }
            let wholeSeries = element.id.role == .legendSwatch || element.id.role == .line || element.id.role == .area
            return ChartElementKeyRef(series: OpID(series), index: wholeSeries ? nil : element.id.index.map { OpID($0) })
        }
        return nil
    }

    /// The pasteboard outlines of the elements `key` covers.
    static func outlines(_ key: ChartElementKeyRef, in chart: OpID, state: EngineState) -> [Rect] {
        guard let (elements, transform) = layout(chart, in: state) else { return [] }
        return elements.filter { element in
            guard pickable.contains(element.id.role), element.id.role != .legendSwatch, element.id.series == NodeID(key.series) else { return false }
            return key.index == nil || element.id.index == NodeID(key.index!)
        }.compactMap { $0.item.bounds.map { $0.applying(transform) } }
    }

    /// The chart under `point` (pasteboard): the topmost live chart whose bounds hold it.
    static func chart(at point: Point, document: DocumentHandle) -> OpID? {
        document.scene.objects.values.filter { $0.kind == .chart && !$0.isEffectivelyLocked && ($0.bounds?.contains(point) ?? false) }
            .max { $0.itemPath.lexicographicallyPrecedes($1.itemPath) }?.id
    }
}

/// The Subselect tool's clicks on chart elements and their highlights (a handle layer: it takes
/// the press before the tool).
@MainActor
final class ChartElementHandles: CanvasHandleLayer {
    let isSubselect: @MainActor () -> Bool

    init(isSubselect: @escaping @MainActor () -> Bool) {
        self.isSubselect = isSubselect
    }

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        let picks = ChartElementPicks.of(context.document)
        guard isSubselect() else {
            picks.clear()
            return false
        }
        let state = context.document.state
        guard let chart = ChartElementHits.chart(at: e.pasteboardPoint, document: context.document),
              let key = ChartElementHits.key(at: e.pasteboardPoint, in: chart, state: state, slop: 3 / max(context.viewport.zoom, 0.0001)) else {
            picks.clear()
            return false
        }
        context.selection.model.set(Selection([SelectionID(chart)]))
        picks.pick(key, in: chart, adding: e.modifiers.contains(.shift))
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {}
    func release(_ e: CanvasEvent, context: ToolContext) {}
    func cancel(context: ToolContext) {}

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        let picks = ChartElementPicks.of(context.document)
        guard let chart = picks.chart, context.selection.selection.contains(SelectionID(chart)) else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        for key in picks.keys {
            for rect in ChartElementHits.outlines(key, in: chart, state: context.document.state) {
                let corners = [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
                ctx.addPath(TextTool.polygon(corners.map { viewport.toView($0) }))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// The overrides the picks write.
@MainActor
enum ChartElementStyling {
    /// The picks of `document` when its selection is the picked chart.
    static func picks(_ document: DocumentHandle?, selection: [OpID]) -> (chart: OpID, keys: [ChartElementKeyRef])? {
        guard let document else { return nil }
        let picks = ChartElementPicks.of(document)
        guard let chart = picks.chart, !picks.keys.isEmpty, selection == [chart], document.state.isLive(chart) else { return nil }
        return (chart, picks.keys)
    }

    /// The override stored for `key`, if any.
    static func override(_ key: ChartElementKeyRef, in chart: OpID, state: EngineState) -> Wiretuner_Doc_V1_ChartOverride? {
        guard case .chart(let props)? = state.props(chart).kind else { return nil }
        let model = Chart(props)
        return model.liveOverrides(for: model.table)[key]
    }

    /// A colour from the Swatches panel on the picks: each key's fill or stroke (or both)
    /// replaced by a basic one of `color`, its other list kept.  One change.
    static func colorCommand(_ document: DocumentHandle?, selection: [OpID], target: ColorTarget, color: Wiretuner_Doc_V1_ColorRef) -> (any WTModel.Command)? {
        guard let document, let (chart, keys) = picks(document, selection: selection) else { return nil }
        let state = document.state
        let commands: [any WTModel.Command] = keys.map { key in
            var appearance = override(key, in: chart, state: state)?.appearance ?? Wiretuner_Doc_V1_AppearanceProps()
            if target.lists.contains(.fills) {
                var fill = Appearances.basicFill(red: 0, green: 0, blue: 0)
                fill.settings.basic.color = color
                appearance.fills = [fill]
            }
            if target.lists.contains(.strokes) {
                var stroke = appearance.strokes.first ?? Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)
                stroke.settings.basic.color = color
                appearance.strokes = [stroke]
            }
            return SetChartOverride(chart, key: key, appearance: appearance)
        }
        return CommandBatch("Style chart element", commands)
    }

    /// The section's stroke width on every pick.
    static func strokeWidth(_ width: Double, chart: OpID, keys: [ChartElementKeyRef], state: EngineState) -> (any WTModel.Command)? {
        guard width.isFinite, width >= 0 else { return nil }
        return CommandBatch("Style chart element", keys.map { key in
            var appearance = override(key, in: chart, state: state)?.appearance ?? Wiretuner_Doc_V1_AppearanceProps()
            var stroke = appearance.strokes.first ?? Appearances.basicStroke(red: 0, green: 0, blue: 0, width: 1)
            stroke.settings.basic.width = width
            appearance.strokes = [stroke]
            return SetChartOverride(chart, key: key, appearance: appearance)
        })
    }

    /// The section's scale (percent) and rotation (degrees) as each pick's extra transform.
    static func transform(scale: Double, rotation: Double, chart: OpID, keys: [ChartElementKeyRef]) -> (any WTModel.Command)? {
        guard scale.isFinite, scale > 0, rotation.isFinite else { return nil }
        let matrix = WTGeometry.AffineTransform.scale(x: scale / 100, y: scale / 100).concatenating(.rotation(radians: rotation * .pi / 180))
        return CommandBatch("Transform chart element", keys.map { SetChartOverride(chart, key: $0, transform: matrix) })
    }

    /// The scale and rotation an override's transform holds.
    static func scaleAndRotation(_ override: Wiretuner_Doc_V1_ChartOverride?) -> (scale: Double, rotation: Double) {
        guard let override, override.hasTransform else { return (100, 0) }
        let m = override.transform
        return ((hypot(m.a, m.b) * 100).rounded(), (atan2(m.b, m.a) * 180 / .pi).rounded())
    }
}

/// The Object panel's *Chart Element* section while elements of the selected chart are picked.
extension ObjectPanelModel {
    struct ChartElementSection: Equatable {
        let chart: OpID
        let keys: [ChartElementKeyRef]
        let title: String
        let strokeWidth: Double?
        let scale: Double
        let rotation: Double
    }

    var chartElement: ChartElementSection? {
        let nodes = selection.ids.map(\.opID)
        guard let (chart, keys) = ChartElementStyling.picks(document, selection: nodes) else { return nil }
        let state = document.state
        let first = ChartElementStyling.override(keys[0], in: chart, state: state)
        let widths = Set(keys.map { ChartElementStyling.override($0, in: chart, state: state)?.appearance.strokes.first?.settings.basic.width ?? 1 })
        let transform = ChartElementStyling.scaleAndRotation(first)
        let title = keys.count == 1 ? (keys[0].index == nil ? "Series" : "Element") : "\(keys.count) picks"
        return ChartElementSection(chart: chart, keys: keys, title: title, strokeWidth: widths.count == 1 ? widths.first : nil,
                                   scale: transform.scale, rotation: transform.rotation)
    }
}

struct ChartElementSectionView: View {
    let section: ObjectPanelModel.ChartElementSection
    let model: ObjectPanelModel

    static func strokeWidth(_ section: ObjectPanelModel.ChartElementSection, _ model: ObjectPanelModel) -> (Double) -> Void {
        { model.perform(ChartElementStyling.strokeWidth($0, chart: section.chart, keys: section.keys, state: model.document.state)) }
    }

    static func scale(_ section: ObjectPanelModel.ChartElementSection, _ model: ObjectPanelModel) -> (Double) -> Void {
        { model.perform(ChartElementStyling.transform(scale: $0, rotation: section.rotation, chart: section.chart, keys: section.keys)) }
    }

    static func rotation(_ section: ObjectPanelModel.ChartElementSection, _ model: ObjectPanelModel) -> (Double) -> Void {
        { model.perform(ChartElementStyling.transform(scale: section.scale, rotation: $0, chart: section.chart, keys: section.keys)) }
    }

    var body: some View {
        Form {
            Text("Chart \(section.title)").font(.headline).accessibilityIdentifier("object.chartElement.title")
            CommitField(title: "Stroke width", value: section.strokeWidth, identifier: "object.chartElement.stroke", commit: Self.strokeWidth(section, model))
            CommitField(title: "Scale %", value: section.scale, identifier: "object.chartElement.scale", commit: Self.scale(section, model))
            CommitField(title: "Rotate", value: section.rotation, identifier: "object.chartElement.rotate", commit: Self.rotation(section, model))
            Text("Color the picks from the Swatches panel.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}
