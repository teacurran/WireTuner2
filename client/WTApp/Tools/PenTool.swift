import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The path a Pen (or, with DRAW-022, Bezigon) session is building (pen-bezigon.adoc, "Client"):
/// the node, its contour, the element id of the end being extended and which end.  The tool
/// tracks the element, not an index, so remote inserts and deletes elsewhere in the contour never
/// move where the next point goes.
struct PathBuildingSession: Equatable, Sendable {
    var node: OpID
    var contour: OpID
    /// The point being extended from.
    var activeEnd: OpID
    var end: ContourEnd
}

/// The Pen tool (DRAW-021): click for a corner point, drag for a curve point (the drag pulls out
/// its handles), kbd:[Control]-click for a connector, kbd:[Cmd]-drag moves the point being placed,
/// kbd:[Option]-drag breaks the handle pair, kbd:[Shift] constrains the segment (and the handle) to
/// the constrain angle and every 45° from it.  Double-click, kbd:[Tab] or kbd:[Esc] ends the path;
/// clicking the first point closes it.  Each placed point is one change (the first is grouped with
/// the path's creation, so undoing every point removes the path); a close is one change.
@MainActor
final class PenTool: Tool, PointerTracking, ToolInfoPublishing {
    static let id: ToolID = .pen
    /// A drag shorter than this (view points) places a corner point.
    static let dragThreshold = 2.0
    static let tabKeyCode: UInt16 = 48
    static let statusMessage = "Click for a corner, drag for a curve, Control-click for a connector; click the first point to close"

    /// What a click would do, shown by the cursor.
    enum Intent: Equatable, Sendable {
        case start, add, close
    }

    /// The point being placed between mouse-down and mouse-up.
    struct Placement: Equatable {
        var anchor: Point
        var inHandle: Vector = .zero
        var outHandle: Vector = .zero
        var kind: PointKind
        var closes: Bool
        /// The pointer at mouse-down and at the last event (Cmd-drag moves the anchor by the
        /// difference).
        var press: Point
        var last: Point
        var dragged = false
    }

    private(set) var context: ToolContext?
    private(set) var session: PathBuildingSession?
    private(set) var placement: Placement?
    /// The pointer with no button down (the preview's end and the cursor's intent).
    private(set) var hover: Point?
    /// The commits in flight, chained so each sees the session the one before left.
    private(set) var pending: Task<Void, Never>?

    init() {}

    var cursor: NSCursor { PenCursors.cursor(for: intent) }

    /// The Info toolbar's readout while placing a point: the handle being pulled out.
    var info: ToolInfo {
        guard let placement else { return ToolInfo() }
        return ToolInfo(delta: placement.outHandle)
    }

    var intent: Intent {
        guard session != nil else { return .start }
        if let hover, closesPath(at: hover) { return .close }
        return .add
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        finish()
        context = nil
    }

    /// Ends the session: the path stays as drawn.
    func finish() {
        placement = nil
        session = nil
        hover = nil
        context?.host.toolCursorDidChange()
    }

    /// Extends an existing open path from one end (a Pen session resumed after a tool switch, or
    /// continuing a path, DRAW-023).
    func resume(_ session: PathBuildingSession) {
        self.session = session
        context?.host.toolCursorDidChange()
    }

    /// Waits for every commit in flight (tests).
    func settle() async {
        await pending?.value
    }

    // MARK: Geometry

    /// The path of the session as merged (it may not render yet: one point draws nothing).
    private func contour(_ session: PathBuildingSession) -> VectorContour? {
        guard let document = context?.document, document.state.isLive(session.node), document.state.nodeKind(session.node) == .path else { return nil }
        let state = document.state
        return VectorPath(state.props(session.node).path, node: session.node, state: state).contour(session.contour)
    }

    /// The session's contour with its transform, when the session is still valid.
    private var drawnContour: (contour: VectorContour, transform: WTGeometry.AffineTransform)? {
        guard let session, let document = context?.document, let contour = contour(session), !contour.closed else { return nil }
        return (contour, transform(of: document.state.props(session.node).path.common.transform))
    }

    private func transform(of value: Wiretuner_Doc_V1_Transform) -> WTGeometry.AffineTransform {
        if value.a == 0, value.b == 0, value.c == 0, value.d == 0, value.tx == 0, value.ty == 0 { return .identity }
        return WTGeometry.AffineTransform(a: value.a, b: value.b, c: value.c, d: value.d, tx: value.tx, ty: value.ty)
    }

