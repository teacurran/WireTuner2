import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Extrude tool (extrude.adoc, "Extruding" and "Editing on the canvas"; FX-020).  A drag from a
/// flat object extrudes it toward where the drag ends -- the vanishing point -- previewing the
/// solid's rear face as it goes.  A click on an extrusion selects it and shows its controls: the
/// centre point (drag to move the object, the vanishing point staying put), the depth control on
/// the axis toward the vanishing point (drag to lengthen or shorten) and the vanishing point (drag
/// anywhere; kbd:[Shift] keeps it level with or directly above the centre).  A double-click enters
/// rotate mode: a rotation circle around the object -- drag inside to tumble it about x and y,
/// outside to spin it about z, kbd:[Shift] for 15° steps -- left by kbd:[Tab], another double-click
/// or another tool.  Every drag is one change and one undo step.
@MainActor
final class ExtrudeTool: Tool {
    static let id: ToolID = "extrude"
    static let dragThreshold = 3.0
    static let handleRadius = 6.0
    static let handleSize = 8.0
    /// Degrees of tumble per view point dragged inside the rotation circle.
    static let tumble = 0.5
    /// Space outside the object's bounds before the rotation circle, view points.
    static let circleMargin = 12.0
    static let tabKeyCode: UInt16 = 48
    static let statusMessage = "Drag from an object toward the vanishing point to extrude it; click an extrusion to edit it, double-click to rotate it"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { ExtrudeTool() }
    }

    /// One extrusion's controls, pasteboard space.
    struct Handles: Equatable {
        enum Part: Equatable {
            case center, depth, vanishing
        }

        var wrapper: OpID
        var bounds: Rect
        var center: Point
        var depth: Point
        var vanishing: Point
        /// The unit direction from the centre toward the vanishing point.
        var axis: Vector
        var length: Double
        var rotation: Wiretuner_Doc_V1_Rotation3

        func position(_ part: Part) -> Point {
            switch part {
            case .center: center
            case .depth: depth
            case .vanishing: vanishing
            }
        }
    }

    enum Gesture: Equatable {
        /// Extruding a flat object.
        case create(OpID)
        /// Dragging one control of an extrusion.
        case handle(Handles, Handles.Part)
        /// Rotating in rotate mode: inside the circle (x and y) or outside (z).
        case rotate(Handles, inside: Bool)
        /// A click that selected something.
        case pick
    }

    private var context: ToolContext?
    private(set) var gesture: Gesture?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?
    /// The extrusion in rotate mode.
    private(set) var rotating: OpID?

    init() {}

    var cursor: NSCursor { .crosshair }
    var hasSomethingToCancel: Bool { gesture != nil || rotating != nil }

    var isDragging: Bool {
        guard let start, let current else { return false }
        return current.viewPoint.distance(to: start.viewPoint) >= Self.dragThreshold
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        rotating = nil
        context = nil
    }

    // MARK: Reading the document

    /// The bounds of the flat shape an extrusion extrudes (its front face), pasteboard space; the
    /// whole solid's without one.
    static func frontBounds(_ wrapper: OpID, in document: DocumentHandle) -> Rect? {
        ExtrudeReading.child(wrapper, in: document.state).flatMap { document.object(for: SelectionID($0))?.bounds }
            ?? document.object(for: SelectionID(wrapper))?.bounds
    }

    /// The controls of extrusion `wrapper`, nil when it draws nothing.
    static func handles(_ wrapper: OpID, in document: DocumentHandle) -> Handles? {
        guard let bounds = frontBounds(wrapper, in: document) else { return nil }
        let props = document.state.props(wrapper).extrude
        let center = bounds.center
        let vanishing = Point(x: props.vanishingPoint.x, y: props.vanishingPoint.y)
        let toward = vanishing - center
        let axis = toward.length > 0 ? Vector(dx: toward.dx / toward.length, dy: toward.dy / toward.length) : Vector(dx: 0, dy: -1)
        let reach = toward.length > 0 ? min(props.length, toward.length) : props.length
        return Handles(wrapper: wrapper, bounds: bounds, center: center, depth: center + Vector(dx: axis.dx * reach, dy: axis.dy * reach),
                       vanishing: vanishing, axis: axis, length: props.length, rotation: props.rotation)
    }

    /// The extrusions selected in the window, with their controls.
    var selectedHandles: [Handles] {
        guard let context else { return [] }
        let document = context.document
        return context.selection.selection.ids.compactMap { id in
            document.object(for: id)?.kind == .extrude ? Self.handles(id.opID, in: document) : nil
        }
    }

    /// The extrusion `node` is or lies inside, if any.
    static func extrusion(of node: OpID, in state: EngineState) -> OpID? {
        var current: OpID? = node
        var steps = 0
        while let id = current, steps < 1000 {
            if state.nodeKind(id) == .extrude { return id }
            current = state.store.placement(id)?.parent
            steps += 1
        }
        return nil
    }

    /// The rotation circle's radius in view points.
    static func circleRadius(_ handles: Handles, viewport: Viewport) -> Double {
        max(handles.bounds.width, handles.bounds.height) / 2 * viewport.zoom + circleMargin
    }

    // MARK: Events

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        start = e
        current = e
        let viewport = context.viewport
        if let rotating, let handles = Self.handles(rotating, in: context.document) {
            let hit = context.selection.pick(at: e.viewPoint, viewport: viewport, subselect: false)?.id.opID
            if e.clickCount >= 2, hit.flatMap({ Self.extrusion(of: $0, in: context.document.state) }) == rotating {
                self.rotating = nil
                gesture = .pick
                return
            }
            let inside = viewport.toView(handles.center).distance(to: e.viewPoint) <= Self.circleRadius(handles, viewport: viewport)
            gesture = .rotate(handles, inside: inside)
            return
        }
        // A double-click on an extrusion enters rotate mode, even over its centre point.
        if e.clickCount >= 2, let hit = context.selection.pick(at: e.viewPoint, viewport: viewport, subselect: false)?.id.opID,
           let wrapper = Self.extrusion(of: hit, in: context.document.state) {
            context.selection.model.set(Selection([SelectionID(wrapper)]))
            rotating = wrapper
            gesture = .pick
            return
        }
        for handles in selectedHandles {
            for part in [Handles.Part.vanishing, .depth, .center]
            where viewport.toView(handles.position(part)).distance(to: e.viewPoint) <= Self.handleRadius {
                gesture = .handle(handles, part)
                return
            }
        }
        guard let hit = context.selection.pick(at: e.viewPoint, viewport: viewport, subselect: false)?.id.opID else {
            context.selection.click(at: e.viewPoint, viewport: viewport, modifiers: e.modifiers, subselect: false)
            gesture = .pick
            return
        }
        if let wrapper = Self.extrusion(of: hit, in: context.document.state) {
            context.selection.model.set(Selection([SelectionID(wrapper)]))
            gesture = .pick
        } else {
            gesture = .create(hit)
        }
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard gesture != nil else { return }
        current = e
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let gesture, isDragging else {
            if let context, let start, case .create? = gesture {
                context.selection.click(at: start.viewPoint, viewport: context.viewport, modifiers: e.modifiers, subselect: false)
            }
            return
        }
        guard let command = command(releasedAt: e) else { return }
        let task = context.commandSink.perform(command)
        guard case .create = gesture else { return }
        let selection = context.selection
        Task { @MainActor in
            guard let created = await task.value?.createdObjects.first else { return }
            selection.model.set(Selection([SelectionID(created)]))
        }
    }

    /// The one command the drag released at `e` performs.
    func command(releasedAt e: CanvasEvent) -> (any WTModel.Command)? {
        guard let gesture, let start, let context else { return nil }
        switch gesture {
        case .create(let node):
            return Extrude([node], vanishingPoint: e.pasteboardPoint)
        case let .handle(handles, part):
            switch part {
            case .center:
                return MoveObjects([handles.wrapper], by: e.pasteboardPoint - start.pasteboardPoint)
            case .depth:
                let length = Self.length(handles, at: e.pasteboardPoint)
                return EditExtrusion([handles.wrapper], label: "Change depth", fields: [ExtrudeFields.length]) { $0.length = length }
            case .vanishing:
                let point = Self.vanishing(handles, at: e.pasteboardPoint, constrained: e.modifiers.contains(.shift))
                return EditExtrusion([handles.wrapper], label: "Move vanishing point", fields: [ExtrudeFields.vanishingPoint]) {
                    $0.vanishingPoint = EffectEditorModel.point(point.x, point.y)
                }
            }
        case let .rotate(handles, inside):
            let rotation = Self.rotation(handles, from: start, to: e, inside: inside, viewport: context.viewport)
            return EditExtrusion([handles.wrapper], label: "Rotate extrusion", fields: [ExtrudeFields.rotation]) { $0.rotation = rotation }
        case .pick:
            return nil
        }
    }

    /// The depth the depth control dragged to `point` gives: its distance along the axis.
    static func length(_ handles: Handles, at point: Point) -> Double {
        let offset = point - handles.center
        return min(max(offset.dx * handles.axis.dx + offset.dy * handles.axis.dy, 0), 32000)
    }

    /// The vanishing point dragged to `point`; constrained, it keeps level with the centre or
    /// directly above or below it, whichever is nearer.
    static func vanishing(_ handles: Handles, at point: Point, constrained: Bool) -> Point {
        guard constrained else { return point }
        let dx = abs(point.x - handles.center.x), dy = abs(point.y - handles.center.y)
        return dx >= dy ? Point(x: point.x, y: handles.center.y) : Point(x: handles.center.x, y: point.y)
    }

    /// The rotation a drag from `start` to `end` gives: inside the circle a trackball about x and
    /// y, outside a spin about z; kbd:[Shift] snaps each angle to 15°.
    static func rotation(_ handles: Handles, from start: CanvasEvent, to end: CanvasEvent, inside: Bool, viewport: Viewport) -> Wiretuner_Doc_V1_Rotation3 {
        var rotation = handles.rotation
        if inside {
            rotation.y += (end.viewPoint.x - start.viewPoint.x) * tumble
            rotation.x -= (end.viewPoint.y - start.viewPoint.y) * tumble
        } else {
            let center = viewport.toView(handles.center)
            let from = atan2(start.viewPoint.y - center.y, start.viewPoint.x - center.x)
            let to = atan2(end.viewPoint.y - center.y, end.viewPoint.x - center.x)
            rotation.z -= (to - from) * 180 / .pi
        }
        guard end.modifiers.contains(.shift) else { return rotation }
        let snap = { (degrees: Double) in (degrees / 15).rounded() * 15 }
        rotation.x = snap(rotation.x)
        rotation.y = snap(rotation.y)
        rotation.z = snap(rotation.z)
        return rotation
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    /// kbd:[Tab] leaves rotate mode.
    func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == Self.tabKeyCode, rotating != nil else { return false }
        rotating = nil
        return true
    }

    /// kbd:[Esc]: abandons the drag; with none, leaves rotate mode.
    func cancel() {
        if gesture == nil { rotating = nil }
        gesture = nil
        start = nil
        current = nil
    }

    // MARK: Overlay

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        let accent = NSColor.controlAccentColor.cgColor
        ctx.setStrokeColor(accent)
        ctx.setFillColor(accent)
        ctx.setLineWidth(1)
        if let context, case .create(let node)? = gesture, let current, isDragging,
           let bounds = context.document.object(for: SelectionID(node))?.bounds {
            Self.drawPreview(bounds, toward: current.pasteboardPoint, in: ctx, viewport: viewport)
        }
        if let context, let rotating, let handles = Self.handles(rotating, in: context.document) {
            let center = viewport.toView(handles.center)
            let radius = Self.circleRadius(handles, viewport: viewport)
            ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
            // The z-axis marker.
            CanvasHandleLayers.drawHandle(Point(x: center.x, y: center.y - radius), size: Self.handleSize, in: ctx)
            return
        }
        for var handles in selectedHandles {
            if case let .handle(dragged, part)? = gesture, dragged.wrapper == handles.wrapper, let current, let start {
                handles = Self.moved(handles, part: part, from: start.pasteboardPoint, to: current.pasteboardPoint, constrained: current.modifiers.contains(.shift))
            }
            let center = viewport.toView(handles.center), depth = viewport.toView(handles.depth), vanishing = viewport.toView(handles.vanishing)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.strokeLineSegments(between: [center.cgPoint, vanishing.cgPoint])
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.fill(CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            CanvasHandleLayers.drawHandle(depth, size: Self.handleSize, in: ctx)
            CanvasHandleLayers.drawHandle(vanishing, size: Self.handleSize, hollow: true, in: ctx)
        }
    }

    /// The controls while `part` is dragged from `from` to `to`.
    static func moved(_ handles: Handles, part: Handles.Part, from: Point, to: Point, constrained: Bool) -> Handles {
        var result = handles
        switch part {
        case .center:
            let delta = to - from
            result.center = handles.center + delta
            result.depth = handles.depth + delta
        case .depth:
            let length = length(handles, at: to)
            result.depth = handles.center + Vector(dx: handles.axis.dx * length, dy: handles.axis.dy * length)
        case .vanishing:
            result.vanishing = vanishing(handles, at: to, constrained: constrained)
        }
        return result
    }

    /// The drag's preview: the object's outline, a smaller copy toward the vanishing point as the
    /// rear face, and the edges joining them.
    static func drawPreview(_ bounds: Rect, toward vanishing: Point, in ctx: CGContext, viewport: Viewport) {
        let rear = { (point: Point) in Point(x: point.x + (vanishing.x - point.x) * 0.3, y: point.y + (vanishing.y - point.y) * 0.3) }
        let corners = [Point(x: bounds.minX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.minY), Point(x: bounds.maxX, y: bounds.maxY), Point(x: bounds.minX, y: bounds.maxY)]
        let front = corners.map { viewport.toView($0).cgPoint }
        let back = corners.map { viewport.toView(rear($0)).cgPoint }
        ctx.addLines(between: front + [front[0]])
        ctx.addLines(between: back + [back[0]])
        for (a, b) in zip(front, back) { ctx.addLines(between: [a, b]) }
        ctx.strokePath()
    }
}
