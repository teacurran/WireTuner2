import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender

/// Identifies a tool: `"pointer"`, `"hand"`, `"zoom"`, `"rectangle"`.  Stable: shortcut sets
/// (`tool.<id>` commands) and accessibility identifiers refer to it.
struct ToolID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    var description: String { rawValue }

    static let pointer: ToolID = "pointer"
    static let hand: ToolID = "hand"
    static let zoom: ToolID = "zoom"
    static let rectangle: ToolID = "rectangle"
    static let ellipse: ToolID = "ellipse"
    static let line: ToolID = "line"
    static let pen: ToolID = "pen"
}

/// One pointer event on the canvas, already translated into both coordinate spaces.
struct CanvasEvent: Equatable, Sendable {
    /// The pointer in pasteboard coordinates (through `Viewport.viewToPasteboard`, so canvas
    /// rotation is already undone).
    let pasteboardPoint: Point
    /// The pointer in view points, y down, origin at the canvas's top-left.
    let viewPoint: Point
    let modifiers: KeyModifiers
    /// Tablet or Force Touch pressure, 0...1; 1 for a mouse button.
    let pressure: Double
    let clickCount: Int
    /// Seconds since system start (`NSEvent.timestamp`).
    let timestamp: TimeInterval
    /// A pen sample (`NSEvent.subtype == .tabletPoint`): a tablet or an Apple Pencil through
    /// Sidecar in contact (freeform.adoc, "Tablet"; DRAW-020).
    var isTablet = false

    init(pasteboardPoint: Point, viewPoint: Point, modifiers: KeyModifiers = [], pressure: Double = 1, clickCount: Int = 1, timestamp: TimeInterval = 0,
         isTablet: Bool = false) {
        self.pasteboardPoint = pasteboardPoint
        self.viewPoint = viewPoint
        self.modifiers = modifiers
        self.pressure = pressure
        self.clickCount = clickCount
        self.timestamp = timestamp
        self.isTablet = isTablet
    }

    /// The same pointer position with different modifiers (a modifier change mid-drag).
    func with(modifiers: KeyModifiers, timestamp: TimeInterval? = nil) -> CanvasEvent {
        CanvasEvent(
            pasteboardPoint: pasteboardPoint, viewPoint: viewPoint, modifiers: modifiers, pressure: pressure,
            clickCount: clickCount, timestamp: timestamp ?? self.timestamp, isTablet: isTablet
        )
    }
}

/// What a tool may ask of the canvas it runs in.  `CanvasView` implements it; tests use a
/// stand-in.
@MainActor
protocol CanvasHost: AnyObject {
    var viewport: Viewport { get }
    func setViewport(_ viewport: Viewport)
    /// Redraws the overlay (per event, never per frame).
    func setNeedsOverlayDisplay()
    /// The active tool or its cursor changed.
    func toolCursorDidChange()
    /// Shows `message` in the status bar ("Drag to draw a rectangle; Shift constrains").
    func showStatusMessage(_ message: String)
    /// Shows `message` briefly over the canvas (the "coming soon" HUD).
    func showHUD(_ message: String)
    /// The Zoom tool's Shift-drag: ask for a named view of `target` (the New View sheet).
    func requestNamedView(_ target: Viewport)
    /// Hands a key to the text input system while the Text tool edits (`interpretKeyEvents`, which
    /// calls back through the canvas's `NSTextInputClient`); false when the host has none.
    func interpretKeys(_ event: NSEvent) -> Bool
    /// Calls `body` once the tiles show every change applied so far (D-076: a gesture's preview
    /// stays up until its change has rendered, so the object never jumps back).
    func whenTilesCatchUp(_ body: @escaping @MainActor () -> Void)
}

extension CanvasHost {
    func whenTilesCatchUp(_ body: @escaping @MainActor () -> Void) { body() }
    func showHUD(_ message: String) { showStatusMessage(message) }
    func requestNamedView(_ target: Viewport) {}
    func interpretKeys(_ event: NSEvent) -> Bool { false }
}

