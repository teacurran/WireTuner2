import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// The Pointer and Subselect tools (selecting.adoc, "The selection tools"; moving.adoc; OBJ-005,
/// OBJ-008; editing-paths.adoc, DRAW-025): a click selects the object under the pointer, a drag on
/// nothing draws a marquee, kbd:[Shift] adds or removes, kbd:[Option] subselects (the Subselect
/// tool is this gesture with the flag always set).  A drag that starts on an object moves the
/// selection -- or, when it starts on a selected point, the selected points -- previewed in the
/// overlay and written by one command on mouse-up: kbd:[Shift] constrains the move to the
/// constrain angle and every 45° from it, kbd:[Option] with *Option-drag copies paths* moves a
/// copy, kbd:[Esc] abandons it.  Hit testing is REND-003's through the window's
/// `SelectionController`, so a rotated or zoomed canvas selects the same way.
@MainActor
final class PointerTool: Tool {
    static let id: ToolID = .pointer
    static let subselectID: ToolID = "subselect"
    /// A drag shorter than this (view points) is a click.
    static let dragThreshold = 3.0
    static let statusMessage = "Click to select, drag to move or to select an area; Shift adds or removes, Option subselects"

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == .pointer }!.delivering { PointerTool() }
    }

    static var subselectDescriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == subselectID }!.delivering { PointerTool(subselect: true) }
    }

    /// What the gesture in progress does.
    enum Gesture: Equatable {
        /// A marquee (or a click on nothing).
        case marquee
        /// Moving the selected objects.
        case move
        /// Moving the selected points.
        case movePoints
    }

    let toolID: ToolID
    /// Always subselect (the Subselect tool).
    let alwaysSubselects: Bool
    private var context: ToolContext?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?
    private(set) var gesture: Gesture = .marquee
    /// The press already changed the selection (an unselected object picked), so the release of
    /// a click leaves it alone.
    private var selectedOnPress = false

    init(subselect: Bool = false) {
        alwaysSubselects = subselect
        toolID = subselect ? Self.subselectID : Self.id
    }

    var cursor: NSCursor { .arrow }

    /// Whether the gesture in progress has moved far enough to be a drag.
    var isDragging: Bool {
        guard let start, let current else { return false }
        return current.viewPoint.distance(to: start.viewPoint) >= Self.dragThreshold
    }

    /// Whether the gesture in progress is a marquee drag.
    var isMarquee: Bool { gesture == .marquee && isDragging }

    /// The marquee in view points while dragging.
    var marqueeRect: Rect? {
        guard isMarquee, let start, let current else { return nil }
        return Rect(start.viewPoint, current.viewPoint)
    }

    /// The distance the selection is being moved (pasteboard space), constrained with Shift.
    var moveDelta: Vector? {
        guard gesture != .marquee, isDragging, let start, let current else { return nil }
        let delta = current.pasteboardPoint - start.pasteboardPoint
        guard current.modifiers.contains(.shift), let context else { return delta }
        return context.drawing().constraint.constrain(delta)
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        context = nil
    }

    private func subselects(_ modifiers: KeyModifiers) -> Bool {
        alwaysSubselects || modifiers.contains(.option)
    }

    func mouseDown(_ e: CanvasEvent) {
        start = e
        current = e
        gesture = .marquee
        selectedOnPress = false
        guard let context, let (id, sub) = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: subselects(e.modifiers)) else { return }
        let selection = context.selection.selection
        if case let .points(points)? = sub {
            if case let .points(selected)? = selection.subSelection(of: id), selected.isSuperset(of: points) {
                gesture = .movePoints
                return
            }
            if !e.modifiers.contains(.shift) {
                context.selection.click(at: e.viewPoint, viewport: context.viewport, modifiers: e.modifiers, subselect: true)
                selectedOnPress = true
                gesture = .movePoints
            }
            return
        }
        if !selection.contains(id) {
            context.selection.click(at: e.viewPoint, viewport: context.viewport, modifiers: e.modifiers, subselect: subselects(e.modifiers))
            selectedOnPress = true
        }
        gesture = context.selection.selection.contains(id) ? .move : .marquee
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard start != nil else { return }
        current = e
    }

    func mouseUp(_ e: CanvasEvent) {
        defer { cancel() }
        guard let context, let start else { return }
        current = e
        let subselect = subselects(e.modifiers)
        switch gesture {
        case .move, .movePoints:
            if let delta = moveDelta {
                commitMove(delta, copy: e.modifiers.contains(.option) && context.optionDragCopies() && gesture == .move)
            } else if !selectedOnPress {
                context.selection.click(at: start.viewPoint, viewport: context.viewport, modifiers: e.modifiers, subselect: subselect)
            }
        case .marquee:
            if let rect = marqueeRect {
                context.selection.marquee(rect, viewport: context.viewport, modifiers: e.modifiers, subselect: subselect)
            } else if !selectedOnPress {
                context.selection.click(at: start.viewPoint, viewport: context.viewport, modifiers: e.modifiers, subselect: subselect)
            }
        }
    }

    /// The command a move by `delta` performs: the selected points (one `MovePoints` per path),
    /// a moved copy, or `MoveObjects`.
    func moveCommand(_ delta: Vector, copy: Bool) -> (any WTModel.Command)? {
        guard let context else { return nil }
        if gesture == .movePoints {
            return ObjectEditing.moveCommand(delta, selection: context.selection.selection, document: context.document)
        }
        let nodes = context.selection.selection.ids.map(\.opID)
        guard !nodes.isEmpty else { return nil }
        return copy ? DuplicateObjects(nodes, offset: .translation(delta), label: "Copy") : MoveObjects(nodes, by: delta)
    }

    private func commitMove(_ delta: Vector, copy: Bool) {
        guard let context, let command = moveCommand(delta, copy: copy) else { return }
        let task = context.commandSink.perform(command)
        guard copy else { return }
        let model = context.selection.model
        Task { @MainActor in
            guard let created = await task.value?.createdRoots, !created.isEmpty else { return }
            model.set(Selection(created.map { SelectionID($0) }))
        }
    }

    /// Shift or Option pressed mid-drag changes what the release does.
    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    /// A Force click subselects the member under the pointer, as Option-click does
    /// (document-view.adoc, "Trackpad, mouse and tablet gestures").
    func forceClick(_ e: CanvasEvent) {
        guard let context else { return }
        cancel()
        context.selection.click(at: e.viewPoint, viewport: context.viewport, modifiers: e.modifiers.union(.option), subselect: true)
    }

    /// The outlines the move previews, pasteboard space: each selected object moved by the
    /// delta (a group by its bounds), or each path with its selected points moved.
    var movePreview: [DisplayPath] {
        guard let delta = moveDelta, let context else { return [] }
        let document = context.document
        let selection = context.selection.selection
        return selection.ids.compactMap { id -> DisplayPath? in
            guard let object = document.object(for: id) else { return nil }
            guard var path = object.path else {
                return object.bounds.map { DisplayPath(rect: $0.applying(.translation(delta))) }
            }
            var transform = object.transform
            if gesture == .movePoints {
                guard case let .points(points)? = selection.subSelection(of: id), let inverse = object.transform.inverted() else { return nil }
                let local = inverse.apply(delta)
                for (c, contour) in path.contours.enumerated() {
                    for (p, point) in contour.points.enumerated() where points.contains(PointReference(node: id.node, contour: contour.id, point: point.id)) {
                        path.contours[c].points[p].anchor = point.anchor + local
                    }
                }
            } else {
                transform = transform.concatenating(.translation(delta))
            }
            return DocumentDisplayListBuilder.display(path) { _ in true }.path.applying(transform)
        }
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        if let rect = marqueeRect {
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(rect.cgRect)
            return
        }
        let preview = movePreview
        guard !preview.isEmpty else { return }
        let path = CGMutablePath()
        for outline in preview { SelectionOverlay.add(outline, transform: viewport.pasteboardToView, to: path) }
        ctx.addPath(path)
        ctx.strokePath()
    }

    func cancel() {
        start = nil
        current = nil
        gesture = .marquee
        selectedOnPress = false
    }
}