    /// The active end's anchor, pasteboard space.
    var activeAnchor: Point? {
        guard let session, let (contour, transform) = drawnContour,
              let point = contour.points.first(where: { $0.id == session.activeEnd }) else { return nil }
        return transform.apply(point.anchor)
    }

    /// Whether a click at `point` lands on the other end of the session's contour (and so closes
    /// it).  A start point deleted by someone else is not offered.
    func closesPath(at point: Point) -> Bool {
        guard let session, let context, let (contour, transform) = drawnContour, contour.points.count >= 2 else { return false }
        let drawn = contour.drawn
        guard let other = session.end == .end ? drawn.first : drawn.last, other.id != session.activeEnd else { return false }
        let tolerance = context.snapping.pickDistance() / context.viewport.zoom
        return transform.apply(other.anchor).distance(to: point) <= tolerance
    }

    private func constrained(_ point: Point, from origin: Point?, modifiers: KeyModifiers) -> Point {
        guard modifiers.contains(.shift), let origin, let context else { return point }
        return context.drawing().constraint.constrain(point, from: origin)
    }

    private func snapped(_ point: Point) -> Point {
        guard let context else { return point }
        return context.snapping.snap(point, viewport: context.viewport)
    }

    // MARK: Events

    func pointerMoved(_ e: CanvasEvent) {
        let before = intent
        hover = e.pasteboardPoint
        if intent != before { context?.host.toolCursorDidChange() }
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseDown(_ e: CanvasEvent) {
        if e.clickCount >= 2 {
            finish()
            return
        }
        if session != nil, drawnContour == nil { session = nil }
        let point = constrained(snapped(e.pasteboardPoint), from: activeAnchor, modifiers: e.modifiers)
        let closes = closesPath(at: e.pasteboardPoint)
        placement = Placement(anchor: point, kind: e.modifiers.contains(.control) ? .connector : .corner, closes: closes, press: point, last: point)
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard var placement, let context else { return }
        let pointer = e.pasteboardPoint
        if e.modifiers.contains(.command) {
            placement.anchor = placement.anchor + (pointer - placement.last)
        } else {
            var handle = pointer - placement.anchor
            if e.modifiers.contains(.shift) { handle = context.drawing().constraint.constrain(handle) }
            let dragged = handle.length * context.viewport.zoom >= Self.dragThreshold
            placement.dragged = placement.dragged || dragged
            switch placement.kind {
            case .connector:
                placement.outHandle = handle
            case .corner where e.modifiers.contains(.option) && placement.dragged:
                // Broken pair: only the leaving handle follows.
                placement.outHandle = handle
            case .corner, .curve:
                if placement.dragged {
                    placement.kind = e.modifiers.contains(.option) ? .corner : .curve
                    placement.outHandle = handle
                    if !e.modifiers.contains(.option) { placement.inHandle = -handle }
                }
            }
        }
        placement.last = pointer
        self.placement = placement
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        guard let placement, let context else { return }
        self.placement = nil
        let point = VectorPoint(anchor: placement.anchor, inHandle: placement.inHandle, outHandle: placement.outHandle, kind: placement.kind)
        let previous = pending
        let fillWhenOpen = context.drawing().fillWhenOpen
        pending = Task { @MainActor [weak self] in
            await previous?.value
            await self?.commit(point, closes: placement.closes, fillWhenOpen: fillWhenOpen, sink: context.commandSink, selection: context.selection)
        }
    }

    /// Performs the placement: close, first point (with the path's creation) or another point.
    private func commit(_ point: VectorPoint, closes: Bool, fillWhenOpen: Bool, sink: CommandSink, selection: SelectionController) async {
        if let session, contour(session) == nil { self.session = nil }
        if let session, closes {
            _ = await sink.perform(SetClosed(node: session.node, closed: true, contours: [session.contour])).value
            finish()
            return
        }
        if let session {
            let placement: PointPlacement = session.end == .end ? .after(session.activeEnd) : .before(session.activeEnd)
            let local = localized(point, in: session.node)
            let change = await sink.perform(InsertPoints(node: session.node, contour: session.contour, at: placement, points: [local])).value
            if let id = change?.insertedElements(session.node, PathFields.points(session.contour)).first {
                self.session?.activeEnd = id
                select(session.node, point: id, contour: session.contour, selection: selection)
            }
            return
        }
        let create = CreatePath(label: "Pen", contours: [NewContour(points: [point])], fillWhenOpen: fillWhenOpen)
        guard let change = await sink.perform(create).value, let node = change.createdObjects.first,
              let contour = change.insertedElements(node, PathFields.contours).first,
              let id = change.insertedElements(node, PathFields.points(contour)).first else { return }
        session = PathBuildingSession(node: node, contour: contour, activeEnd: id, end: .end)
        context?.host.toolCursorDidChange()
        select(node, point: id, contour: contour, selection: selection)
    }

    /// `point` (pasteboard space) in the local space of the path `node`.
    private func localized(_ point: VectorPoint, in node: OpID) -> VectorPoint {
        guard let document = context?.document,
              let inverse = transform(of: document.state.props(node).path.common.transform).inverted() else { return point }
        var local = point
        local.anchor = inverse.apply(point.anchor)
        local.inHandle = inverse.apply(point.inHandle)
        local.outHandle = inverse.apply(point.outHandle)
        return local
    }

    private func select(_ node: OpID, point: OpID, contour: OpID, selection: SelectionController) {
        let id = SelectionID(node)
        selection.model.set(Selection([id]).applying([id], sub: [id: .points([PointReference(node: id.node, contour: contour, point: point)])], mode: .add))
    }

    func flagsChanged(_ e: CanvasEvent) {}

    /// Tab ends the path.
    func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == Self.tabKeyCode, session != nil else { return false }
        finish()
        return true
    }

