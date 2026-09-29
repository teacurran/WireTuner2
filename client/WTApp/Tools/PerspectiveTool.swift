import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Perspective tool (perspective.adoc, "Attaching objects to the grid", "To reshape the grid on
/// the canvas"; FX-044, with FX-043's grid handles).  Press on an object that is not on the grid
/// and drag: an arrow key picks the plane (one-point grids: kbd:[Left]/kbd:[Right] the wall,
/// kbd:[Up]/kbd:[Down] the floor; two and three points: kbd:[Left] the left wall, kbd:[Right] the
/// right, kbd:[Up] the floor to the right vanishing point, kbd:[Down] to the left) and the release
/// attaches it there, under the pointer where it was grabbed; released without a plane it moves
/// flat.  Press on an attached object: the drag slides it on its plane (kbd:[Shift]: whole cells),
/// kbd:[Space] flips it (the tool takes Space mid-press through `SpaceDragging`, so the temporary
/// Hand does not), kbd:[1]–kbd:[6] shrink and grow it by a cell, all written on release as one
/// change.  With the grid shown, drag a vanishing point, the horizon, a wall's edge line or the
/// floor's front edge to reshape the page's grid -- the built-in grid too, which the same change
/// defines (`ReshapePageGrid`) -- with the reshaped grid drawn as it goes (kbd:[Option+Shift]: the
/// attached objects leave copies where they were; kbd:[Option]: a copy of the grid ("Grid 2")
/// becomes the page's grid); double-click a vanishing point or the horizon to hide or show its
/// plane.  Pointing at a live line shows the arrow badge beside the pointer, highlights the line
/// and says in the status line what a drag does; kbd:[Cmd+Option]-double-click on attached text
/// opens it in the Text Editor.
@MainActor
final class PerspectiveTool: Tool, PointerTracking, SpaceDragging {
    static let id: ToolID = "perspective"
    static let statusMessage = "Drag an object and, holding the mouse button, press an arrow key to attach it; drag the grid's lines to reshape the grid"
    /// How near (view points) a vanishing point or a line a press takes it.
    static let pickRadius = 6.0

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { PerspectiveTool() }
    }

    /// Whether the window showing `document` shows the grid (set by `PerspectiveFeatures`).
    static var showsGrid: @MainActor (DocumentHandle) -> Bool = { _ in false }

    /// What the press took.
    enum Gesture: Equatable {
        /// An object not on the grid (its painted bounds); the plane an arrow key chose and
        /// whether kbd:[Space] flipped it.
        case attach(OpID, bounds: Rect, plane: Wiretuner_Doc_V1_PerspectivePlane?, flip: Bool)
        /// An attached object (its wrapper): the flip and cell resizes pressed so far.
        case move(OpID, flip: Bool, width: Int, height: Int)
        /// A vanishing point of the page's grid (nil: the built-in grid).
        case vanishingPoint(grid: OpID?, page: Page, field: PerspectiveFields.GridField)
        /// The horizon of the page's grid.
        case horizon(grid: OpID?, page: Page)
        /// A wall's near edge (`leftWallX`, `rightWallX`) or the floor's front edge (`floorFrontY`).
        case edge(grid: OpID?, page: Page, field: PerspectiveFields.GridField)
    }

    /// Opens attached text in the Text Editor (replaceable in tests).
    static var editText: @MainActor (OpID, ToolContext) -> Void = { node, context in
        guard let window = (context.host as? NSView)?.window?.windowController as? DocumentWindowController else { return }
        TextEditorFeatures.shared.show(node, in: window)
    }

    /// The pointer over a live grid line: the arrow with a small arrow badge beside it.
    static let badgeCursor: NSCursor = {
        let arrow = NSCursor.arrow
        let base = arrow.image
        let size = NSSize(width: base.size.width + 10, height: base.size.height + 6)
        let image = NSImage(size: size, flipped: true) { _ in
            base.draw(in: NSRect(origin: .zero, size: base.size))
            let badge = NSBezierPath()
            let x = base.size.width - 2, y = base.size.height - 4
            badge.move(to: NSPoint(x: x, y: y))
            badge.line(to: NSPoint(x: x + 9, y: y + 4))
            badge.line(to: NSPoint(x: x + 3, y: y + 9))
            badge.close()
            NSColor.black.setFill()
            badge.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: arrow.hotSpot)
    }()

    /// The live grid line under the pointer while no button is down.
    private(set) var hovered: Gesture?
    /// Whether the pointer is over a live grid line.
    var overHandle: Bool { hovered != nil }

    private var context: ToolContext?
    private(set) var gesture: Gesture?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?

    init() {}

    var cursor: NSCursor { overHandle || gesture?.isHandle == true ? Self.badgeCursor : .crosshair }
    var hasSomethingToCancel: Bool { gesture != nil }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
        hovered = nil
        context = nil
    }

    // MARK: Reading

    /// The page under `point`, and its grid drawing.
    static func grid(at point: Point, document: DocumentHandle) -> (page: Page, drawing: PerspectiveGridDrawing) {
        let page = document.pageList.page(containing: point) ?? document.activePage
        return (page, PerspectiveGridDrawing(page: page, state: document.state))
    }

    /// The plane an arrow key (key code) picks on a grid of `points` vanishing points.
    static func plane(keyCode: UInt16, vanishingPoints: Int) -> Wiretuner_Doc_V1_PerspectivePlane? {
        let onePoint = vanishingPoints == 1
        switch keyCode {
        case 123: return onePoint ? .wall : .leftWall
        case 124: return onePoint ? .wall : .rightWall
        case 126: return onePoint ? .floor : .floorRight
        case 125: return onePoint ? .floor : .floorLeft
        default: return nil
        }
    }

    /// The projector's name for a stored plane.
    static func plane(_ plane: Wiretuner_Doc_V1_PerspectivePlane) -> PerspectiveSpec.Plane {
        switch plane {
        case .rightWall: .rightWall
        case .floorLeft: .floorLeft
        case .floorRight: .floorRight
        case .wall: .wall
        case .floor: .floor
        default: .leftWall
        }
    }

    /// A plane as the status line names it.
    static func name(_ plane: Wiretuner_Doc_V1_PerspectivePlane) -> String {
        switch plane {
        case .rightWall: "the right wall"
        case .floorLeft: "the floor (left vanishing point)"
        case .floorRight: "the floor (right vanishing point)"
        case .wall: "the wall"
        case .floor: "the floor"
        default: "the left wall"
        }
    }

    /// What the status line says while an object off the grid is pressed.
    static func pickHint(vanishingPoints: Int) -> String {
        vanishingPoints == 1
            ? "Press an arrow key to attach: ← or → the wall, ↑ or ↓ the floor; release without one to move it flat"
            : "Press an arrow key to attach: ← left wall, → right wall, ↑ floor (right), ↓ floor (left); release without one to move it flat"
    }

    static let moveHint = "Drag to slide it on the grid (Shift: whole cells); Space flips it; 1–6 shrink and grow it"

    /// What the status line says with the pointer over (or dragging) `handle`.
    static func hint(_ handle: Gesture) -> String {
        switch handle {
        case .vanishingPoint(_, _, .verticalVP): "Drag to move the vertical vanishing point"
        case .vanishingPoint: "Drag to move the vanishing point; double-click to hide or show its wall; Option-drag makes a new grid"
        case .horizon: "Drag to move the horizon; double-click to hide or show the floor; Option-drag makes a new grid"
        case .edge(_, _, .floorFrontY): "Drag to move the floor's front edge"
        case .edge: "Drag to move the wall"
        default: statusMessage
        }
    }

    /// What a press at `e` takes: a vanishing point, else an unlocked object, else a line (the
    /// horizon, a wall's edge, the floor's front edge) -- so an object lying on a grid line can
    /// still be grabbed, and the line elsewhere along its length.
    func handleTakingPress(at e: CanvasEvent, context: ToolContext) -> (gesture: Gesture, drawing: PerspectiveGridDrawing)? {
        guard let hit = hit(at: e, context: context) else { return nil }
        if case .vanishingPoint = hit.gesture { return hit }
        return pickObject(at: e, context: context) == nil ? hit : nil
    }

    /// The unlocked object under `e`, with its painted bounds.
    func pickObject(at e: CanvasEvent, context: ToolContext) -> (id: SelectionID, bounds: Rect)? {
        guard let (id, _) = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: false),
              let object = context.document.object(for: id), let bounds = object.bounds, !object.isEffectivelyLocked else { return nil }
        return (id, bounds)
    }

    /// The live line under `e` -- a vanishing point, the horizon, a wall's edge or the floor's front
    /// edge, in that order -- with the page's grid drawing; nil off every line or with the grid
    /// hidden.  The built-in grid's lines are live too (their gesture's grid is nil).
    func hit(at e: CanvasEvent, context: ToolContext) -> (gesture: Gesture, drawing: PerspectiveGridDrawing)? {
        guard Self.showsGrid(context.document) else { return nil }
        let (page, drawing) = Self.grid(at: e.pasteboardPoint, document: context.document)
        let viewport = context.viewport
        let nearPoint = drawing.vanishingPoints.first { viewport.toView($0.point).distance(to: e.viewPoint) <= Self.pickRadius }
        let onHorizon = abs(viewport.toView(Point(x: e.pasteboardPoint.x, y: drawing.spec.horizonY)).y - e.viewPoint.y) <= Self.pickRadius
        let edge = nearPoint == nil && !onHorizon ? drawing.edge(near: e.viewPoint, viewport: viewport, radius: Self.pickRadius) : nil
        let grid = drawing.grid
        if let nearPoint { return (.vanishingPoint(grid: grid, page: page, field: nearPoint.field), drawing) }
        if let edge { return (.edge(grid: grid, page: page, field: edge), drawing) }
        if onHorizon { return (.horizon(grid: grid, page: page), drawing) }
        return nil
    }

    /// Hovering: the arrow badge, the highlight and the hint over a live line.
    func pointerMoved(_ e: CanvasEvent) {
        guard let context else { return }
        let over = handleTakingPress(at: e, context: context)?.gesture
        guard over != hovered else { return }
        let was = hovered
        hovered = over
        if was == nil || over == nil { context.host.toolCursorDidChange() }
        context.host.showStatusMessage(over.map(Self.hint) ?? Self.statusMessage)
        context.host.setNeedsOverlayDisplay()
    }

    /// kbd:[Cmd+Option]-double-click on attached text: the Text Editor on it.
    @discardableResult
    func editAttachedText(at e: CanvasEvent, context: ToolContext) -> Bool {
        guard e.clickCount >= 2, e.modifiers.isSuperset(of: [.command, .option]),
              let (id, _) = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: false) else { return false }
        let state = context.document.state
        guard let wrapper = PerspectiveReading.wrapper(of: id.opID, in: state),
              let text = state.liveChildren(wrapper).first(where: { state.nodeKind($0) == .text }) else { return false }
        Self.editText(text, context)
        return true
    }

    // MARK: Events

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        start = e
        current = e
        hovered = nil
        if editAttachedText(at: e, context: context) {
            resetGesture()
            return
        }
        if let (handle, drawing) = handleTakingPress(at: e, context: context) {
            if e.clickCount >= 2 {
                if let command = Self.toggle(handle, drawing: drawing) { context.commandSink.perform(command) }
                resetGesture()
                return
            }
            gesture = handle
            context.host.showStatusMessage(Self.hint(handle))
            return
        }
        guard let (id, bounds) = pickObject(at: e, context: context) else {
            resetGesture()
            return
        }
        let state = context.document.state
        context.selection.model.set(Selection([id]))
        if let wrapper = PerspectiveReading.wrapper(of: id.opID, in: state) {
            gesture = .move(wrapper, flip: false, width: 0, height: 0)
            context.host.showStatusMessage(Self.moveHint)
        } else {
            gesture = .attach(id.opID, bounds: bounds, plane: nil, flip: false)
            let (_, drawing) = Self.grid(at: e.pasteboardPoint, document: context.document)
            context.host.showStatusMessage(Self.pickHint(vanishingPoints: drawing.spec.effectiveVanishingPoints))
        }
    }

    func mouseDragged(_ e: CanvasEvent) {
        guard gesture != nil else { return }
        current = e
        context?.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ e: CanvasEvent) {
        defer { resetGesture() }
        guard let context, let start else { return }
        current = e
        if let command = command(start: start, end: e, context: context) {
            context.commandSink.perform(command)
        }
        context.host.showStatusMessage(Self.statusMessage)
    }

    /// Where an attach would put the object: the plane's map and the object's cell rectangle, the
    /// pointer over the point of the object it was grabbed at.  Nil for a degenerate grid or a
    /// rectangle reaching past the horizon.
    func placement(_ gesture: Gesture, start: CanvasEvent, end: CanvasEvent, document: DocumentHandle) -> (map: PlaneMap, cells: Rect)? {
        guard case .attach(_, let bounds, let plane?, let flip) = gesture else { return nil }
        let (_, drawing) = Self.grid(at: end.pasteboardPoint, document: document)
        let projected = Self.plane(plane)
        let map = PlaneMap(drawing.spec, plane: projected)
        guard let pointer = map.cell(at: end.pasteboardPoint) else { return nil }
        let size = drawing.spec.effectiveCellSize
        var fu = bounds.width > 0 ? (start.pasteboardPoint.x - bounds.minX) / bounds.width : 0
        var fv = bounds.height > 0 ? (bounds.maxY - start.pasteboardPoint.y) / bounds.height : 0
        let isFloor = [.floor, .floorLeft, .floorRight].contains(PerspectiveSpec(grid: drawing.spec, plane: projected).effectivePlane)
        if flip { if isFloor { fv = 1 - fv } else { fu = 1 - fu } }
        let width = bounds.width / size, height = bounds.height / size
        let cells = Rect(x: pointer.x - fu * width, y: pointer.y - fv * height, width: width, height: height)
        let corners = [cells.minPoint, Point(x: cells.maxX, y: cells.minY), cells.maxPoint, Point(x: cells.minX, y: cells.maxY)]
        guard corners.allSatisfy({ map.weight($0) > 0.05 }) else { return nil }
        return (map, cells)
    }

    /// The change the gesture writes on release; nil when it changes nothing.
    func command(start: CanvasEvent, end: CanvasEvent, context: ToolContext) -> (any WTModel.Command)? {
        let state = context.document.state
        switch gesture {
        case .attach(let node, _, let plane, let flip)?:
            guard let plane else {
                let delta = end.pasteboardPoint - start.pasteboardPoint
                return delta == Vector(0, 0) ? nil : MoveObjects([node], by: delta)
            }
            guard let placement = placement(gesture!, start: start, end: end, document: context.document) else {
                context.host.showStatusMessage("The object would reach past the horizon there; drag it nearer")
                return nil
            }
            return AttachToPerspectiveGrid([node], plane: plane, at: placement.cells.minPoint, flipped: flip)
        case .move(let wrapper, let flip, let width, let height)?:
            var commands: [any WTModel.Command] = []
            if let position = movedPosition(wrapper, start: start, end: end, state: state) { commands.append(MoveOnGrid([wrapper: position])) }
            if flip { commands.append(FlipOnGrid([wrapper])) }
            if width != 0 || height != 0 { commands.append(ResizeOnGrid([wrapper], width: width, height: height)) }
            guard !commands.isEmpty else { return nil }
            return commands.count == 1 ? commands[0] : CompositeCommand(commands[0].label, commands)
        case let handle?:
            guard let edit = Self.edit(handle, to: end.pasteboardPoint), edit.moved(from: start.pasteboardPoint, to: end.pasteboardPoint) else { return nil }
            return ReshapePageGrid(page: handle.page!.id, grid: handle.grid, gesture: edit.label, mode: Self.mode(start: start, end: end), fields: edit.fields) {
                $0 = edit.values
            }
        case nil:
            return nil
        }
    }

    /// A handle drag's registers.
    struct HandleEdit {
        let label: String
        let fields: [PerspectiveFields.GridField]
        let values: Wiretuner_Doc_V1_PerspectiveGrid
        /// Whether a drag between the points changes the register (the horizon and the floor's
        /// edge only move up and down, a wall's edge only sideways).
        let changes: (Point, Point) -> Bool

        func moved(from: Point, to: Point) -> Bool { changes(from, to) }
    }

    /// The registers dragging `handle` to pasteboard `point` writes (page coordinates).
    static func edit(_ handle: Gesture, to point: Point) -> HandleEdit? {
        var values = Wiretuner_Doc_V1_PerspectiveGrid()
        switch handle {
        case .vanishingPoint(_, let page, let field):
            let stored = PerspectivePageCoordinates.stored(point, page: page.rect)
            switch field {
            case .rightVP: values.rightVp = stored
            case .verticalVP: values.verticalVp = stored
            default: values.leftVp = stored
            }
            return HandleEdit(label: "Move vanishing point", fields: [field], values: values) { $0 != $1 }
        case .horizon(_, let page):
            values.horizonY = PerspectivePageCoordinates.horizon(point.y, page: page.rect)
            return HandleEdit(label: "Move horizon", fields: [.horizonY], values: values) { $0.y != $1.y }
        case .edge(_, let page, .floorFrontY):
            values.floorFrontY = PerspectivePageCoordinates.horizon(point.y, page: page.rect)
            return HandleEdit(label: "Move floor", fields: [.floorFrontY], values: values) { $0 != $1 }
        case .edge(_, let page, let field):
            let x = PerspectivePageCoordinates.wallX(point.x, page: page.rect)
            if field == .rightWallX { values.rightWallX = x } else { values.leftWallX = x }
            return HandleEdit(label: "Move wall", fields: [field], values: values) { $0 != $1 }
        default:
            return nil
        }
    }

    /// kbd:[Option+Shift] at the release leaves copies of the attached objects (`.clone`),
    /// kbd:[Option] alone reshapes a copy of the grid made the page's grid (`.fork`).
    static func mode(start: CanvasEvent, end: CanvasEvent) -> ReshapePageGrid.Mode {
        if end.modifiers.isSuperset(of: [.option, .shift]) { return .clone }
        if start.modifiers.contains(.option) || end.modifiers.contains(.option) { return .fork }
        return .edit
    }

    /// Where a drag from `start` to `end` slides the attached `wrapper` (cells); kbd:[Shift] snaps
    /// to whole cells.  Nil without a move.
    func movedPosition(_ wrapper: OpID, start: CanvasEvent, end: CanvasEvent, state: EngineState) -> Point? {
        guard end.pasteboardPoint != start.pasteboardPoint else { return nil }
        let spec = PerspectiveReading.spec(wrapper, in: state)
        let map = PlaneMap(spec.grid, plane: spec.effectivePlane)
        guard let from = map.cell(at: start.pasteboardPoint), let to = map.cell(at: end.pasteboardPoint) else { return nil }
        var position = spec.cellPosition + (to - from)
        if end.modifiers.contains(.shift) { position = Point(x: position.x.rounded(), y: position.y.rounded()) }
        return position
    }

    /// The change a double-click on `handle` writes -- a vanishing point hides or shows its wall,
    /// the horizon the floor (the built-in grid defined by the same change); nil for the vertical
    /// vanishing point and the edges.
    static func toggle(_ handle: Gesture, drawing: PerspectiveGridDrawing) -> ReshapePageGrid? {
        let field: PerspectiveFields.GridField
        let hidden: Bool
        let noun: String
        switch handle {
        case .vanishingPoint(_, _, .leftVP):
            (field, hidden, noun) = (.leftHidden, !drawing.leftHidden, "wall")
        case .vanishingPoint(_, _, .rightVP):
            (field, hidden, noun) = (.rightHidden, !drawing.rightHidden, "wall")
        case .horizon:
            (field, hidden, noun) = (.floorHidden, !drawing.floorHidden, "floor")
        default:
            return nil
        }
        return ReshapePageGrid(page: handle.page!.id, grid: handle.grid, gesture: "\(hidden ? "Hide" : "Show") \(noun)", fields: [field]) { values in
            switch field {
            case .leftHidden: values.leftHidden = hidden
            case .rightHidden: values.rightHidden = hidden
            default: values.floorHidden = hidden
            }
        }
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
        context?.host.setNeedsOverlayDisplay()
    }

    // MARK: Keys

    /// Space mid-press is the flip, not the temporary Hand (`ToolManager` hands it here while an
    /// object is pressed).
    var isDragging: Bool {
        switch gesture {
        case .attach?, .move?: true
        default: false
        }
    }

    func spaceChanged(down: Bool) {
        guard down, let context else { return }
        switch gesture {
        case .attach(let node, let bounds, let plane, let flip)?:
            gesture = .attach(node, bounds: bounds, plane: plane, flip: !flip)
        case .move(let wrapper, let flip, let width, let height)?:
            gesture = .move(wrapper, flip: !flip, width: width, height: height)
        default:
            return
        }
        context.host.setNeedsOverlayDisplay()
    }

    /// Mid-press keys: an arrow picks the plane of a pending attach; the digits resize an attached
    /// object.
    func keyDown(_ e: NSEvent) -> Bool {
        guard let context, let gesture, let current else { return false }
        switch gesture {
        case .attach(let node, let bounds, _, let flip):
            let (_, drawing) = Self.grid(at: current.pasteboardPoint, document: context.document)
            guard let plane = Self.plane(keyCode: e.keyCode, vanishingPoints: drawing.spec.effectiveVanishingPoints) else { return false }
            self.gesture = .attach(node, bounds: bounds, plane: plane, flip: flip)
            context.host.showStatusMessage("Release to attach it to \(Self.name(plane)); another arrow picks another plane; Space flips it")
        case .move(let wrapper, let flip, var width, var height):
            guard let digit = e.charactersIgnoringModifiers.flatMap(Int.init), (1...6).contains(digit) else { return false }
            let step = digit % 2 == 0 ? 1 : -1
            if digit <= 2 { width += step; height += step } else if digit <= 4 { width += step } else { height += step }
            self.gesture = .move(wrapper, flip: flip, width: width, height: height)
        default:
            return false
        }
        context.host.setNeedsOverlayDisplay()
        return true
    }

    // MARK: Overlay

    /// The preview: the object's outline where it would go (attached: its cell rectangle on its
    /// plane), the grid as a handle drag reshapes it, or the line under the pointer highlighted.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let context else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        guard let start, let current, let gesture else {
            if let hovered, Self.showsGrid(context.document) { highlight(hovered, in: ctx, viewport: viewport, state: context.document.state) }
            return
        }
        let state = context.document.state
        switch gesture {
        case .attach(_, let bounds, let plane, _):
            if plane != nil {
                guard let placement = placement(gesture, start: start, end: current, document: context.document) else { return }
                stroke(quad: placement.cells, map: placement.map, viewport: viewport, in: ctx)
            } else {
                let delta = current.pasteboardPoint - start.pasteboardPoint
                ctx.stroke(bounds.applying(.translation(delta)).applying(viewport.pasteboardToView).cgRect)
            }
        case .move(let wrapper, _, _, _):
            let spec = PerspectiveReading.spec(wrapper, in: state)
            let map = PlaneMap(spec.grid, plane: spec.effectivePlane)
            let position = movedPosition(wrapper, start: start, end: current, state: state) ?? spec.cellPosition
            let size = Self.cells(spec, flat: PerspectiveReading.child(wrapper, in: state).flatMap { Objects.bounds(of: $0, in: state) })
            stroke(quad: Rect(x: position.x, y: position.y, width: size.width, height: size.height), map: map, viewport: viewport, in: ctx)
        case .vanishingPoint, .horizon, .edge:
            // The grid as the release would leave it.
            if let edit = Self.edit(gesture, to: current.pasteboardPoint), let page = gesture.page {
                let drawing = PerspectiveGridDrawing(page: page, state: state).editing(edit.fields, edit.values, state: state)
                PerspectiveFeatures.draw(drawing, in: ctx, viewport: viewport)
            }
            let point = viewport.toView(current.pasteboardPoint)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.strokeEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
        }
    }

    /// The live line under the pointer, in the accent colour.
    private func highlight(_ handle: Gesture, in ctx: CGContext, viewport: Viewport, state: EngineState) {
        guard let page = handle.page else { return }
        let drawing = PerspectiveGridDrawing(page: page, state: state)
        ctx.setLineWidth(2)
        switch handle {
        case .vanishingPoint(_, _, let field):
            guard let point = drawing.vanishingPoints.first(where: { $0.field == field })?.point else { return }
            let view = viewport.toView(point)
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: view.x - 5, y: view.y - 5, width: 10, height: 10))
        case .horizon:
            ctx.move(to: viewport.toView(Point(x: drawing.page.minX, y: drawing.spec.horizonY)).cgPoint)
            ctx.addLine(to: viewport.toView(Point(x: drawing.page.maxX, y: drawing.spec.horizonY)).cgPoint)
            ctx.strokePath()
        case .edge(_, _, let field):
            guard let edge = drawing.edges.first(where: { $0.field == field }) else { return }
            ctx.move(to: viewport.toView(edge.start).cgPoint)
            ctx.addLine(to: viewport.toView(edge.end).cgPoint)
            ctx.strokePath()
        default:
            break
        }
    }

    /// An attached object's size on its plane, cells: its own, or (0 or less) its flat size in
    /// cells -- one cell without a child.
    static func cells(_ spec: PerspectiveSpec, flat: Rect?) -> Size {
        let cell = spec.grid.effectiveCellSize
        let flat = flat ?? Rect(x: 0, y: 0, width: cell, height: cell)
        return Size(width: spec.cellWidth > 0 ? spec.cellWidth : flat.width / cell, height: spec.cellHeight > 0 ? spec.cellHeight : flat.height / cell)
    }

    private func stroke(quad cells: Rect, map: PlaneMap, viewport: Viewport, in ctx: CGContext) {
        let corners = [Point(x: cells.minX, y: cells.minY), Point(x: cells.maxX, y: cells.minY), Point(x: cells.maxX, y: cells.maxY), Point(x: cells.minX, y: cells.maxY)]
            .map { viewport.toView(map.apply($0)).cgPoint }
        ctx.addLines(between: corners)
        ctx.closePath()
        ctx.strokePath()
    }

    func cancel() {
        resetGesture()
        context?.host.setNeedsOverlayDisplay()
    }

    private func resetGesture() {
        gesture = nil
        start = nil
        current = nil
    }
}

extension PerspectiveTool.Gesture {
    /// Whether this is a grid handle (not an object).
    var isHandle: Bool { page != nil }

    /// A handle's page.
    var page: Page? {
        switch self {
        case .vanishingPoint(_, let page, _), .horizon(_, let page), .edge(_, let page, _): page
        default: nil
        }
    }

    /// A handle's grid (nil: the built-in grid, or not a handle).
    var grid: OpID? {
        switch self {
        case .vanishingPoint(let grid, _, _), .horizon(let grid, _), .edge(let grid, _, _): grid
        default: nil
        }
    }
}
