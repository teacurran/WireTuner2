import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// The Perspective tool (perspective.adoc, "Attaching objects to the grid", "Reshaping the grid on
/// the canvas"; FX-044, with FX-043's grid handles).  Press on an object that is not on the grid
/// and drag: an arrow key picks the plane (one-point grids: kbd:[Left]/kbd:[Right] the wall,
/// kbd:[Up]/kbd:[Down] the floor; two and three points: kbd:[Left] the left wall, kbd:[Right] the
/// right, kbd:[Up] the floor to the right vanishing point, kbd:[Down] to the left) and the release
/// attaches it there with its corner at the pointer; released without a plane it moves flat.
/// Press on an attached object: the drag slides it on its plane (kbd:[Shift]: whole cells),
/// kbd:[Space] flips it, kbd:[1]–kbd:[6] shrink and grow it by a cell, all written on release as
/// one change.  With the grid shown, drag a vanishing point or the horizon to reshape the page's
/// grid (kbd:[Option+Shift]: the attached objects leave copies where they were) and double-click one
/// to hide or show its plane.  A wall's edge line and the floor's front edge drag too; pointing at
/// any live line shows the arrow badge beside the pointer; kbd:[Option]-dragging one makes a copy
/// of the grid ("Grid 2") the page's grid and reshapes that; kbd:[Cmd+Option]-double-click on
/// attached text opens it in the Text Editor.
@MainActor
final class PerspectiveTool: Tool, PointerTracking {
    static let id: ToolID = "perspective"
    static let statusMessage = "Drag an object and press an arrow key to attach it; drag a vanishing point or the horizon to reshape the grid"
    static let defineFirst = "Define a grid first (View ▸ Perspective Grid ▸ Define Grids…)"
    /// How near (view points) a vanishing point or the horizon a press takes it.
    static let pickRadius = 6.0

    static var descriptor: ToolDescriptor {
        ToolCatalog.all.first { $0.id == id }!.delivering { PerspectiveTool() }
    }

    /// Whether the window showing `document` shows the grid (set by `PerspectiveFeatures`).
    static var showsGrid: @MainActor (DocumentHandle) -> Bool = { _ in false }

    /// What the press took.
    enum Gesture: Equatable {
        /// An object not on the grid (its painted bounds); the plane an arrow key chose.
        case attach(OpID, bounds: Rect, plane: Wiretuner_Doc_V1_PerspectivePlane?)
        /// An attached object (its wrapper): the flip and cell resizes pressed so far.
        case move(OpID, flip: Bool, width: Int, height: Int)
        /// A vanishing point of the page's grid.
        case vanishingPoint(grid: OpID, page: Rect, field: PerspectiveFields.GridField)
        /// The horizon of the page's grid.
        case horizon(grid: OpID, page: Rect)
        /// A wall's near edge (`leftWallX`, `rightWallX`) or the floor's front edge (`floorFrontY`).
        case edge(grid: OpID, page: Rect, field: PerspectiveFields.GridField)
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

    /// Whether the pointer is over a live grid line.
    private(set) var overHandle = false

    private var context: ToolContext?
    private(set) var gesture: Gesture?
    private(set) var start: CanvasEvent?
    private(set) var current: CanvasEvent?

    init() {}

    var cursor: NSCursor { overHandle ? Self.badgeCursor : .crosshair }
    var hasSomethingToCancel: Bool { gesture != nil }

    func activate(in context: ToolContext) {
        self.context = context
        context.host.showStatusMessage(Self.statusMessage)
    }

