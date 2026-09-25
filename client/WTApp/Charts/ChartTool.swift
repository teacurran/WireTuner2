import AppKit
import SwiftUI
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Chart tool (charts.adoc, "Creating a chart"; DRAW-033): drag on the canvas to set the
/// chart's size; the chart is created ("Chart") and the Chart sheet opens on its *Data* tab with
/// the top-left cell active.  kbd:[Shift] squares the drag.
@MainActor
final class ChartTool: Tool {
    static let id: ToolID = "chart"
    static let statusMessage = "Drag to set the chart's size"
    static let minimumSize = 4.0

    private var context: ToolContext?
    private(set) var start: Point?
    private(set) var current: Point?
    /// Opens the Chart sheet on a chart just made.
    let openSheet: @MainActor (OpID) -> Void
    /// The creation in flight (tests await it).
    private(set) var creation: Task<Void, Never>?

    init(openSheet: @escaping @MainActor (OpID) -> Void = { _ in }) {
        self.openSheet = openSheet
    }

    var cursor: NSCursor { .crosshair }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    func mouseDown(_ e: CanvasEvent) {
        start = e.pasteboardPoint
        current = e.pasteboardPoint
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let start else { return }
        var point = e.pasteboardPoint
        if e.modifiers.contains(.shift) {
            let side = max(abs(point.x - start.x), abs(point.y - start.y))
            point = Point(x: start.x + (point.x < start.x ? -side : side), y: start.y + (point.y < start.y ? -side : side))
        }
        current = point
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let rect = rect else { return }
        let command = CreateChart(size: Size(width: rect.width, height: rect.height), transform: .translation(x: rect.minX, y: rect.minY),
                                  layer: context.objectEditing?.activeLayer)
        let task = context.commandSink.perform(command)
        let selection = context.selection
        let open = openSheet
        creation = Task { @MainActor in
            guard let chart = await task.value?.createdObjects.first else { return }
            selection.model.set(Selection([SelectionID(chart)]))
            open(chart)
        }
    }

    /// The dragged rectangle; nil for a drag too small to be a chart.
    var rect: Rect? {
        guard let start, let current else { return nil }
        let rect = Rect(start, current)
        return rect.width >= Self.minimumSize && rect.height >= Self.minimumSize ? rect : nil
    }

    func flagsChanged(_ e: CanvasEvent) {}
    func keyDown(_ e: NSEvent) -> Bool { false }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let rect else { return }
        let corners = [Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY), Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY)]
            .map { viewport.toView($0).cgPoint }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.addLines(between: corners + [corners[0]])
        ctx.strokePath()
    }

    func cancel() {
        start = nil
        current = nil
    }

    var hasSomethingToCancel: Bool { start != nil }
}

/// The Chart tool's delivery, the Chart sheet on a window, double-click-to-edit on the tool, and
/// menu:Object[Chart > Edit Data…] and *Chart Type…*.
@MainActor
enum ChartFeatures {
    static let noChart = "Select a chart"

    /// The one selected chart of `window`.
    static func selectedChart(in window: DocumentWindowController?) -> OpID? {
        guard let window else { return nil }
        let state = window.documentHandle.state
        let charts = window.selection.selection.ids.map(\.opID).filter { state.nodeKind($0) == .chart }
        return charts.count == 1 ? charts[0] : nil
    }

    /// Opens the Chart sheet for `chart` on `window`.
    @discardableResult
    static func present(_ chart: OpID, tab: ChartSheetModel.Tab = .data, on window: DocumentWindowController) -> NSWindow? {
        let model = ChartSheetModel(chart: chart, document: window.documentHandle, sink: window.objectEditing, tab: tab)
        return window.presentSheet("chart-sheet") { close in ChartSheetView(model: model, close: close) }
    }

    static func descriptor(window: @escaping @MainActor () -> DocumentWindowController?) -> ToolDescriptor {
        ToolCatalog.all.first { $0.id == ChartTool.id }!.delivering {
            ChartTool { chart in if let front = window() { present(chart, on: front) } }
        }
    }

    /// The tool's double-click: the sheet for the selected chart; every other tool keeps `previous`.
    static func toolOptions(window: @escaping @MainActor () -> DocumentWindowController?,
                            previous: @escaping @MainActor (ToolDescriptor) -> Void) -> @MainActor (ToolDescriptor) -> Void {
        { descriptor in
            guard descriptor.id == ChartTool.id else { return previous(descriptor) }
            if let front = window(), let chart = selectedChart(in: front) { present(chart, on: front) }
        }
    }

    static func commands(window: @escaping @MainActor () -> DocumentWindowController?) -> [Command] {
        let validation: @MainActor @Sendable () -> CommandValidation = { selectedChart(in: window()) == nil ? .disabled(noChart) : .enabled }
        func open(_ tab: ChartSheetModel.Tab) -> CommandAction {
            .perform { if let front = window(), let chart = selectedChart(in: front) { present(chart, tab: tab, on: front) } }
        }
        let object = ContextMenuCatalog.Menu.object
        return [
            Command(id: ContextMenuCatalog.ID.chartEditData, title: "Edit Data…", menu: MenuPath(object, "Chart", section: 0), contexts: [.chart],
                    keywords: ["chart", "data", "table"], validation: validation, action: open(.data)),
            Command(id: ContextMenuCatalog.ID.chartType, title: "Chart Type…", menu: MenuPath(object, "Chart", section: 0), contexts: [.chart],
                    keywords: ["chart", "type", "axis"], validation: validation, action: open(.type)),
        ]
    }
}