    /// Esc ends the path where it is (same as Tab).
    func cancel() {
        finish()
    }

    // MARK: Overlay

    /// The rubber-band segment from the active end to `end` (with *Pen tool preview* on), and the
    /// handles of the point being placed, pasteboard space.
    var previewSegment: DisplayPath? {
        guard let context, context.drawing().penPreview, let session, let (contour, transform) = drawnContour,
              let from = contour.drawn.first(where: { $0.id == session.activeEnd }) else { return nil }
        let target = placement?.anchor ?? hover
        guard let target else { return nil }
        let start = transform.apply(from.anchor)
        let leaving = transform.apply(session.end == .end ? from.outHandle : from.inHandle)
        var path = DisplayPath()
        path.move(to: start)
        let arriving = placement.map { $0.inHandle } ?? .zero
        if leaving == .zero, arriving == .zero {
            path.addLine(to: target)
        } else {
            path.addCubicCurve(control1: start + leaving, control2: target + arriving, to: target)
        }
        return path
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        let toView = viewport.pasteboardToView
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        if let preview = previewSegment {
            let path = CGMutablePath()
            SelectionOverlay.add(preview, transform: toView, to: path)
            ctx.addPath(path)
            ctx.strokePath()
        }
        guard let placement else { return }
        let anchor = toView.apply(placement.anchor)
        for handle in [placement.inHandle, placement.outHandle] where handle != .zero {
            let end = toView.apply(placement.anchor + handle)
            ctx.move(to: anchor.cgPoint)
            ctx.addLine(to: end.cgPoint)
            ctx.strokePath()
            let r = SelectionOverlay.handleEndRadius
            ctx.strokeEllipse(in: CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r))
        }
    }
}

/// The Pen's cursors (pen-bezigon.adoc, "Cursors"): the pen, with a plus to continue or start, a
/// circle to close.  Drawn from SF Symbols at run time.
@MainActor
enum PenCursors {
    static func cursor(for intent: PenTool.Intent) -> NSCursor {
        switch intent {
        case .start: start
        case .add: add
        case .close: close
        }
    }

    static let start = make(badge: nil)
    static let add = make(badge: "plus")
    static let close = make(badge: "circle")

    /// The pen tip at the hot spot, with an optional badge at the lower right.
    static func make(badge: String?) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: true) { rect in
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            if let pen = NSImage(systemSymbolName: "pencil.tip", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                pen.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            }
            if let badge, let mark = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                mark.draw(in: NSRect(x: rect.maxX - 10, y: rect.maxY - 10, width: 9, height: 9))
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 1, y: 1))
    }
}
