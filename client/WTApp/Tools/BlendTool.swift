import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Blend tool (blends.adoc, "Using the Blend tool"; FX-027): a drag from one object to another
/// blends them, previewing the steps as it goes; a drag from a blend (one of its key objects) to
/// another object adds that object as the last key object; kbd:[Option]-dragging from a blend
/// onto a path joins the blend to it; dragging a selected blend's blend point -- the large circle
/// on each key object -- to another point of the same object moves where the steps start.  Over an
/// object the gesture cannot use the cursor refuses and nothing is written.  Every gesture is one
/// change and one undo step.
@MainActor
final class BlendTool: Tool {
    static let id: ToolID = "blend"
    static let dragThreshold = 3.0
    /// The blend points' circles, view points.
    static let pointRadius = 7.0
    /// Steps the rubber band previews.
    static let previewSteps = 6
    static let statusMessage = "Drag from one object to another to blend them; Option-drag from a blend onto a path to join them"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { BlendTool() }
    }

    /// A key object's blend point.
    struct BlendPointHandle: Equatable {
        var blend: OpID
        var object: OpID
        /// Pasteboard space.
        var position: Point
    }

    enum Gesture: Equatable {
        /// From object `from` to another: a new blend.
        case create(from: OpID)
        /// From blend `blend` to another object: added at the end.
        case add(blend: OpID)
        /// kbd:[Option] from blend `blend` onto a path.
        case join(blend: OpID)
        /// Dragging a blend point.
        case point(BlendPointHandle)
    }

    private var context: ToolContext?
    private(set) var gesture: Gesture?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?
    /// The object under the pointer the gesture would use, and whether it refuses.
    private(set) var target: OpID?
    private(set) var refusal: String?

    init() {}

    var cursor: NSCursor { refusal != nil ? .operationNotAllowed : .crosshair }
    var hasSomethingToCancel: Bool { gesture != nil }

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
        context = nil
    }

    // MARK: Reading the canvas

    /// The top-level object under `e`.
    func object(at e: CanvasEvent) -> OpID? {
        guard let context else { return nil }
        return context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: false)?.id.opID
    }

    /// The blend points of every selected blend.
    var blendPoints: [BlendPointHandle] {
        guard let context else { return [] }
        let document = context.document
        let state = document.state
        return context.selection.selection.ids.map(\.opID).filter { state.nodeKind($0) == .blend }.flatMap { blend in
            Self.blendPoints(blend, in: document)
        }
    }

    /// Each key object's blend point: the chosen point, else the start of its first contour.
    static func blendPoints(_ blend: OpID, in document: DocumentHandle) -> [BlendPointHandle] {
        let state = document.state
        var chosen: [OpID: (contour: OpID, point: OpID)] = [:]
        for entry in BlendReading.points(state.props(blend).blend) { chosen[entry.object] = entry.point }
        return BlendReading.keyObjects(blend, in: state).compactMap { key in
            guard let object = document.object(for: SelectionID(key)), let path = object.path else { return nil }
            let point = chosen[key].flatMap { choice in path.contour(choice.contour)?.drawn.first { $0.id == choice.point } }
                ?? path.contours.first(where: { !$0.drawn.isEmpty })?.drawn.first
            return point.map { BlendPointHandle(blend: blend, object: key, position: object.transform.apply($0.anchor)) }
        }
    }

    /// The point of `object`'s outline nearest `pasteboard`, as a blend point choice and its
    /// position.
    static func nearestPoint(of object: OpID, to pasteboard: Point, in document: DocumentHandle) -> (choice: BlendPointChoice, position: Point)? {
        guard let scene = document.object(for: SelectionID(object)), let path = scene.path else { return nil }
        var best: (choice: BlendPointChoice, position: Point)?
        for contour in path.contours {
            for point in contour.drawn {
                let position = scene.transform.apply(point.anchor)
                if best.map({ position.distance(to: pasteboard) < $0.position.distance(to: pasteboard) }) ?? true {
                    best = (BlendPointChoice(contour: contour.id, point: point.id), position)
                }
            }
        }
        return best
    }

    /// Why the gesture cannot use `target`, or nil when it can.
    func refusal(for gesture: Gesture, target: OpID?) -> String? {
        guard let context, let target else { return nil }
        let state = context.document.state
        switch gesture {
        case .create(let from):
            return from == target ? nil : BlendEligibility.refusal(Objects.stackingOrder([from, target], in: state), in: state)
        case .add(let blend):
            guard target != blend, let last = BlendReading.keyObjects(blend, in: state).last else { return nil }
            return BlendEligibility.refusal([last, target], in: state)
        case .join(let blend):
            return target == blend || state.nodeKind(target) == .path ? nil : "Option-drag onto a path to join the blend to it."
        case .point:
            return nil
        }
    }

    // MARK: Events

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        start = e
        current = e
        if let handle = blendPoints.first(where: { context.viewport.toView($0.position).distance(to: e.viewPoint) <= Self.pointRadius }) {
            gesture = .point(handle)
            return
        }
        guard let hit = object(at: e) else { return }
        if context.document.state.nodeKind(hit) == .blend {
            gesture = e.modifiers.contains(.option) ? .join(blend: hit) : .add(blend: hit)
        } else {
            gesture = .create(from: hit)
        }
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard let gesture else { return }
        let before = refusal
        current = e
        if case .point = gesture {
            target = nil
        } else {
            target = object(at: e)
        }
        refusal = refusal(for: gesture, target: target)
        if (before != nil) != (refusal != nil) { context?.host.toolCursorDidChange() }
    }

    func mouseUp(_ e: CanvasEvent) {
        mouseDragged(e)
        defer { cancel() }
        guard let context, isDragging, let command = command(releasedAt: e) else {
            if let context, let start, !isDragging {
                context.selection.click(at: start.viewPoint, viewport: context.viewport, modifiers: e.modifiers, subselect: false)
            }
            if let refusal { context?.host.showStatusMessage(refusal) }
            return
        }
        let task = context.commandSink.perform(command)
        guard case .create = gesture else { return }
        let selection = context.selection
        Task { @MainActor in
            guard let created = await task.value?.createdObjects.first else { return }
            selection.model.set(Selection([SelectionID(created)]))
        }
    }

    /// The one command the drag released at `e` performs; nil when the target refuses or there is
    /// none.
    func command(releasedAt e: CanvasEvent) -> (any WTModel.Command)? {
        guard let context, let gesture, refusal == nil else { return nil }
        switch gesture {
        case .create(let from):
            guard let target, target != from else { return nil }
            return Blend(Objects.stackingOrder([from, target], in: context.document.state), layer: context.objectEditing?.activeLayer)
        case .add(let blend):
            guard let target, target != blend else { return nil }
            return AddToBlend(blend, target)
        case .join(let blend):
            guard let target, target != blend else { return nil }
            return JoinBlendToPath(blend, path: target)
        case .point(let handle):
            guard let nearest = Self.nearestPoint(of: handle.object, to: e.pasteboardPoint, in: context.document) else { return nil }
            return SetBlendPoint(handle.blend, object: handle.object, choice: nearest.choice)
        }
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    func cancel() {
        let refused = refusal != nil
        gesture = nil
        start = nil
        current = nil
        target = nil
        refusal = nil
        if refused { context?.host.toolCursorDidChange() }
    }

    // MARK: Overlay

    /// The rubber band's preview: the two objects blended with a few steps, as the blend would
    /// draw them.
    func preview() -> DisplayItem? {
        guard let context, isDragging, refusal == nil, case .create(let from)? = gesture, let target, target != from else { return nil }
        let document = context.document
        let ordered = Objects.stackingOrder([from, target], in: document.state)
        let items = ordered.compactMap { document.item(for: SelectionID($0)) }
        guard items.count == 2 else { return nil }
        return .group(GroupItem(children: items, live: .blend(BlendSpec(steps: Self.previewSteps, rangeLast: 100))))
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        let accent = (refusal == nil ? NSColor.controlAccentColor : NSColor.systemRed).cgColor
        ctx.setStrokeColor(accent)
        ctx.setFillColor(accent)
        ctx.setLineWidth(1)
        if let preview = preview() {
            ctx.saveGState()
            ctx.setAlpha(0.5)
            CoreGraphicsRenderer(background: nil).render(DisplayList(canvas: "blend-preview", items: [preview]), viewport: viewport, into: ctx)
            ctx.restoreGState()
        }
        if let start, let current, isDragging {
            if case .point = gesture {} else {
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.strokeLineSegments(between: [start.viewPoint.cgPoint, current.viewPoint.cgPoint])
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        for handle in blendPoints {
            var position = handle.position
            if case .point(let dragged)? = gesture, dragged == handle, let current, let context,
               let nearest = Self.nearestPoint(of: handle.object, to: current.pasteboardPoint, in: context.document) {
                position = nearest.position
            }
            CanvasHandleLayers.drawHandle(viewport.toView(position), size: 2 * Self.pointRadius, hollow: true, in: ctx)
        }
    }
}
