import AppKit
import WTGeometry
import WTRender

/// Routes canvas events to the active tool and owns the temporary-tool state (client.adoc,
/// "Tools").  One per canvas.  The decisions are in `TemporaryToolMachine` and
/// `CanvasEventTranslator`; this class only performs them.
@MainActor
final class ToolManager {
    let registry: ToolRegistry
    let context: ToolContext
    /// Runs the command bound to a key the tool did not consume (tool shortcuts go through
    /// the command registry); returns whether a command ran.
    var runShortcut: @MainActor (KeyEquivalent) -> Bool
    /// Called after the effective tool changes.
    var onToolChange: (@MainActor (ToolID) -> Void)?
    /// What the Info toolbar shows: the pointer position plus the active tool's readouts.
    private(set) var info = ToolInfo() {
        didSet { if info != oldValue { onInfoChange?(info) } }
    }
    /// Called when `info` changes (the Info toolbar, BASIC-011).
    var onInfoChange: (@MainActor (ToolInfo) -> Void)?
    /// kbd:[Esc] pressed while the tool had nothing to cancel (the window ends following).
    var onIdleEscape: (@MainActor () -> Void)?

    private(set) var machine: TemporaryToolMachine
    private(set) var activeTool: any Tool
    private var instances: [ToolID: any Tool] = [:]
    private var lastEvent: CanvasEvent?

    init(registry: ToolRegistry, context: ToolContext, initialTool: ToolID = .pointer, runShortcut: @escaping @MainActor (KeyEquivalent) -> Bool = { _ in false }) {
        self.registry = registry
        self.context = context
        self.runShortcut = runShortcut
        let initial = registry.contains(initialTool) ? initialTool : .pointer
        machine = TemporaryToolMachine(baseTool: initial)
        let tool = registry.makeTool(initial)
        activeTool = tool
        instances[initial] = tool
        tool.activate(in: context)
    }

    var baseToolID: ToolID { machine.baseTool }
    var activeToolID: ToolID { activeTool.toolID }
    var isTemporary: Bool { machine.temporary != nil }
    var cursor: NSCursor { activeTool.cursor }

    // MARK: Selection

    /// Makes `id` the base tool (a click in the Tools panel, a tool shortcut).
    func select(_ id: ToolID) {
        guard registry.contains(id) else { return }
        perform(machine.select(id))
    }

    private func tool(for id: ToolID) -> any Tool {
        if let existing = instances[id] { return existing }
        let tool = registry.makeTool(id)
        instances[id] = tool
        return tool
    }

    private func perform(_ effects: [ToolMachineEffect]) {
        for effect in effects {
            switch effect {
            case .finishDrag:
                if let lastEvent { activeTool.mouseUp(lastEvent) }
            case let .activate(_, to):
                activeTool.deactivate()
                activeTool = tool(for: to)
                activeTool.activate(in: context)
                context.host.toolCursorDidChange()
                context.host.setNeedsOverlayDisplay()
                onToolChange?(to)
            }
        }
    }

    // MARK: Pointer events

    func mouseDown(_ event: CanvasEvent) {
        machine.mouseDown()
        lastEvent = event
        activeTool.mouseDown(event)
        publishInfo(event)
        context.host.setNeedsOverlayDisplay()
    }

    /// The pointer moved with no button down: the Info toolbar follows it.
    func pointerMoved(_ event: CanvasEvent) {
        publishInfo(event)
        (activeTool as? any PointerTracking)?.pointerMoved(event)
    }

    private func publishInfo(_ event: CanvasEvent) {
        let base = ToolInfo(position: event.pasteboardPoint)
        info = (activeTool as? any ToolInfoPublishing).map { base.merged(with: $0.info) } ?? base
    }