    func deactivate() {
        cancel()
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

    /// The grid handle under view point `point` and the page's grid drawing, when the grid is
    /// shown and defined.
    func handle(at e: CanvasEvent, context: ToolContext) -> (gesture: Gesture, drawing: PerspectiveGridDrawing)? {
        guard let hit = hit(at: e, context: context) else { return nil }
        guard let gesture = hit.gesture else {
            context.host.showStatusMessage(Self.defineFirst)
            return nil
        }
        return (gesture, hit.drawing)
    }

    /// The live line under `e` with the page's grid drawing -- a vanishing point, the horizon, a
    /// wall's edge or the floor's front edge, in that order -- and its gesture (nil while the
    /// page uses the built-in grid, which is reshaped only once defined); nil off every line or
    /// with the grid hidden.
    func hit(at e: CanvasEvent, context: ToolContext) -> (gesture: Gesture?, drawing: PerspectiveGridDrawing)? {
        guard Self.showsGrid(context.document) else { return nil }
        let (page, drawing) = Self.grid(at: e.pasteboardPoint, document: context.document)
        let viewport = context.viewport
        let nearPoint = drawing.vanishingPoints.first { viewport.toView($0.point).distance(to: e.viewPoint) <= Self.pickRadius }
        let onHorizon = abs(viewport.toView(Point(x: e.pasteboardPoint.x, y: drawing.spec.horizonY)).y - e.viewPoint.y) <= Self.pickRadius
        let edge = nearPoint == nil && !onHorizon ? drawing.edge(near: e.viewPoint, viewport: viewport, radius: Self.pickRadius) : nil
        guard nearPoint != nil || onHorizon || edge != nil else { return nil }
        guard let grid = drawing.grid else { return (nil, drawing) }
        if let nearPoint { return (.vanishingPoint(grid: grid, page: page.rect, field: nearPoint.field), drawing) }
        if let edge { return (.edge(grid: grid, page: page.rect, field: edge), drawing) }
        return (.horizon(grid: grid, page: page.rect), drawing)
    }

    /// Hovering: the arrow badge over a live line.
    func pointerMoved(_ e: CanvasEvent) {
        guard let context else { return }
        let over = hit(at: e, context: context) != nil
        guard over != overHandle else { return }
        overHandle = over
        context.host.toolCursorDidChange()
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
        if editAttachedText(at: e, context: context) {
            resetGesture()
            return
        }
        if let (handle, drawing) = handle(at: e, context: context) {
            if e.clickCount >= 2 {
                toggleHidden(handle, drawing: drawing, context: context)
                resetGesture()
                return
            }
            gesture = handle
            return
        }
        guard let (id, _) = context.selection.pick(at: e.viewPoint, viewport: context.viewport, subselect: false),
              let object = context.document.object(for: id), let bounds = object.bounds, !object.isEffectivelyLocked else {
            resetGesture()
            return
        }
        let state = context.document.state
        context.selection.model.set(Selection([id]))
        if let wrapper = PerspectiveReading.wrapper(of: id.opID, in: state) {
            gesture = .move(wrapper, flip: false, width: 0, height: 0)
        } else {
            gesture = .attach(id.opID, bounds: bounds, plane: nil)
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
    }

    /// The change the gesture writes on release; nil when it changes nothing.
    func command(start: CanvasEvent, end: CanvasEvent, context: ToolContext) -> (any WTModel.Command)? {
        let state = context.document.state
        switch gesture {
        case .attach(let node, _, let plane)?:
            guard let plane else {
                let delta = end.pasteboardPoint - start.pasteboardPoint
                return delta == Vector(0, 0) ? nil : MoveObjects([node], by: delta)
            }
            let (_, drawing) = Self.grid(at: end.pasteboardPoint, document: context.document)
            guard let cell = PlaneMap(drawing.spec, plane: Self.plane(plane)).cell(at: end.pasteboardPoint) else { return nil }
            return AttachToPerspectiveGrid([node], plane: plane, at: cell)
        case .move(let wrapper, let flip, let width, let height)?:
            var commands: [any WTModel.Command] = []
            if let position = movedPosition(wrapper, start: start, end: end, state: state) { commands.append(MoveOnGrid([wrapper: position])) }
            if flip { commands.append(FlipOnGrid([wrapper])) }
            if width != 0 || height != 0 { commands.append(ResizeOnGrid([wrapper], width: width, height: height)) }
            guard !commands.isEmpty else { return nil }
            return commands.count == 1 ? commands[0] : CompositeCommand(commands[0].label, commands)
        case .vanishingPoint(let grid, let page, let field)?:
            guard end.pasteboardPoint != start.pasteboardPoint else { return nil }
            let stored = PerspectivePageCoordinates.stored(end.pasteboardPoint, page: page)
            let edit = EditGrid(grid, label: "Move vanishing point", fields: [field]) { values in
                switch field {
                case .rightVP: values.rightVp = stored
                case .verticalVP: values.verticalVp = stored
                default: values.leftVp = stored
                }
            }
            return reshape(edit, start: start, end: end, context: context)
        case .horizon(let grid, let page)?:
            guard end.pasteboardPoint.y != start.pasteboardPoint.y else { return nil }
            let y = PerspectivePageCoordinates.horizon(end.pasteboardPoint.y, page: page)
            let edit = EditGrid(grid, label: "Move horizon", fields: [.horizonY]) { $0.horizonY = y }
            return reshape(edit, start: start, end: end, context: context)
        case .edge(let grid, let page, let field)?:
            guard end.pasteboardPoint != start.pasteboardPoint else { return nil }
            let edit: EditGrid
            if field == .floorFrontY {
                let y = PerspectivePageCoordinates.horizon(end.pasteboardPoint.y, page: page)
                edit = EditGrid(grid, label: "Move floor", fields: [.floorFrontY]) { $0.floorFrontY = y }
            } else {
                let x = PerspectivePageCoordinates.wallX(end.pasteboardPoint.x, page: page)
                edit = EditGrid(grid, label: "Move wall", fields: [field]) { values in
                    if field == .rightWallX { values.rightWallX = x } else { values.leftWallX = x }
                }
            }
            return reshape(edit, start: start, end: end, context: context)
        case nil:
            return nil
        }
    }

    /// A grid handle's drag as written: kbd:[Option+Shift] leaves copies of the attached objects
    /// (`CloneOnGrid`), kbd:[Option] alone reshapes a copy of the grid made the page's grid
    /// (`ForkGrid`), else the edit itself.
    func reshape(_ edit: EditGrid, start: CanvasEvent, end: CanvasEvent, context: ToolContext) -> any WTModel.Command {
        if end.modifiers.isSuperset(of: [.option, .shift]) { return CloneOnGrid(edit) }
        if start.modifiers.contains(.option) || end.modifiers.contains(.option) {
            return ForkGrid(edit, page: Self.grid(at: start.pasteboardPoint, document: context.document).page.id)
        }
        return edit
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

    /// Double-click on a vanishing point hides or shows its wall (the vertical one has none); on
    /// the horizon, the floor.
    private func toggleHidden(_ handle: Gesture, drawing: PerspectiveGridDrawing, context: ToolContext) {
        guard let command = Self.toggle(handle, drawing: drawing) else { return }
        context.commandSink.perform(command)
    }

    /// The change a double-click on `handle` writes; nil for the vertical vanishing point.
    static func toggle(_ handle: Gesture, drawing: PerspectiveGridDrawing) -> EditGrid? {
        switch handle {
        case .vanishingPoint(let grid, _, .leftVP):
            let hidden = !drawing.leftHidden
            return EditGrid(grid, label: hidden ? "Hide wall" : "Show wall", fields: [.leftHidden]) { $0.leftHidden = hidden }
        case .vanishingPoint(let grid, _, .rightVP):
            let hidden = !drawing.rightHidden
            return EditGrid(grid, label: hidden ? "Hide wall" : "Show wall", fields: [.rightHidden]) { $0.rightHidden = hidden }
        case .horizon(let grid, _):
            let hidden = !drawing.floorHidden
            return EditGrid(grid, label: hidden ? "Hide floor" : "Show floor", fields: [.floorHidden]) { $0.floorHidden = hidden }
        default:
            return nil
        }
    }

    func flagsChanged(_ e: CanvasEvent) {
        guard let current else { return }
        self.current = current.with(modifiers: e.modifiers, timestamp: e.timestamp)
    }

    /// Mid-drag keys: an arrow picks the plane of a pending attach; kbd:[Space] flips and the
    /// digits resize an attached object.
    func keyDown(_ e: NSEvent) -> Bool {
        guard let context, let gesture, let current else { return false }
        switch gesture {
        case .attach(let node, let bounds, _):
            let (_, drawing) = Self.grid(at: current.pasteboardPoint, document: context.document)
            guard let plane = Self.plane(keyCode: e.keyCode, vanishingPoints: drawing.spec.effectiveVanishingPoints) else { return false }
            self.gesture = .attach(node, bounds: bounds, plane: plane)
        case .move(let wrapper, let flip, var width, var height):
            if e.keyCode == 49 {
                self.gesture = .move(wrapper, flip: !flip, width: width, height: height)
            } else if let digit = e.charactersIgnoringModifiers.flatMap(Int.init), (1...6).contains(digit) {
                let step = digit % 2 == 0 ? 1 : -1
                if digit <= 2 { width += step; height += step } else if digit <= 4 { width += step } else { height += step }
                self.gesture = .move(wrapper, flip: flip, width: width, height: height)
            } else {
                return false
            }
        default:
            return false
        }
        context.host.setNeedsOverlayDisplay()
        return true
    }

    /// The preview: the object's outline where it would go (attached: its cell rectangle on its
    /// plane) or the handle being dragged.
    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        guard let context, let start, let current, let gesture else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        let state = context.document.state
        switch gesture {
        case .attach(_, let bounds, let plane):
            if let plane {
                let (_, drawing) = Self.grid(at: current.pasteboardPoint, document: context.document)
                let map = PlaneMap(drawing.spec, plane: Self.plane(plane))
                guard let cell = map.cell(at: current.pasteboardPoint) else { return }
                let size = drawing.spec.effectiveCellSize
                stroke(quad: Rect(x: cell.x, y: cell.y, width: bounds.width / size, height: bounds.height / size), map: map, viewport: viewport, in: ctx)
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
            let point = viewport.toView(current.pasteboardPoint)
            ctx.strokeEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
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
