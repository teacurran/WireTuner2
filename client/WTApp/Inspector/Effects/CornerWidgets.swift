import AppKit
import Observation
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// One corner a widget sits in: a point where two segments meet at an angle, in pasteboard space.
struct CornerWidget: Equatable {
    var node: OpID
    /// The corner's point (a rectangle's corners have none worth writing: nil).
    var point: OpID?
    var anchor: Point
    /// The unit vector halving the corner's angle, pointing into the corner.
    var bisector: Vector
    /// Half the angle between the two segments (radians, 0 < half < π/2).
    var half: Double
}

/// The Subselect tool's corner widgets (live-effects.adoc, "Corners", "To round corners by
/// dragging"; FX-047): a small round widget just inside every corner point of each selected path
/// or rectangle -- curve points have none.  Dragging one sets the radius of the object's Corners
/// effect, adding the effect on the first drag, and with points selected adds them to the
/// effect's *Selected points*; kbd:[Option]-click cycles the style (Round, Inverted round,
/// Chamfer); a double-click shows the effect in the Object panel.  A drag is one undo step.
/// menu:View[Show Corner Widgets] hides them.
@MainActor
final class CornerWidgetLayer: CanvasHandleLayer {
    static let radius = 5.0
    static let size = 7.0
    /// The widget's distance inside its corner when the radius is zero (view points).
    static let inset = 8.0
    /// menu:View[Show Corner Widgets].
    static var isShown: @MainActor () -> Bool = { true }
    /// Shows the Object panel (a double-click on a widget).
    static var showPanel: @MainActor () -> Void = {}

    var tools: Set<ToolID>? { [PointerTool.subselectID] }

    private(set) var dragging: CornerWidget?
    private var pressed: CanvasEvent?
    private var moved = false
    /// The drag's writes, in order (the first one may add the effect before the rest can find it).
    private var chain: Task<Void, Never>?
    private var wrote = false
    private var addedPoints = false

    init() {}

    // MARK: Geometry

    /// The corners of `object` (a path or a rectangle), pasteboard space.
    static func corners(of object: SceneObject) -> [CornerWidget] {
        guard object.kind == .path || object.kind == .rect, let path = object.path else { return [] }
        let t = object.transform
        var result: [CornerWidget] = []
        for contour in path.contours where contour.isRenderable {
            let drawn = contour.drawn
            let count = drawn.count
            for index in drawn.indices where drawn[index].kind != .curve {
                guard contour.closed || (index > 0 && index < count - 1) else { continue }
                let point = drawn[index], previous = drawn[(index - 1 + count) % count], next = drawn[(index + 1) % count]
                let anchor = t.apply(point.anchor)
                let toPrevious = t.apply(point.inHandle != .zero ? point.anchor + point.inHandle : previous.anchor + previous.outHandle) - anchor
                let toNext = t.apply(point.outHandle != .zero ? point.anchor + point.outHandle : next.anchor + next.inHandle) - anchor
                guard toPrevious.length > 1e-9, toNext.length > 1e-9 else { continue }
                let a = toPrevious.normalized, b = toNext.normalized
                let angle = acos(min(max(a.dot(b), -1), 1))
                guard angle > 0.001, angle < .pi - 0.001 else { continue }
                result.append(CornerWidget(node: object.id, point: object.kind == .rect ? nil : point.id, anchor: anchor,
                                           bisector: (a + b).normalized, half: angle / 2))
            }
        }
        return result
    }

    /// The object-level Corners effect of `node`, if it has one.
    static func effect(_ node: OpID, in state: EngineState) -> EffectEntry? {
        EffectReading.entries(node, in: state).last { $0.kind == .corners && $0.attachment == .object && !$0.effect.hidden }
    }

    /// The radius drawn at `corner` now: the effect's, when the effect treats that corner.
    static func radius(_ corner: CornerWidget, in state: EngineState) -> Double {
        guard let entry = effect(corner.node, in: state) else { return 0 }
        let points = entry.effect.settings.corners.points.compactMap { OpID(element: $0) }
        guard points.isEmpty || corner.point.map(points.contains) == true else { return 0 }
        return entry.effect.settings.corners.radius
    }