    func mouseDragged(_ event: CanvasEvent) {
        guard !machine.isSuppressingDrag else { return }
        lastEvent = event
        activeTool.mouseDragged(event)
        publishInfo(event)
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ event: CanvasEvent) {
        let suppressed = machine.isSuppressingDrag
        if !suppressed { activeTool.mouseUp(event) }
        publishInfo(event)
        lastEvent = nil
        let result = machine.mouseUp()
        perform(result.effects)
        context.host.setNeedsOverlayDisplay()
    }

    /// A modifier change.  The current tool hears it first (mid-drag constraint changes);
    /// then Command may push or pop the temporary Pointer.
    func flagsChanged(_ modifiers: KeyModifiers, timestamp: TimeInterval = 0) {
        if let lastEvent {
            let event = lastEvent.with(modifiers: modifiers, timestamp: timestamp)
            self.lastEvent = event
            activeTool.flagsChanged(event)
        } else {
            activeTool.flagsChanged(CanvasEvent(pasteboardPoint: .zero, viewPoint: .zero, modifiers: modifiers, timestamp: timestamp))
        }
        perform(machine.commandChanged(down: modifiers.contains(.command)))
        context.host.setNeedsOverlayDisplay()
    }

    /// A Force click on the canvas, delivered to the effective tool (BASIC-034).
    func forceClick(_ event: CanvasEvent) {
        activeTool.forceClick(event)
        context.host.setNeedsOverlayDisplay()
    }

    // MARK: Keys

    /// Space (push/pop), Esc (cancel), then the tool, then shortcuts.  Returns whether the
    /// key was handled.
    @discardableResult
    func keyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == CanvasEventTranslator.spaceKeyCode {
            if let tool = activeTool as? any SpaceDragging, tool.isDragging {
                if !event.isARepeat { tool.spaceChanged(down: true) }
                context.host.setNeedsOverlayDisplay()
                return true
            }
            if !event.isARepeat { perform(machine.spaceChanged(down: true)) }
            return true
        }
        if event.keyCode == CanvasEventTranslator.escapeKeyCode {
            let busy = activeTool.hasSomethingToCancel || machine.isDragging
            cancel()
            // Esc with nothing else to cancel ends following (presence.adoc, "Following someone").
            if !busy { onIdleEscape?() }
            return true
        }
        if activeTool.keyDown(event) {
            context.host.setNeedsOverlayDisplay()
            return true
        }
        if !machine.isDragging, nudge(keyCode: event.keyCode, modifiers: KeyEquivalentResolver.modifiers(event.modifierFlags)) {
            return true
        }
        guard !machine.isDragging,
            let key = CanvasEventTranslator.shortcut(charactersIgnoringModifiers: event.charactersIgnoringModifiers, modifierFlags: event.modifierFlags)
        else { return false }
        return runShortcut(key)
    }

    /// An arrow key without Command, Option or Control nudges the selection by *Arrow key
    /// distance* (with Shift, *Shift-arrow key distance*) (OBJ-009).  Returns whether it did.
    func nudge(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        guard let editing = context.objectEditing, modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }
        let settings = context.drawing()
        let distance = modifiers.contains(.shift) ? settings.shiftArrowDistance : settings.arrowDistance
        guard let delta = ObjectEditing.nudgeDelta(keyCode: keyCode, distance: distance) else { return false }
        return editing.nudge(by: delta)
    }

    @discardableResult
    func keyUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == CanvasEventTranslator.spaceKeyCode else { return false }
        if let tool = activeTool as? any SpaceDragging, tool.isDragging {
            tool.spaceChanged(down: false)
            context.host.setNeedsOverlayDisplay()
            return true
        }
        perform(machine.spaceChanged(down: false))
        return true
    }

    /// Esc: the tool abandons its gesture; the rest of a drag is swallowed.
    func cancel() {
        activeTool.cancel()
        machine.cancel()
        context.host.setNeedsOverlayDisplay()
    }

    // MARK: Overlay

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        activeTool.drawOverlay(in: ctx, viewport: viewport)
    }
}
