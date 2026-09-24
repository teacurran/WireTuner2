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
    /// A tool pushed over the others until it pops itself (the import pointer, IMG-005): it gets
    /// every event, and the temporary tools wait until it is gone.
    private(set) var pushedTool: (any Tool)?
    private var instances: [ToolID: any Tool] = [:]
    private var lastEvent: CanvasEvent?
    /// Handles drawn over the selection tools (effect centres, gradient handles), pressed first.
    var handleLayers: [any CanvasHandleLayer] = CanvasHandleLayers.standard()
    /// The layer whose handle is being dragged.
    private(set) var handleDrag: (any CanvasHandleLayer)?
    /// The focus whose changes redraw the overlay (the handles follow the Object panel's row).
    private let focus: InspectorFocus
    private var focusObservation: UUID?

    init(registry: ToolRegistry, context: ToolContext, initialTool: ToolID = .pointer, focus: InspectorFocus = .shared,
         runShortcut: @escaping @MainActor (KeyEquivalent) -> Bool = { _ in false }) {
        self.registry = registry
        self.context = context
        self.runShortcut = runShortcut
        self.focus = focus
        let initial = registry.contains(initialTool) ? initialTool : .pointer
        machine = TemporaryToolMachine(baseTool: initial)
        let tool = registry.makeTool(initial)
        activeTool = tool
        instances[initial] = tool
        tool.activate(in: context)
        let host = context.host
        focusObservation = focus.observe { [weak host] in host?.setNeedsOverlayDisplay() }
    }

    isolated deinit {
        if let focusObservation { focus.stopObserving(focusObservation) }
    }

    /// Whether the handle layers take presses and draw: under the Pointer and Subselect tools,
    /// not while a tool is pushed.
    var handlesApply: Bool { pushedTool == nil && CanvasHandleLayers.tools.contains(activeToolID) }

    var baseToolID: ToolID { machine.baseTool }
    var activeToolID: ToolID { activeTool.toolID }
    var isTemporary: Bool { machine.temporary != nil || pushedTool != nil }
    var cursor: NSCursor { activeTool.cursor }

    // MARK: Selection

    /// Makes `id` the base tool (a click in the Tools panel, a tool shortcut).
    func select(_ id: ToolID) {
        guard registry.contains(id) else { return }
        // Choosing a tool ends a pushed one (Esc's effect), then selects as usual.
        if let pushedTool {
            pushedTool.cancel()
            pop(pushedTool)
        }
        perform(machine.select(id))
    }

    /// Pushes `tool` over the current one (client.adoc, "Tools": the import pointer is pushed
    /// temporarily); it runs until `pop`, which restores the tool the keys and the Tools panel say.
    func push(_ tool: any Tool) {
        activeTool.deactivate()
        pushedTool = tool
        switchTo(tool)
    }

    /// Removes the pushed `tool` (another tool is left alone) and restores the effective tool.
    func pop(_ tool: any Tool) {
        guard let pushedTool, pushedTool === tool else { return }
        tool.deactivate()
        self.pushedTool = nil
        switchTo(self.tool(for: machine.effectiveTool))
    }

    private func switchTo(_ tool: any Tool) {
        activeTool = tool
        tool.activate(in: context)
        context.host.toolCursorDidChange()
        context.host.setNeedsOverlayDisplay()
        onToolChange?(tool.toolID)
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
                // A pushed tool stays until it pops; `pop` then restores the machine's tool.
                guard pushedTool == nil else { continue }
                activeTool.deactivate()
                switchTo(tool(for: to))
            }
        }
    }

    // MARK: Pointer events

    func mouseDown(_ event: CanvasEvent) {
        if handlesApply, let layer = handleLayers.first(where: { $0.press(event, context: context) }) {
            handleDrag = layer
            publishInfo(event)
            context.host.setNeedsOverlayDisplay()
            return
        }
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
        if let handleDrag {
            handleDrag.drag(event, context: context)
            publishInfo(event)
            context.host.setNeedsOverlayDisplay()
            return
        }
        guard !machine.isSuppressingDrag else { return }
        lastEvent = event
        activeTool.mouseDragged(event)
        publishInfo(event)
        context.host.setNeedsOverlayDisplay()
    }

    func mouseUp(_ event: CanvasEvent) {
        if let handleDrag {
            self.handleDrag = nil
            handleDrag.release(event, context: context)
            publishInfo(event)
            context.host.setNeedsOverlayDisplay()
            return
        }
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
        // While text is edited Command is for the text keys (Cmd-arrows), not the temporary Pointer.
        if !isEditingText { perform(machine.commandChanged(down: modifiers.contains(.command))) }
        context.host.setNeedsOverlayDisplay()
    }

    /// Whether the active tool is editing text: every key but kbd:[Esc] is typing.
    var isEditingText: Bool { (activeTool as? any TextInputHandling)?.isEditingText == true }

    /// The tool the canvas's text input client talks to, while it edits text.
    var textInput: (any TextInputHandling)? {
        (activeTool as? any TextInputHandling).flatMap { $0.isEditingText ? $0 : nil }
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
        if event.keyCode == CanvasEventTranslator.spaceKeyCode, !isEditingText {
            if let tool = activeTool as? any SpaceDragging, tool.isDragging {
                if !event.isARepeat { tool.spaceChanged(down: true) }
                context.host.setNeedsOverlayDisplay()
                return true
            }
            if !event.isARepeat { perform(machine.spaceChanged(down: true)) }
            return true
        }
        // A composition takes kbd:[Esc] itself (the input method cancels it).
        if event.keyCode == CanvasEventTranslator.escapeKeyCode, textInput?.hasMarkedText == true, activeTool.keyDown(event) {
            context.host.setNeedsOverlayDisplay()
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
        guard event.keyCode == CanvasEventTranslator.spaceKeyCode, !isEditingText else { return false }
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
        if let handleDrag {
            self.handleDrag = nil
            handleDrag.cancel(context: context)
        }
        activeTool.cancel()
        machine.cancel()
        context.host.setNeedsOverlayDisplay()
    }

    // MARK: Overlay

    func drawOverlay(in ctx: CGContext, viewport: Viewport) {
        if handlesApply {
            for layer in handleLayers { layer.draw(in: ctx, viewport: viewport, context: context) }
        }
        activeTool.drawOverlay(in: ctx, viewport: viewport)
    }
}