    /// Where the widget draws: at the rounding's centre, or `inset` view points inside a sharp corner.
    static func position(_ corner: CornerWidget, radius: Double, zoom: Double) -> Point {
        let distance = max(radius / sin(corner.half), inset / max(zoom, 1e-9))
        return corner.anchor + corner.bisector * distance
    }

    /// The radius a widget dragged to `point` (pasteboard) makes: the rounding whose centre is the
    /// pointer's place along the bisector.
    static func radius(_ corner: CornerWidget, draggedTo point: Point) -> Double {
        max(0, (point - corner.anchor).dot(corner.bisector) * sin(corner.half))
    }

    /// Every widget of the selection, with where it draws.
    static func widgets(_ context: ToolContext) -> [(corner: CornerWidget, at: Point)] {
        guard isShown() else { return [] }
        let state = context.document.state
        return context.selection.selection.ids.flatMap { id -> [(corner: CornerWidget, at: Point)] in
            guard let object = context.document.object(for: id) else { return [] }
            return corners(of: object).map { ($0, position($0, radius: radius($0, in: state), zoom: context.viewport.zoom)) }
        }
    }

    /// The selected points of `node` (the drag adds them to *Selected points*).
    static func selectedPoints(_ node: OpID, context: ToolContext) -> [OpID] {
        guard case let .points(points)? = context.selection.selection.subSelection(of: SelectionID(node)) else { return [] }
        return points.map(\.point).sorted()
    }

    // MARK: Commands

    /// The next style after `style` (Round → Inverted round → Chamfer → Round).
    static func nextStyle(_ style: Wiretuner_Doc_V1_CornerStyle) -> Wiretuner_Doc_V1_CornerStyle {
        switch style {
        case .invertedRound: .chamfer
        case .chamfer: .round
        default: .invertedRound
        }
    }

    static func cycleStyle(_ node: OpID, in state: EngineState) -> (any WTModel.Command)? {
        guard let entry = effect(node, in: state) else { return nil }
        let next = nextStyle(entry.effect.settings.corners.style)
        return EditEffect([(node, entry.row)], label: "Change corner style", fields: [EffectField.corners(2)]) { $0.corners.style = next }
    }

    /// The radius write, with the selected points added once per drag.
    static func radiusCommand(_ node: OpID, radius: Double, points: [OpID], in state: EngineState) -> (any WTModel.Command)? {
        guard let entry = effect(node, in: state) else { return nil }
        var commands: [any WTModel.Command] = [EditEffect([(node, entry.row)], label: "Change corner radius", fields: [EffectField.corners(1)]) {
            $0.corners.radius = radius
        }]
        let current = Set(entry.effect.settings.corners.points.compactMap { OpID(element: $0) })
        let adding = points.filter { !current.contains($0) }
        if !adding.isEmpty { commands.append(SetCornerPoints([(node, entry.row)], points: adding, adding: true)) }
        return commands.count == 1 ? commands[0] : CompositeCommand("Change corner radius", commands)
    }

    // MARK: CanvasHandleLayer

    func press(_ e: CanvasEvent, context: ToolContext) -> Bool {
        guard let hit = Self.widgets(context).first(where: { context.viewport.toView($0.at).distance(to: e.viewPoint) <= Self.radius }) else { return false }
        if e.clickCount >= 2 {
            if let entry = Self.effect(hit.corner.node, in: context.document.state) {
                InspectorRowRequest.shared.request(entry.row, targets: [hit.corner.node])
                Self.showPanel()
            }
            return true
        }
        dragging = hit.corner
        pressed = e
        moved = false
        wrote = false
        addedPoints = false
        chain = nil
        context.document.beginGroup()
        return true
    }

