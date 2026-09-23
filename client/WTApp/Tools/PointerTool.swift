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
///
/// Double-clicking the selection shows the transform handles (transforming.adoc, "Transform
/// handles"; OBJ-034) when *Double-click enables transform handles* is on: inside moves, the
/// centre circle moves the centre (kbd:[Shift]-click puts it back), a handle scales, just outside a
/// corner rotates, the dotted edge skews; kbd:[Shift] constrains, kbd:[Option] transforms a copy,
/// and each drag is one change.  kbd:[~] goes up to the enclosing group keeping the centre;
/// kbd:[Esc] or a double-click away puts the handles away.
@MainActor
final class PointerTool: Tool, PointerTracking {
    static let id: ToolID = .pointer
    static let subselectID: ToolID = "subselect"
    /// A drag shorter than this (view points) is a click.
    static let dragThreshold = 3.0
    static let statusMessage = "Click to select, drag to move or to select an area; Shift adds or removes, Option subselects"
    static let handlesMessage = "Drag a handle to scale, outside a corner to rotate, an edge to skew; Option copies, Esc puts the handles away"

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
        /// Dragging a zone of the transform handles.
        case handles(TransformHandles.Zone)
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
    /// The transform handles, while shown: the centre the user set (nil: the bounds' centre) and
    /// the selection they belong to.
    private(set) var handlesShown = false
    private(set) var handleCenter: Point?
    private var handleSelection: [SelectionID] = []
    /// The zone under the pointer (the cursor).
    private(set) var hoverZone: TransformHandles.Zone?
    private var hoverCopies = false

    init(subselect: Bool = false) {
        alwaysSubselects = subselect
        toolID = subselect ? Self.subselectID : Self.id
    }

    var cursor: NSCursor { handlesShown ? TransformHandles.cursor(hoverZone, copying: hoverCopies) : .arrow }