/// Snapping, as the tools see it (grid-guides.adoc, "Snapping to points and objects"; DOC-016's
/// `SnapEngine`): `sources` gathers what there is to snap to -- the grid, every page's guides and
/// the guide objects from `PageList`, the canvas's objects through the hit tester's R-tree --
/// and the View menu's toggles; `snap` resolves a dragged point against them, and kbd:[Control]
/// held suspends it.  Without sources (a tool outside a window) points come back unchanged.
@MainActor
struct SnappingContext {
    /// View pixels within which a point snaps (*Snap distance*).
    var snapDistance: @MainActor () -> Double = { 3 }
    /// View pixels within which a click picks (*Pick distance*).
    var pickDistance: @MainActor () -> Double = { 3 }
    var smartGuidesEnabled: @MainActor () -> Bool = { true }
    /// Called each time a dragged point snaps, with what it snapped to (the Sounds preferences,
    /// BASIC-025; a path counts as an object).
    var didSnap: @MainActor (SnapKind) -> Void = { _ in }
    /// What there is to snap to and the toggles that are on, read at each snap; nil snaps nothing.
    var sources: @MainActor () -> (sources: SnapSources, toggles: SnapToggles)? = { nil }
    /// Whether kbd:[Control] is held (it suspends snapping for the drag); replaceable in tests.
    var suspended: @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.control) }
    /// The last snap, for the pointer's feedback (the triangle, the point badge); nil when the
    /// last point snapped to nothing.
    var feedback: SnapFeedbackBox = SnapFeedbackBox()

    /// Where `point` (pasteboard) snaps at `viewport`'s zoom; `point` itself when nothing is in
    /// reach, snapping is suspended, or there are no sources.
    func snap(_ point: Point, viewport: Viewport) -> Point {
        resolve(point, viewport: viewport)?.point ?? point
    }

    /// The snap of `point`, reporting what it snapped to.
    func resolve(_ point: Point, viewport: Viewport, dragOrigin: Point? = nil) -> SnapResult? {
        guard let (sources, toggles) = sources() else { return nil }
        let engine = SnapEngine(snapDistance: snapDistance(), zoom: viewport.zoom, toggles: toggles)
        let result = engine.resolve(point, sources: sources, dragOrigin: dragOrigin, suspended: suspended())
        report(result)
        return result
    }

    /// A drag of `point` by `delta` (the selection's snapping point): the delta that lands it on
    /// what it snaps to, or `delta` unchanged.
    func snapDrag(of point: Point, by delta: Vector, viewport: Viewport) -> Vector {
        guard let (sources, toggles) = sources() else { return delta }
        let engine = SnapEngine(snapDistance: snapDistance(), zoom: viewport.zoom, toggles: toggles)
        let (snapped, result) = engine.resolveDrag(of: point, by: delta, sources: sources, suspended: suspended())
        report(result)
        return snapped
    }

    /// Remembers `result` and sounds a snap when the point lands on something new (not again
    /// while it stays on the same target).
    private func report(_ result: SnapResult?) {
        let previous = feedback.result
        feedback.result = result
        guard let result, previous?.candidate != result.candidate else { return }
        didSnap(SnapKind(result.kind))
    }
}

/// The last snap, shared by the copies of a `SnappingContext` (the tools hold copies).
@MainActor
final class SnapFeedbackBox {
    var result: SnapResult?
}

extension SnapKind {
    /// The sound a snap to `kind` plays: a path is an object; smart guides sound as guides.
    init(_ kind: WTGeometry.SnapKind) {
        switch kind {
        case .point: self = .point
        case .path: self = .object
        case .guide, .smartGuide: self = .guide
        case .grid: self = .grid
        }
    }
}

/// What a dragged point snapped to (preferences.adoc, "Sounds").
enum SnapKind: String, CaseIterable, Sendable {
    case point, object, grid, guide
}