    func drag(_ e: CanvasEvent, context: ToolContext) {
        guard let corner = dragging, let pressed else { return }
        if !moved, e.viewPoint.distance(to: pressed.viewPoint) < PointerTool.dragThreshold { return }
        moved = true
        wrote = true
        let radius = Self.radius(corner, draggedTo: e.pasteboardPoint)
        let document = context.document, sink = context.commandSink
        let points = corner.point == nil ? [] : Self.selectedPoints(corner.node, context: context)
        if Self.effect(corner.node, in: document.state) == nil, chain == nil {
            let add = sink.perform(AddEffect([corner.node], kind: .corners))
            chain = Task { @MainActor in _ = await add.value }
        }
        let previous = chain
        let addPoints = !addedPoints
        addedPoints = true
        chain = Task { @MainActor in
            await previous?.value
            await document.settle()
            if let command = Self.radiusCommand(corner.node, radius: radius, points: addPoints ? points : [], in: document.state) {
                _ = await sink.perform(command).value
            }
        }
    }

    func release(_ e: CanvasEvent, context: ToolContext) {
        if !moved, let corner = dragging, pressed?.modifiers.contains(.option) == true,
           let command = Self.cycleStyle(corner.node, in: context.document.state) {
            wrote = true
            context.commandSink.perform(command)
        } else {
            drag(e, context: context)
        }
        finish(context, undo: false)
    }

    func cancel(context: ToolContext) {
        finish(context, undo: wrote)
    }

    private func finish(_ context: ToolContext, undo: Bool) {
        guard dragging != nil else { return }
        dragging = nil
        pressed = nil
        let document = context.document, previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await document.settle()
            document.endGroup()
            if undo { _ = await document.undo().value }
        }
    }

    /// Waits for the drag's writes (tests).
    func settle() async {
        await chain?.value
    }

    func draw(in ctx: CGContext, viewport: Viewport, context: ToolContext) {
        let widgets = Self.widgets(context)
        guard !widgets.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        for widget in widgets {
            let at = viewport.toView(widget.at)
            CanvasHandleLayers.drawHandle(at, size: Self.size, in: ctx)
            CanvasHandleLayers.drawHandle(at, size: Self.size, hollow: true, in: ctx)
        }
        ctx.restoreGState()
    }
}

/// A row the canvas asks the Object panel to select (a double-click on a corner widget): the
/// panel selects it in its Attributes list when it next draws.
@MainActor
@Observable
final class InspectorRowRequest {
    static let shared = InspectorRowRequest()

    struct Request: Equatable {
        var row: AppearanceRow
        var targets: [OpID]
        var serial: Int
    }

    private(set) var pending: Request?
    private var serial = 0

    init() {}

    func request(_ row: AppearanceRow, targets: [OpID]) {
        serial += 1
        pending = Request(row: row, targets: targets, serial: serial)
    }

    /// Applies the pending request to `state` once.
    func apply(to state: AttributesState) {
        guard let pending else { return }
        state.select(pending.row, targets: pending.targets)
        self.pending = nil
    }
}

extension ObjectPanelModel {
    /// Whether any selected rectangle carries a Corners effect: its own radius is ignored, so the
    /// rectangle section dims its radius fields and says why.
    var rectangleCornersEffect: Bool {
        objects.contains { $0.object.kind == .rect && CornerWidgetLayer.effect($0.id, in: document.state) != nil }
    }

    static let cornersEffectNote = "The Corners effect sets these corners; remove it to use the rectangle's own radius."
}

/// menu:View[Show Corner Widgets], kept in this Mac's defaults.
@MainActor
enum CornerWidgetCommands {
    static let id: CommandID = "view.showCornerWidgets"
    static let key = "WTShowCornerWidgets"

    static func isShown(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func command(defaults: UserDefaults, redraw: @escaping @MainActor () -> Void) -> Command {
        Command(id: id, title: "Show Corner Widgets", menu: MenuPath(StandardCommands.Menu.view, section: StandardCommands.Section.viewRulers, subsection: 2),
                keywords: ["corners", "widgets", "round"], validation: { .checked(isShown(defaults)) },
                action: .perform {
                    defaults.set(!isShown(defaults), forKey: key)
                    redraw()
                })
    }
}