    var hasSomethingToCancel: Bool { start != nil || handlesShown }

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
        guard gesture == .move || gesture == .movePoints, isDragging, let start, let current else { return nil }
        let delta = current.pasteboardPoint - start.pasteboardPoint
        guard current.modifiers.contains(.shift), let context else { return delta }
        return context.drawing().constraint.constrain(delta)
    }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        hideHandles()
        cancel()
        context = nil
    }

    private func subselects(_ modifiers: KeyModifiers) -> Bool {
        alwaysSubselects || modifiers.contains(.option)
    }

    // MARK: Transform handles

    /// The handles for the current selection, while shown (nil when the selection went away).
    var handles: TransformHandles? {
        guard handlesShown, let context, let bounds = TransformHandles.bounds(of: context.selection.selection, document: context.document) else { return nil }
        return TransformHandles(bounds: bounds, center: handleCenter)
    }

    /// Shows the handles around the selection (a double-click on it).
    func showHandles() {
        guard let context, !context.selection.selection.isEmpty else { return }
        handlesShown = true
        handleCenter = nil
        handleSelection = context.selection.selection.ids
        context.host.showStatusMessage(Self.handlesMessage)
        context.host.setNeedsOverlayDisplay()
    }

    /// Puts the handles away (kbd:[Esc], a double-click away, another tool).
    func hideHandles() {
        guard handlesShown else { return }
        handlesShown = false
        handleCenter = nil
        hoverZone = nil
        context?.host.showStatusMessage(Self.statusMessage)
        context?.host.setNeedsOverlayDisplay()
        context?.host.toolCursorDidChange()
    }

    /// The selection changed under the handles (a click elsewhere): they follow it, and the
    /// centre returns to its bounds' centre; an empty selection puts them away.
    private func followSelection() {
        guard handlesShown, let context else { return }
        let ids = context.selection.selection.ids
        guard ids != handleSelection else { return }
        if ids.isEmpty {
            hideHandles()
        } else {
            handleSelection = ids
            handleCenter = nil
        }
    }

    /// kbd:[~]: the handles go up to the group enclosing the selection, keeping the centre.
    func superselect() {
        guard let context, handlesShown else { return }
        let parents = context.selection.selection.ids.compactMap { context.document.object(for: $0)?.parent }
            .filter { context.document.object(for: SelectionID($0))?.kind == .group }
        guard let parent = parents.first else { return }
        let center = handles?.center
        context.selection.model.set(Selection([SelectionID(parent)]))
        handleSelection = [SelectionID(parent)]
        handleCenter = center
        context.host.setNeedsOverlayDisplay()
    }

    func pointerMoved(_ e: CanvasEvent) {
        guard handlesShown, let context else { return }
        let zone = handles?.zone(at: e.viewPoint, viewport: context.viewport)
        let copies = e.modifiers.contains(.option)
        guard zone != hoverZone || copies != hoverCopies else { return }
        hoverZone = zone
        hoverCopies = copies
        context.host.toolCursorDidChange()
    }

    // MARK: Events

    func mouseDown(_ e: CanvasEvent) {
        start = e
        current = e
        gesture = .marquee
        selectedOnPress = false
        guard let context else { return }
        followSelection()
        if let handles, let zone = handles.zone(at: e.viewPoint, viewport: context.viewport) {
            if zone == .center, e.modifiers.contains(.shift) {
                handleCenter = nil
                context.host.setNeedsOverlayDisplay()
            }
            gesture = .handles(zone)
            return
        }
        if e.clickCount >= 2 {
            // The object, or the member of it already selected by an Option-click.
            let hit = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: false)
            let member = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: true)
            let onSelection = [hit?.id, member?.id].contains { $0.map(context.selection.selection.contains) == true }
            if onSelection, context.transformHandles() {
                showHandles()
                cancel()
                return
            }
            if hit == nil, handlesShown {
                hideHandles()
                cancel()
                return
            }
        }
        guard let (id, sub) = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: subselects(e.modifiers)) else { return }
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
        defer {
            resetGesture()
            followSelection()
        }
        guard let context, let start else { return }
        current = e
        let subselect = subselects(e.modifiers)
        switch gesture {
        case .handles(let zone):
            finishHandles(zone, start: start, end: e, context: context)
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

    /// The end of a drag on the handles: the centre moves, or one transformation is performed; a
    /// click inside (no drag) selects as a click would -- kbd:[Option] picks a group's member, and
    /// the handles then belong to it.
    private func finishHandles(_ zone: TransformHandles.Zone, start: CanvasEvent, end: CanvasEvent, context: ToolContext) {
        guard isDragging else {
            if zone == .move {
                context.selection.click(at: start.viewPoint, viewport: context.viewport, modifiers: end.modifiers, subselect: subselects(end.modifiers))
                followSelection()
            }
            return
        }
        guard let handles else { return }
        if zone == .center {
            handleCenter = end.pasteboardPoint
            context.host.setNeedsOverlayDisplay()
            return
        }
        guard let command = handleCommand(zone, handles: handles, end: end) else { return }
        let copy = end.modifiers.contains(.option)
        if case .move = zone, let center = handleCenter, let delta = handleMatrix(zone, handles: handles, end: end) {
            handleCenter = delta.apply(center)
        }
        let task = context.commandSink.perform(command)
        guard copy else { return }
        let model = context.selection.model
        Task { @MainActor [weak self] in
            guard let created = await task.value?.createdRoots, !created.isEmpty else { return }
            model.set(Selection(created.map { SelectionID($0) }))
            self?.handleSelection = model.ids
        }
    }

    /// The matrix of the handle drag so far (about the origin).
    func handleMatrix(_ zone: TransformHandles.Zone, handles: TransformHandles, end: CanvasEvent) -> WTGeometry.AffineTransform? {
        guard let start, let context else { return nil }
        return handles.matrix(zone, from: start.pasteboardPoint, to: end.pasteboardPoint, constrained: end.modifiers.contains(.shift),
                              constraint: context.drawing().constraint)
    }

    /// The command the handle drag performs on release.
    func handleCommand(_ zone: TransformHandles.Zone, handles: TransformHandles, end: CanvasEvent) -> (any WTModel.Command)? {
        guard let context, let matrix = handleMatrix(zone, handles: handles, end: end) else { return nil }
        return TransformHandles.command(zone, matrix: matrix, about: handles.center, selection: context.selection.selection,
                                        copy: end.modifiers.contains(.option))
    }

    /// The command a move by `delta` performs: the selected points (one `MovePoints` per path),
    /// a moved copy, or `MoveObjects`.
    func moveCommand(_ delta: Vector, copy: Bool) -> (any WTModel.Command)? {
        guard let context else { return nil }
        if gesture == .movePoints {
            return ObjectEditing.moveCommand(delta, selection: context.selection.selection, document: context.document)
        }
        let nodes = context.selection.selection.ids.map(\.opID)
        // A connector follows the objects it joins and cannot be dragged on its own
        // (connectors.adoc): a selection of connectors alone neither moves nor copies.
        let movable = nodes.filter { context.document.state.nodeKind($0) != .connector }
        guard !movable.isEmpty else { return nil }
        return copy ? DuplicateObjects(nodes, offset: .translation(delta), label: "Copy") : MoveObjects(movable, by: delta)
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
        if handlesShown, e.modifiers.contains(.option) != hoverCopies {
            hoverCopies = e.modifiers.contains(.option)
            context?.host.toolCursorDidChange()
        }
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    /// kbd:[~] (or kbd:[`]) goes up a group while the handles are shown.
    func keyDown(_ e: NSEvent) -> Bool {
        guard handlesShown, let characters = e.charactersIgnoringModifiers, characters == "`" || characters == "~" else { return false }
        superselect()
        return true
    }

    /// A Force click subselects the member under the pointer, as Option-click does
    /// (document-view.adoc, "Trackpad, mouse and tablet gestures").
    func forceClick(_ e: CanvasEvent) {
        guard let context else { return }
        resetGesture()
        context.selection.click(at: e.viewPoint, viewport: context.viewport, modifiers: e.modifiers.union(.option), subselect: true)
    }

    /// The outlines the move previews, pasteboard space: each selected object moved by the
    /// delta (a group by its bounds), or each path with its selected points moved.
    var movePreview: [DisplayPath] {
        guard let delta = moveDelta, let context else { return [] }
        let document = context.document
        let selection = context.selection.selection
        return selection.ids.compactMap { id -> DisplayPath? in
            guard let object = document.object(for: id), object.kind != .connector else { return nil }
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

    /// The outlines a handle drag previews: the selected objects transformed (pasteboard space).
    var handlePreview: [DisplayPath] {
        guard case .handles(let zone) = gesture, zone != .center, isDragging, let context, let handles, let current,
              let matrix = handleMatrix(zone, handles: handles, end: current) else { return [] }
        let kind = TransformHandles.kind(zone)
        let m = TransformObjects([], matrix: matrix, about: kind == .move ? nil : handles.center, kind: kind).effectiveMatrix
        return context.selection.selection.ids.compactMap { id in
            guard let object = context.document.object(for: id) else { return nil }
            guard let path = object.path else { return object.bounds.map { DisplayPath(rect: $0).applying(m) } }
            return DocumentDisplayListBuilder.display(path) { _ in true }.path.applying(object.transform.concatenating(m))
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
        if let handles {
            var shown = handles
            if case .handles(.center) = gesture, isDragging, let current { shown.center = current.pasteboardPoint }
            shown.draw(in: ctx, viewport: viewport, color: NSColor.controlAccentColor.cgColor)
        }
        let preview = movePreview + handlePreview
        guard !preview.isEmpty else { return }
        let path = CGMutablePath()
        for outline in preview { SelectionOverlay.add(outline, transform: viewport.pasteboardToView, to: path) }
        ctx.addPath(path)
        ctx.strokePath()
    }

    /// kbd:[Esc]: abandons the gesture in progress; with none, puts the handles away.
    func cancel() {
        if start == nil { hideHandles() }
        resetGesture()
    }

    private func resetGesture() {
        start = nil
        current = nil
        gesture = .marquee
        selectedOnPress = false
    }
}