/// The preferences the drawing tools read at each use (rectangles-ellipses-lines.adoc,
/// pen-bezigon.adoc, vector-basics.adoc).
struct DrawingSettings: Equatable, Sendable {
    /// *Constrain angle*, degrees: Shift snaps to it and every 45° from it; shapes drawn with it
    /// are rotated by it.
    var constrainAngle: Double = 0
    /// *Show fill for new open paths*: copied into `fill_when_open` when a path is created.
    var fillWhenOpen = false
    /// *Pen tool preview*: the rubber-band segment.
    var penPreview = true
    /// *Auto-join paths*: ending a Pen path on another open path's end joins them.
    var autoJoin = true
    /// *Arrow key distance* and *Shift-arrow key distance*, points (moving.adoc).
    var arrowDistance = 1.0
    var shiftArrowDistance = 10.0
    /// The drawing tools' own settings (their options sheets).
    var tools = DrawingToolOptions()

    init(constrainAngle: Double = 0, fillWhenOpen: Bool = false, penPreview: Bool = true, autoJoin: Bool = true, arrowDistance: Double = 1,
         shiftArrowDistance: Double = 10, tools: DrawingToolOptions = DrawingToolOptions()) {
        self.constrainAngle = constrainAngle
        self.fillWhenOpen = fillWhenOpen
        self.penPreview = penPreview
        self.autoJoin = autoJoin
        self.arrowDistance = arrowDistance
        self.shiftArrowDistance = shiftArrowDistance
        self.tools = tools
    }

    @MainActor init(preferences: PreferenceStore) {
        constrainAngle = preferences[PreferenceCatalog.Object.constrainAngle]
        fillWhenOpen = preferences[PreferenceCatalog.Object.showFillOpenPaths]
        penPreview = preferences[PreferenceCatalog.General.penPreview]
        autoJoin = preferences[PreferenceCatalog.Object.autoJoinPaths]
        arrowDistance = preferences[PreferenceCatalog.Object.arrowDistance]
        shiftArrowDistance = preferences[PreferenceCatalog.Object.shiftArrowDistance]
        tools = DrawingToolOptions(preferences: preferences)
    }

    /// Shift's rule: the constrain angle and every 45° from it.
    var constraint: AngleConstraint { .degrees(constrainAngle) }
}

/// Everything a tool gets when activated (client.adoc, "Tools"): the document, the view
/// transform, snapping and the `CommandSink` it emits its change through.
@MainActor
struct ToolContext {
    let document: DocumentHandle
    unowned let host: any CanvasHost
    var snapping: SnappingContext
    /// The window's selection (APP-006); a fresh one over `document` when none is given.
    let selection: SelectionController
    /// The Redraw preferences (*Preview drag* and the rest, BASIC-013), read at each use.
    var redraw: @MainActor () -> RedrawSettings = { RedrawSettings() }
    /// *Option-drag copies paths*: with it off, Option-drag previews the dragged objects fully.
    var optionDragCopies: @MainActor () -> Bool = { true }
    /// The drawing preferences (constrain angle, open-path fill, pen preview).
    var drawing: @MainActor () -> DrawingSettings = { DrawingSettings() }
    /// Where the tools' commands go: the document unless a test records them.
    var commandSink: CommandSink
    /// The window's object commands (nudging, the active layer), when the tool runs in a window.
    var objectEditing: ObjectEditing?
    /// *Double-click enables transform handles* (transforming.adoc, OBJ-034).
    var transformHandles: @MainActor () -> Bool = { true }
    /// Makes `id` the window's tool (the Text tool handing over to the Pointer).
    var selectTool: @MainActor (ToolID) -> Void = { _ in }
    /// The Pointer's double-click on text: the Text tool takes over with the insertion point at
    /// the point (text-blocks.adoc, "Double-click behaviors"); nil outside a window.
    var editText: (@MainActor (OpID, Point) -> Void)?
    /// Opens the Text Editor window on a block, or on a new empty block at the point (TYPE-011).
    var openTextEditor: (@MainActor (OpID?, Point) -> Void)?
    /// Opens the Text Editor on a text block inside an instance (its text override; LIB-027).
    var openOverrideEditor: (@MainActor (_ instance: OpID, _ master: OpID) -> Void)?
    /// The Text tool's preferences.
    var text: @MainActor () -> TextToolSettings = { TextToolSettings() }
    /// The Text tool's insertion point moved: the block, the character it is before (zero: the
    /// end) and a selection's other end; nil when editing ends (outgoing presence).
    var textCaretChanged: @MainActor (PresenceCaret?) -> Void = { _ in }
    /// The Page tool's kbd:[Option]-double-click: the *Modify Page* sheet on the page; nil outside
    /// a window.
    var modifyPage: (@MainActor (OpID) -> Void)?
    /// Asks the person to confirm (a removal that takes objects with it): message, informative
    /// text; true goes ahead.  Outside a window it always goes ahead.
    var confirm: @MainActor (String, String) -> Bool = { _, _ in true }
    /// The attribute stack a new object is born with (default-attributes.adoc; OBJ-037): the
    /// document's defaults, with the window's current colours laid over them in a window.
    var newObjectAppearance: @MainActor () -> Wiretuner_Doc_V1_AppearanceProps

