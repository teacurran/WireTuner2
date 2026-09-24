import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// ATTR-025: the gradient form and the ramp's stop gestures -- click, drag, kbd:[Cmd]-drag copy,
/// drag-off removal, colour drops -- verified against the stored stops.
@Suite @MainActor struct GradientEditorTests {
    static let red = Appearances.inline(red: 1, green: 0, blue: 0)
    static let blue = Appearances.inline(red: 0, green: 0, blue: 1)

    /// A rectangle whose fill has been switched to Gradient from the *Fill type* pop-up.
    static func fixture() async -> AttributeFixture {
        let fixture = await AttributeFixture.make()
        let fill = FillEditorModel(context: fixture.context(0))
        _ = await fixture.document.perform(fill.setKind(.gradient)).value
        return fixture
    }

    static func model(_ fixture: AttributeFixture, ids: [SelectionID]? = nil) -> GradientEditorModel {
        GradientEditorModel(context: fixture.context(0, ids: ids))
    }

    static func stops(_ fixture: AttributeFixture) -> [GradientRampStop] {
        GradientReading.ramp(fixture.stack()[0].fill.settings.gradient)
    }

    static func perform(_ command: (any WTModel.Command)?, _ fixture: AttributeFixture) async {
        _ = await fixture.document.perform(command!).value
    }

    /// A controller over the ramp of `fixture`, 208 points wide (offset = (x − 8) / 192).
    static func controller(_ fixture: AttributeFixture) -> GradientRampController {
        let controller = GradientRampController()
        controller.model = model(fixture)
        controller.width = 208
        return controller
    }

    static func x(_ offset: Double) -> Double { 8 + offset * 192 }
    static let thumbY = 25.0

    @Test func choosingGradientStartsARampAndTheFormWritesTypeBehaviorAndCount() async throws {
        let fixture = await Self.fixture()
        var model = Self.model(fixture)
        #expect(model.type == .linear && model.behavior == .normal && model.count == 1 && !model.countApplies)
        #expect(Self.stops(fixture).count == 2 && fixture.document.undoTitle == "Undo Change fill type")
        for command in [model.setType(.radial), model.setBehavior(.reflect), model.setCount(7)] {
            await Self.perform(command, fixture)
        }
        model = Self.model(fixture)
        #expect(model.type == .radial && model.behavior == .reflect && model.count == 7 && model.countApplies)
        AttributeFixture.render(FillEditorView(model: FillEditorModel(context: fixture.context(0))))
        // Back to Basic: the ramp's left colour.
        let left = Self.stops(fixture)[0].color
        await Self.perform(FillEditorModel(context: fixture.context(0)).setKind(.basic), fixture)
        #expect(fixture.stack()[0].fill.settings.basic.color == left && FillEditorModel(context: fixture.context(0)).kind == .basic)
        // Several objects: the form edits all of them, the ramp one at a time.
        let two = await AttributeFixture.make(2)
        for index in 0..<2 {
            _ = await two.document.perform(ChooseGradient(two.list([two.ids[index]]).rows[0].targets.map(\.pair))).value
        }
        let both = GradientEditorModel(context: two.context(0))
        #expect(both.target == nil && both.stops.isEmpty && both.move(OpID(counter: 1, replica: 1), to: 0.5) == nil)
        #expect(both.copy(OpID(counter: 1, replica: 1), to: 0.5) == nil && both.remove(OpID(counter: 1, replica: 1)) == nil)
        #expect(both.add(at: 0.5, color: Self.red) == nil && both.recolor(OpID(counter: 1, replica: 1), Self.red) == nil)
        AttributeFixture.render(GradientEditorView(model: both))
    }

