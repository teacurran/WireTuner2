import AppKit
import WTCRDT
import WTGeometry
import WTModel
import WTRender

/// Inspect mode in one window (COLLAB-035's app half; inspect.adoc, "Entering and leaving Inspect
/// mode", "Measuring by hovering"): the measurement overlay (`InspectOverlayLayer`, a layer of its
/// own above the presence layer, so hovering never repaints a document tile), the inspect pointer
/// pushed over the window's tool, and every document command made inert -- whatever the menus,
/// keys or tools ask for, nothing is written while inspecting.
@MainActor
final class InspectModeController {
    weak var window: DocumentWindowController?
    let overlay = InspectOverlayLayer()
    private(set) var isOn = false
    private(set) var tool: InspectTool?
    private var previousTransform: (@MainActor (any WTModel.Command) -> any WTModel.Command)?
    private var previousViewportChange: (@MainActor (Viewport) -> Void)?
    /// How many commands were refused while inspecting.
    private(set) var refused = 0

    init(window: DocumentWindowController) {
        self.window = window
    }

    /// The format measurements read in: the document's unit (picas and kyus read as points and
    /// millimetres).
    static func format(for unit: LengthUnit) -> InspectFormat {
        switch unit {
        case .pixels: InspectFormat(unit: .pixels)
        case .inches, .decimalInches: InspectFormat(unit: .inches)
        case .millimeters, .kyus: InspectFormat(unit: .millimeters)
        case .centimeters: InspectFormat(unit: .centimeters)
        default: InspectFormat(unit: .points)
        }
    }

    func toggle() {
        isOn ? leave() : enter()
    }

    /// Enters Inspect mode.
    func enter() {
        guard !isOn, let window else { return }
        isOn = true
        let canvas = window.canvas
        overlay.anchorPoint = .zero
        overlay.frame = canvas.bounds
        overlay.contentsScale = canvas.overlayScale
        overlay.viewport = canvas.viewport
        overlay.format = Self.format(for: window.documentHandle.units)
        canvas.layer?.insertSublayer(overlay, above: canvas.presenceLayer)
        previousViewportChange = canvas.onViewportChange
        canvas.onViewportChange = { [weak self] viewport in
            self?.previousViewportChange?(viewport)
            self?.viewportDidChange(viewport)
        }
        let document = window.documentHandle
        previousTransform = document.commandTransform
        document.commandTransform = { [weak self] command in
            self?.refused += 1
            return InertCommand(label: command.label)
        }
        // Undo and redo are inert too: they would change the document as surely as a command.
        document.historyLocked = true
        let tool = InspectTool(controller: self)
        self.tool = tool
        window.toolManager?.push(tool)
        window.statusBar.show(message: "Inspect mode: hover to measure; nothing can be changed")
    }

    /// Leaves Inspect mode: the tool, the overlay and the commands are back as they were.
    func leave() {
        guard isOn, let window else { return }
        isOn = false
        overlay.clear()
        overlay.removeFromSuperlayer()
        window.canvas.onViewportChange = previousViewportChange
        window.documentHandle.commandTransform = previousTransform
        window.documentHandle.historyLocked = false
        if let tool { window.toolManager?.pop(tool) }
        tool = nil
    }

    private func viewportDidChange(_ viewport: Viewport) {
        guard let canvas = window?.canvas else { return }
        overlay.frame = canvas.bounds
        overlay.viewport = viewport
    }

    /// What the overlay shows for the pointer at `event`: the hovered object's outline and size,
    /// then the gaps to the selection, or the distances to the page (kbd:[Option]: to every page's
    /// area).
    func measurements(at event: CanvasEvent) -> InspectMeasurements {
        guard let window else { return .empty }
        let viewport = window.canvas.viewport
        let hovered = window.selection.pick(at: event.viewPoint, viewport: viewport, subselect: false)?.id
        let hoveredBounds = hovered.flatMap { window.documentHandle.object(for: $0)?.bounds }
        let selected = window.selection.selection.ids.contains { $0 == hovered } ? nil : window.selection.selectedBounds
        let page = window.documentHandle.pageList.page(containing: event.pasteboardPoint)
        let container = event.modifiers.contains(.option) ? window.documentHandle.allPagesBounds : page?.rect
        // A path point within the pick distance of the pointer reads out too (COLLAB-035's rest).
        let member = window.selection.pick(at: event.viewPoint, viewport: viewport, subselect: true)?.id.opID
        let tolerance = window.selection.pickDistance() / max(viewport.zoom, 0.0001)
        let point = member.flatMap { InspectPoints.anchor(of: $0, near: event.pasteboardPoint, tolerance: tolerance, in: window.documentHandle.state) }
        return InspectMeasurements.measure(hovered: hoveredBounds, selected: selected, container: container, point: point,
                                           origin: page?.origin ?? Point(x: 0, y: 0))
    }

    /// The pointer moved.
    func hover(_ event: CanvasEvent) {
        _ = overlay.show(measurements(at: event))
    }
}

/// A command that writes nothing: Inspect mode hands it to the document in place of any other.
struct InertCommand: WTModel.Command {
    let label: String

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        throw InspectModeError.readOnly
    }
}

enum InspectModeError: Error, Equatable {
    case readOnly
}

/// The pointer in Inspect mode: hovering measures, a click selects (to measure from it),
/// kbd:[Shift] freezes the overlay, kbd:[Esc] leaves the mode.
@MainActor
final class InspectTool: Tool, PointerTracking {
    static let id: ToolID = "inspect"
    weak var controller: InspectModeController?
    private var context: ToolContext?

    init(controller: InspectModeController) {
        self.controller = controller
    }

    var cursor: NSCursor { .crosshair }

    func activate(in context: ToolContext) { self.context = context }
    func deactivate() { context = nil }

    func mouseDown(_ e: CanvasEvent) {
        guard let context else { return }
        context.selection.click(at: e.viewPoint, viewport: context.host.viewport, modifiers: e.modifiers, subselect: false)
        controller?.hover(e)
    }

    func mouseDragged(_ e: CanvasEvent) {}
    func mouseUp(_ e: CanvasEvent) {}

    func flagsChanged(_ e: CanvasEvent) {
        controller?.overlay.frozen = e.modifiers.contains(.shift)
    }

    func keyDown(_ e: NSEvent) -> Bool {
        guard e.keyCode == 53 else { return true }
        controller?.leave()
        return true
    }

    func pointerMoved(_ e: CanvasEvent) {
        controller?.hover(e)
    }

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {}
    func cancel() { controller?.overlay.clear() }
}