    init(document: DocumentHandle, host: any CanvasHost, snapping: SnappingContext = SnappingContext(), selection: SelectionController? = nil) {
        self.document = document
        self.host = host
        self.snapping = snapping
        self.selection = selection ?? SelectionController(document: document)
        commandSink = document
        newObjectAppearance = { DocumentDefaults.appearance(in: document.state) }
    }
    var viewport: Viewport { host.viewport }
}

/// A tool that takes Space mid-drag for itself (the shape tools' "reposition while dragging")
/// instead of the temporary Hand.
@MainActor
protocol SpaceDragging: AnyObject {
    /// Whether a drag is in progress that Space should reposition.
    var isDragging: Bool { get }
    func spaceChanged(down: Bool)
}

/// A tool that follows the pointer while no button is down (the Pen's cursor and preview).
@MainActor
protocol PointerTracking: AnyObject {
    func pointerMoved(_ e: CanvasEvent)
}

/// A canvas tool (client.adoc, "Tools").  Tools preview during a drag by drawing an overlay
/// and emit exactly one change on mouse-up, so a drag is one undo step and one change on the
/// wire.
@MainActor
protocol Tool: AnyObject {
    static var id: ToolID { get }
    /// The id this instance is registered under; `Self.id` unless one class serves several
    /// tools (`UnimplementedTool`).
    var toolID: ToolID { get }
    var cursor: NSCursor { get }
    func activate(in context: ToolContext)
    func deactivate()
    func mouseDown(_ e: CanvasEvent)
    func mouseDragged(_ e: CanvasEvent)
    func mouseUp(_ e: CanvasEvent)
    /// A modifier change, including mid-drag; many tools depend on it.
    func flagsChanged(_ e: CanvasEvent)
    /// Returns whether the tool consumed the key; unconsumed keys run shortcuts.
    func keyDown(_ e: NSEvent) -> Bool
    /// Draws handles and previews in view points (y down) into the overlay layer.
    func drawOverlay(in ctx: CGContext, viewport: Viewport)
    /// Esc: abandons the gesture in progress without emitting anything.
    func cancel()
    /// A Force click (stage 2 of a Force Touch press) at `e`; most tools ignore it.
    func forceClick(_ e: CanvasEvent)
    /// Whether kbd:[Esc] would abandon something; with nothing, Esc ends following.
    var hasSomethingToCancel: Bool { get }
}

extension Tool {
    var toolID: ToolID { Self.id }
    func forceClick(_ e: CanvasEvent) {}
    /// Whether kbd:[Esc] would abandon something (a gesture, the transform handles).
    var hasSomethingToCancel: Bool { false }
}
