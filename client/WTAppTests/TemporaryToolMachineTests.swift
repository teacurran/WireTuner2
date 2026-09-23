import Testing
@testable import WireTuner

@Suite struct TemporaryToolMachineTests {
    @Test func spacePushesTheHandAndReleaseRestores() {
        var machine = TemporaryToolMachine(baseTool: .rectangle)
        #expect(machine.spaceChanged(down: true) == [.activate(from: .rectangle, to: .hand)])
        #expect(machine.effectiveTool == .hand)
        #expect(machine.spaceChanged(down: true) == [], "key repeat changes nothing")
        #expect(machine.spaceChanged(down: false) == [.activate(from: .hand, to: .rectangle)])
        #expect(machine.effectiveTool == .rectangle)
        #expect(machine.temporary == nil)
    }

    @Test func commandPushesThePointerAndCommandSpaceTheZoomTool() {
        var machine = TemporaryToolMachine(baseTool: .rectangle)
        #expect(machine.commandChanged(down: true) == [.activate(from: .rectangle, to: .pointer)])
        #expect(machine.spaceChanged(down: true) == [.activate(from: .pointer, to: .zoom)])
        #expect(machine.temporary == .commandSpace)
        #expect(machine.commandChanged(down: false) == [.activate(from: .zoom, to: .hand)])
        #expect(machine.spaceChanged(down: false) == [.activate(from: .hand, to: .rectangle)])
        #expect(machine.commandChanged(down: false) == [])
    }

    @Test func aTriggerForTheBaseToolPushesNothing() {
        var machine = TemporaryToolMachine(baseTool: .pointer)
        #expect(machine.commandChanged(down: true) == [])
        #expect(machine.temporary == nil)
        #expect(machine.spaceChanged(down: true) == [.activate(from: .pointer, to: .zoom)], "Command+Space still zooms")
        var hand = TemporaryToolMachine(baseTool: .hand)
        #expect(hand.spaceChanged(down: true) == [])
    }

    @Test func commandPressedMidDragIsAModifierNotASwitch() {
        var machine = TemporaryToolMachine(baseTool: .rectangle)
        machine.mouseDown()
        #expect(machine.commandChanged(down: true) == [])
        #expect(machine.effectiveTool == .rectangle)
        let up = machine.mouseUp()
        #expect(!up.swallowed)
        #expect(up.effects == [.activate(from: .rectangle, to: .pointer)], "the held key applies once the drag ends")
    }

    @Test func releasingTheTriggerMidDragFinishesTheDragAndRestores() {
        var machine = TemporaryToolMachine(baseTool: .rectangle)
        _ = machine.spaceChanged(down: true)
        machine.mouseDown()
        #expect(machine.isDragging)
        #expect(machine.spaceChanged(down: false) == [.finishDrag, .activate(from: .hand, to: .rectangle)])
        #expect(machine.isSuppressingDrag)
        let up = machine.mouseUp()
        #expect(up.swallowed)
        #expect(up.effects == [])
        #expect(!machine.isSuppressingDrag)
    }

    @Test func aSecondReleaseDuringASwallowedDragWaitsForMouseUp() {
        var machine = TemporaryToolMachine(baseTool: .rectangle)
        _ = machine.commandChanged(down: true)
        _ = machine.spaceChanged(down: true)
        machine.mouseDown()
        #expect(machine.commandChanged(down: false) == [.finishDrag, .activate(from: .zoom, to: .hand)])
        #expect(machine.spaceChanged(down: false) == [])
        #expect(machine.effectiveTool == .hand)
        #expect(machine.mouseUp().effects == [.activate(from: .hand, to: .rectangle)])
    }

    @Test func holdingTheTriggerThroughADragKeepsTheTool() {
        var machine = TemporaryToolMachine(baseTool: .rectangle)
        _ = machine.spaceChanged(down: true)
        machine.mouseDown()
        #expect(machine.commandChanged(down: true) == [], "no switch mid-drag")
        #expect(machine.mouseUp().effects == [.activate(from: .hand, to: .zoom)])
    }

    @Test func selectingChangesTheBaseTool() {
        var machine = TemporaryToolMachine(baseTool: .pointer)
        #expect(machine.select(.rectangle) == [.activate(from: .pointer, to: .rectangle)])
        #expect(machine.select(.rectangle) == [])
        _ = machine.spaceChanged(down: true)
        #expect(machine.select(.zoom) == [], "the Hand stays in front while Space is held")
        #expect(machine.baseTool == .zoom)
        #expect(machine.select(.hand) == [], "selecting the temporary tool's own tool")
        #expect(machine.temporary == nil)
        machine.mouseDown()
        _ = machine.select(.rectangle)
        #expect(machine.effectiveTool == .rectangle, "no temporary: the base changes even mid-drag")
        _ = machine.mouseUp()
        #expect(machine.effectiveTool == .hand, "Space is still held")
        machine.mouseDown()
        #expect(machine.select(.pointer) == [], "mid-drag with a temporary tool the front tool stays")
        #expect(machine.baseTool == .pointer)
    }

    @Test func cancelSwallowsTheRestOfADragOnly() {
        var machine = TemporaryToolMachine(baseTool: .rectangle)
        machine.cancel()
        #expect(!machine.isSuppressingDrag)
        machine.mouseDown()
        machine.cancel()
        #expect(machine.isSuppressingDrag)
        #expect(machine.mouseUp().swallowed)
        #expect(TemporaryTrigger.space.tool == .hand)
        #expect(TemporaryTrigger.command.tool == .pointer)
        #expect(TemporaryTrigger.commandSpace.tool == .zoom)
    }
}
