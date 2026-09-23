import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Connector tool (connectors.adoc; DRAW-036).  Over an object an end can attach to, the
/// cursor changes and the side nearest the pointer highlights; pressing there and dragging draws
/// a connector, previewed along its route, created by one `CreateConnector` on release -- attached
/// to the side under the pointer, or ending at a free point over empty canvas (a press on empty
/// canvas starts from a free point too).  A click on a connector selects it and shows its handles:
/// dragging an end handle re-attaches it to another object or side, or frees it over empty canvas
/// (one `SetConnectorEnd`, the whole end); dragging a run handle slides that run sideways (one
/// `SetConnectorRunOffsets`, the whole list).  Inside an object a press always starts a connector,
/// even where one already leaves that side; a click anywhere else selects as the Pointer does;
/// kbd:[Esc] abandons the drag.  Every gesture is one change and one undo step.
@MainActor
final class ConnectorTool: Tool, PointerTracking {
    static let id: ToolID = "connector"
    /// A drag shorter than this (view points) is a click.
    static let dragThreshold = 3.0
    /// How near a handle (view points) a press takes it.
    static let handleRadius = 5.0
    /// The handles' size, view points.
    static let handleSize = 7.0
    static let statusMessage = "Drag from a side of one object to a side of another to connect them; click a connector to move its ends or reshape it"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { ConnectorTool() }
    }

    /// What the press in progress does.
    enum Gesture: Equatable {
        /// Drawing a connector from `start`.
        case create(start: ConnectorEnd)
        /// Dragging one end of a selected connector.
        case moveEnd(OpID, ConnectorEndName)
        /// Dragging run handle `run` of a selected connector.
        case moveRun(ConnectorHandles, run: Int)
        /// A press on a connector's line: it is selected, and a drag does nothing.
        case pick
    }

    private var context: ToolContext?
    private(set) var gesture: Gesture?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?
    /// The object (and side) under the pointer an end would attach to.
    private(set) var hover: ConnectorTarget?
    /// The pointer is over a handle of a selected connector.
    private(set) var hoverHandle = false

    init() {}

    var cursor: NSCursor { hover != nil || hoverHandle ? .pointingHand : .crosshair }

    var hasSomethingToCancel: Bool { gesture != nil }

    /// Whether the press in progress has moved far enough to be a drag.
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
        hover = nil
        hoverHandle = false
        context = nil
    }

    // MARK: Reading the canvas

    /// The attachable object under `e`, grown by the pick distance.
    func target(at e: CanvasEvent) -> ConnectorTarget? {
        guard let context else { return nil }
        let tolerance = context.snapping.pickDistance() / max(context.viewport.zoom, 1e-9)
        return ConnectorTarget.find(at: e.pasteboardPoint, tolerance: tolerance, in: context.document)
    }

    /// The handles of every selected connector.
    var handles: [ConnectorHandles] {
        guard let context else { return [] }
        let document = context.document
        return context.selection.selection.ids.compactMap { id in
            document.object(for: id)?.kind == .connector ? ConnectorHandles.make(id.opID, in: document) : nil
        }
    }

    /// The handle of a selected connector under `viewPoint`.
    func handle(at viewPoint: Point) -> (handles: ConnectorHandles, handle: ConnectorHandles.Handle)? {
        guard let context else { return nil }
        for connector in handles {
            if let handle = connector.handle(at: viewPoint, viewport: context.viewport, radius: Self.handleRadius) { return (connector, handle) }
        }
        return nil
    }

    /// The end a release at `e` writes: attached to the side under the pointer, or free there.
    func end(at e: CanvasEvent) -> ConnectorEnd {
        if let hover { return hover.end }
        guard let context else { return ConnectorEnd(point: e.pasteboardPoint) }
        return ConnectorEnd(point: context.snapping.snap(e.pasteboardPoint, viewport: context.viewport))
    }

    // MARK: Events

    func pointerMoved(_ e: CanvasEvent) {
        guard let context, gesture == nil else { return }
        let target = target(at: e)
        let onHandle = handle(at: e.viewPoint) != nil
        guard target != hover || onHandle != hoverHandle else { return }
        let cursorChanges = (target != nil || onHandle) != (hover != nil || hoverHandle)
        hover = target
        hoverHandle = onHandle
        context.host.setNeedsOverlayDisplay()
        if cursorChanges { context.host.toolCursorDidChange() }
    }

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        start = e
        current = e
        if let (connector, handle) = handle(at: e.viewPoint) {
            hover = nil
            switch handle {
            case .end(let which): gesture = .moveEnd(connector.node, which)
            case .run(let run): gesture = .moveRun(connector, run: run)
            }
            return
        }
        let target = target(at: e)
        // Inside an object a press starts a connector even where one already leaves it; elsewhere a
        // press on a connector's line picks it.
        if target?.bounds.contains(e.pasteboardPoint) != true,
           let hit = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: false),
           context.document.object(for: hit.id)?.kind == .connector {
            context.selection.click(at: e.viewPoint, viewport: context.viewport, modifiers: e.modifiers, subselect: false)
            hover = nil
            gesture = .pick
            return
        }
        hover = target
        gesture = .create(start: end(at: e))
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let gesture else { return }
        current = e
        switch gesture {
        case .create, .moveEnd: hover = target(at: e)
        case .moveRun, .pick: break
        }
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, let gesture, let start else { return }
        guard isDragging else {
            if case .create = gesture {
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

    /// The one command a drag released at `e` performs.
    func command(releasedAt e: CanvasEvent) -> (any WTModel.Command)? {
        guard let gesture, let start else { return nil }
        switch gesture {
        case .create(let from):
            return CreateConnector(start: from, end: end(at: e))
        case let .moveEnd(node, which):
            return SetConnectorEnd(node, which, to: end(at: e))
        case let .moveRun(handles, run):
            return SetConnectorRunOffsets(handles.node, offsets: handles.offsets(draggingRun: run, by: e.pasteboardPoint - start.pasteboardPoint))
        case .pick:
            return nil
        }
    }

    /// The route the drag in progress would give, pasteboard space.
    var preview: ConnectorRoute? {
        guard isDragging, let context, let gesture, let start, let current else { return nil }
        let document = context.document
        let state = document.state
        var spec: ConnectorSpec
        switch gesture {
        case .create(let from):
            spec = ConnectorSpec(id: NodeID(counter: 0, replica: 0), start: from, end: end(at: current))
        case let .moveEnd(node, which):
            spec = Connectors.spec(node, in: state, layers: LayerOrder(state))
            if which == .start { spec.start = end(at: current) } else { spec.end = end(at: current) }
        case let .moveRun(handles, run):
            spec = Connectors.spec(handles.node, in: state, layers: LayerOrder(state))
            spec.runOffsets = handles.offsets(draggingRun: run, by: current.pasteboardPoint - start.pasteboardPoint)
        case .pick:
            return nil
        }
        let scene = document.scene
        return ConnectorRouter.route(spec) { id in scene.objects[id].flatMap { Connectors.attachmentBounds(of: $0.item) } }
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    /// kbd:[Esc]: abandons the drag without writing anything.
    func cancel() {
        gesture = nil
        start = nil
        current = nil
    }

    // MARK: Overlay

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        let accent = NSColor.controlAccentColor.cgColor
        ctx.setStrokeColor(accent)
        ctx.setFillColor(accent)
        let toView = viewport.pasteboardToView
        if let hover {
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            ctx.stroke(hover.bounds.applying(toView).cgRect)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(3)
            let (a, b) = hover.edge
            ctx.strokeLineSegments(between: [toView.apply(a).cgPoint, toView.apply(b).cgPoint])
        }
        if let preview {
            let path = CGMutablePath()
            SelectionOverlay.add(preview.path, transform: toView, to: path)
            ctx.setLineWidth(1)
            ctx.addPath(path)
            ctx.strokePath()
        }
        let half = Self.handleSize / 2
        for connector in handles {
            for handle in connector.handles {
                let at = viewport.toView(connector.position(handle))
                let rect = CGRect(x: at.x - half, y: at.y - half, width: Self.handleSize, height: Self.handleSize)
                switch handle {
                case .end: ctx.fillEllipse(in: rect)
                case .run: ctx.fill(rect)
                }
            }
        }
    }
}
