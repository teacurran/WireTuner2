import AppKit
import WTGeometry
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

    init(pasteboardPoint: Point, viewPoint: Point, modifiers: KeyModifiers = [], pressure: Double = 1, clickCount: Int = 1, timestamp: TimeInterval = 0) {
        self.pasteboardPoint = pasteboardPoint
        self.viewPoint = viewPoint
        self.modifiers = modifiers
        self.pressure = pressure
        self.clickCount = clickCount
        self.timestamp = timestamp
    }

    /// The same pointer position with different modifiers (a modifier change mid-drag).
    func with(modifiers: KeyModifiers, timestamp: TimeInterval? = nil) -> CanvasEvent {
        CanvasEvent(
            pasteboardPoint: pasteboardPoint, viewPoint: viewPoint, modifiers: modifiers, pressure: pressure,
            clickCount: clickCount, timestamp: timestamp ?? self.timestamp
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
}

extension CanvasHost {
    func showHUD(_ message: String) { showStatusMessage(message) }
    func requestNamedView(_ target: Viewport) {}
}

/// Snapping, as the tools see it.  A placeholder until GEO-005 and OBJ-039 deliver the
/// resolver and the smart-guide engine: it reports the distances from Preferences and returns
/// points unchanged.
@MainActor
struct SnappingContext {
    /// View pixels within which a point snaps (*Snap distance*).
    var snapDistance: @MainActor () -> Double = { 3 }
    /// View pixels within which a click picks (*Pick distance*).
    var pickDistance: @MainActor () -> Double = { 3 }
    var smartGuidesEnabled: @MainActor () -> Bool = { true }
    /// Called by the snap resolver each time a dragged point snaps (the Sounds preferences,
    /// BASIC-025); GEO-005's resolver reports what it snapped to.
    var didSnap: @MainActor (SnapKind) -> Void = { _ in }

    func snap(_ point: Point, viewport: Viewport) -> Point { point }
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

    init(constrainAngle: Double = 0, fillWhenOpen: Bool = false, penPreview: Bool = true) {
        self.constrainAngle = constrainAngle
        self.fillWhenOpen = fillWhenOpen
        self.penPreview = penPreview
    }

    @MainActor init(preferences: PreferenceStore) {
        constrainAngle = preferences[PreferenceCatalog.Object.constrainAngle]
        fillWhenOpen = preferences[PreferenceCatalog.Object.showFillOpenPaths]
        penPreview = preferences[PreferenceCatalog.General.penPreview]
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

    init(document: DocumentHandle, host: any CanvasHost, snapping: SnappingContext = SnappingContext(), selection: SelectionController? = nil) {
        self.document = document
        self.host = host
        self.snapping = snapping
        self.selection = selection ?? SelectionController(document: document)
        commandSink = document
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
}

extension Tool {
    var toolID: ToolID { Self.id }
    func forceClick(_ e: CanvasEvent) {}
}