    @Test func eachStopGestureWritesTheStops() async throws {
        let fixture = await Self.fixture()
        var controller = Self.controller(fixture)
        var selected: [OpID?] = []
        controller.onSelect = { selected.append($0) }
        let stops = Self.stops(fixture)
        // A click on a thumb selects the stop and writes nothing.
        #expect(controller.mouseDown(x: Self.x(0), y: Self.thumbY, command: false))
        #expect(controller.mouseUp(x: Self.x(0), y: Self.thumbY) == nil && selected == [stops[0].id] && controller.selected == stops[0].id)
        #expect(!controller.mouseDown(x: Self.x(0.5), y: Self.thumbY, command: false), "no thumb there")
        #expect(!controller.mouseDown(x: Self.x(0), y: 2, command: false), "the bar is not a thumb")
        // Dragging an end stop inward leaves a copy at the end.
        controller.mouseDown(x: Self.x(0), y: Self.thumbY, command: false)
        controller.mouseDragged(x: Self.x(0.25), y: Self.thumbY)
        #expect(controller.shownStops[0].offset == 0.25)
        await Self.perform(controller.mouseUp(x: Self.x(0.25), y: Self.thumbY), fixture)
        var now = Self.stops(fixture)
        #expect(now.count == 3 && now.map(\.offset) == [0, 0.25, 1] && fixture.document.undoTitle == "Undo Move color stop")
        // Cmd-drag copies.
        controller = Self.controller(fixture)
        controller.mouseDown(x: Self.x(0.25), y: Self.thumbY, command: true)
        await Self.perform(controller.mouseUp(x: Self.x(0.6), y: Self.thumbY), fixture)
        now = Self.stops(fixture)
        #expect(now.map(\.offset) == [0, 0.25, 0.6, 1] && fixture.document.undoTitle == "Undo Copy color stop")
        // Dragged off the ramp: removed; an end stop is not, nor a copy dragged off.
        controller = Self.controller(fixture)
        controller.mouseDown(x: Self.x(0.6), y: Self.thumbY, command: false)
        await Self.perform(controller.mouseUp(x: Self.x(0.6), y: 90), fixture)
        #expect(Self.stops(fixture).count == 3 && fixture.document.undoTitle == "Undo Remove color stop")
        controller = Self.controller(fixture)
        controller.mouseDown(x: Self.x(1), y: Self.thumbY, command: false)
        #expect(controller.mouseUp(x: Self.x(1), y: -40) == nil)
        controller.mouseDown(x: Self.x(0.25), y: Self.thumbY, command: true)
        #expect(controller.mouseUp(x: Self.x(0.25), y: -40) == nil)
        controller.mouseDragged(x: 0, y: 0)
        #expect(controller.mouseUp(x: 0, y: 0) == nil)
        // A colour dropped on a thumb recolours it; elsewhere it adds a stop.
        controller = Self.controller(fixture)
        await Self.perform(controller.drop(Self.red, x: Self.x(1), y: Self.thumbY), fixture)
        #expect(Self.stops(fixture).last?.color == Self.red && fixture.document.undoTitle == "Undo Change stop color")
        await Self.perform(controller.drop(Self.blue, x: Self.x(0.75), y: 4), fixture)
        #expect(Self.stops(fixture).map(\.offset) == [0, 0.25, 0.75, 1] && fixture.document.undoTitle == "Undo Add color stop")
        // Two stops left: nothing more is removed.
        let model = Self.model(fixture)
        #expect(model.isEnd(model.stops[0].id) && !model.isEnd(model.stops[1].id))
        #expect(GradientEditorModel.clamp(3) == 1 && controller.offset(atX: -50) == 0)
    }

    @Test func aRemoteStopInsertDoesNotDisturbADrag() async throws {
        let fixture = await Self.fixture()
        let controller = Self.controller(fixture)
        controller.mouseDown(x: Self.x(1), y: Self.thumbY, command: false)
        controller.mouseDragged(x: Self.x(0.8), y: Self.thumbY)
        let target = try #require(Self.model(fixture).target)
        try await fixture.receive(AddGradientStop(node: target.node, row: target.row, offset: 0.5, color: Self.red))
        controller.model = Self.model(fixture)
        let rounded = { (stops: [GradientRampStop]) in stops.map { ($0.offset * 1000).rounded() / 1000 } }
        #expect(rounded(controller.shownStops) == [0, 0.5, 0.8], "the dragged stop stays under the pointer")
        await Self.perform(controller.mouseUp(x: Self.x(0.8), y: Self.thumbY), fixture)
        #expect(rounded(Self.stops(fixture)) == [0, 0.5, 0.8, 1])
    }

    @Test func theRampViewDrawsAndForwardsItsGestures() async throws {
        let fixture = await Self.fixture()
        let view = GradientRampView(controller: GradientRampController())
        view.frame = NSRect(x: 0, y: 0, width: 208, height: GradientRampController.height)
        var performed: [any WTModel.Command] = []
        var selected: [OpID?] = []
        GradientRamp(model: Self.model(fixture)) { selected.append($0) }.update(view)
        view.perform = { performed.append($0) }
        #expect(view.isFlipped)
        view.press(CGPoint(x: Self.x(0), y: Self.thumbY), command: false)
        view.move(CGPoint(x: Self.x(0.3), y: Self.thumbY))
        view.release(CGPoint(x: Self.x(0.3), y: Self.thumbY))
        #expect(performed.count == 1 && selected.count == 1)
        view.release(CGPoint(x: 0, y: 0))
        #expect(performed.count == 1)
        // Drops read the colour from the pasteboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.ramp.\(UUID().uuidString)"))
        pasteboard.declareTypes([.color], owner: nil)
        NSColor.red.write(to: pasteboard)
        #expect(view.draggingEntered(PasteboardDragging(pasteboard, at: .zero)) == .copy)
        view.readColor = { GradientRamp.color(from: $0, document: fixture.document) }
        #expect(view.performDragOperation(PasteboardDragging(pasteboard, at: NSPoint(x: Self.x(0.5), y: 4))))
        #expect(performed.count == 2)
        #expect(!view.drop(NSPasteboard(name: NSPasteboard.Name("WireTunerTests.empty.\(UUID().uuidString)")), at: .zero))
        // Drawing: the bar and thumbs into a bitmap.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 208, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        view.draw(view.bounds)
        // Mouse events convert through the window-less view.
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: Self.x(1), y: 11), modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: event)
        view.mouseDragged(with: event)
        view.mouseUp(with: event)
        // The form with a selected stop shows its colour; recolouring writes it.
        AttributeFixture.render(GradientEditorView(model: Self.model(fixture)))
        let stop = Self.stops(fixture)[0].id
        GradientEditorView.recolor(stop, model: Self.model(fixture))(Self.blue)
        await fixture.document.settle()
        #expect(Self.stops(fixture)[0].color == Self.blue)
        _ = GradientRamp(model: Self.model(fixture)) { _ in }.makeCoordinator()
    }
}
