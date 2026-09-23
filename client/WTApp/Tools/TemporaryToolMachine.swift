import Foundation

/// The keys that push a temporary tool (toolbars.adoc, "To use the previous tool for one
/// action"): Space for the Hand, Command for the Pointer, Command+Space for the Zoom tool
/// (Option with it zooms out, delivered to the Zoom tool as a modifier).
enum TemporaryTrigger: Hashable, Sendable {
    case space
    case command
    case commandSpace

    var tool: ToolID {
        switch self {
        case .space: .hand
        case .command: .pointer
        case .commandSpace: .zoom
        }
    }
}

/// What the tool manager must do after an input.
enum ToolMachineEffect: Equatable, Sendable {
    /// End the gesture in progress on the current tool as if the button were released at the
    /// last pointer position, so its change is committed before the tool goes away.
    case finishDrag
    /// Deactivate `from` and activate `to`.
    case activate(from: ToolID, to: ToolID)
}

/// The temporary-tool state machine.  Pure; the tool manager feeds it inputs and performs the
/// effects.
///
/// Rules:
/// * The effective tool is the temporary tool of the held keys, or the base tool.  A trigger
///   whose tool is the base tool pushes nothing (Command with the Pointer active).
/// * A temporary tool is pushed only between drags: Command pressed mid-drag is a modifier
///   for the current tool (moving.adoc: Command "held before pressing").
/// * Releasing the key of the temporary tool restores the previous tool even mid-drag
///   (toolbars.adoc, "Client"): the drag is finished first, and the rest of it is swallowed
///   until the button comes up.
/// * Any other key change mid-drag waits for the button to come up.
struct TemporaryToolMachine: Equatable, Sendable {
    private(set) var baseTool: ToolID
    private(set) var temporary: TemporaryTrigger?
    private(set) var spaceDown = false
    private(set) var commandDown = false
    private(set) var isDragging = false
    /// After a mid-drag restore: drag events are dropped until mouse-up.
    private(set) var isSuppressingDrag = false

    init(baseTool: ToolID) {
        self.baseTool = baseTool
    }

    var effectiveTool: ToolID { temporary?.tool ?? baseTool }

    /// The trigger the held keys ask for.
    var desiredTrigger: TemporaryTrigger? {
        let trigger: TemporaryTrigger? =
            spaceDown ? (commandDown ? .commandSpace : .space) : (commandDown ? .command : nil)
        guard let trigger, trigger.tool != baseTool else { return nil }
        return trigger
    }

    private func isHeld(_ trigger: TemporaryTrigger) -> Bool {
        switch trigger {
        case .space: spaceDown
        case .command: commandDown
        case .commandSpace: spaceDown && commandDown
        }
    }

    // MARK: Inputs

    mutating func select(_ tool: ToolID) -> [ToolMachineEffect] {
        let before = effectiveTool
        baseTool = tool
        // Mid-drag the temporary tool neither appears nor goes; mouse-up re-evaluates.
        if !isDragging { temporary = desiredTrigger }
        return transition(from: before)
    }

    mutating func spaceChanged(down: Bool) -> [ToolMachineEffect] {
        guard down != spaceDown else { return [] }
        spaceDown = down
        return keysChanged()
    }

    mutating func commandChanged(down: Bool) -> [ToolMachineEffect] {
        guard down != commandDown else { return [] }
        commandDown = down
        return keysChanged()
    }

    mutating func mouseDown() {
        isDragging = true
        isSuppressingDrag = false
    }

    /// Returns whether the mouse-up belongs to a swallowed drag, and the effects of key
    /// changes that waited for it.
    mutating func mouseUp() -> (swallowed: Bool, effects: [ToolMachineEffect]) {
        let swallowed = isSuppressingDrag
        isDragging = false
        isSuppressingDrag = false
        let before = effectiveTool
        temporary = desiredTrigger
        return (swallowed, transition(from: before))
    }

    /// Esc mid-drag: the tool cancels and the rest of the drag is swallowed.
    mutating func cancel() {
        if isDragging { isSuppressingDrag = true }
    }

    // MARK: Transitions

    private mutating func keysChanged() -> [ToolMachineEffect] {
        let before = effectiveTool
        if isDragging {
            guard let current = temporary, !isHeld(current), !isSuppressingDrag else { return [] }
            temporary = desiredTrigger
            isSuppressingDrag = true
            return [.finishDrag] + transition(from: before)
        }
        temporary = desiredTrigger
        return transition(from: before)
    }

    private func transition(from before: ToolID) -> [ToolMachineEffect] {
        effectiveTool == before ? [] : [.activate(from: before, to: effectiveTool)]
    }
}
