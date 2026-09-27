import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// COLOR-012's remainder: the Eyedropper's colour dragged out of the canvas onto the panels.
@Suite(.serialized) @MainActor struct EyedropperDragOutTests {
    @Test func aLiftedColourLeavingTheCanvasBecomesAColourDrag() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let origin = setup.page.origin
        let square = await setup.document.addRectangles([Rect(x: origin.x + 100, y: origin.y + 100, width: 60, height: 60)])[0].opID
        let tool = EyedropperTool(defaultSpace: { .sRGB }, pick: { _ in })
        setup.window.toolManager.push(tool)
        let dragOut = EyedropperDragOut()
        var sessions: [(NSView, NSDraggingItem)] = []
        dragOut.startSession = { view, item, _, _ in sessions.append((view, item)) }
        ImageLinkWindowParts.attach(setup.window, dragOut: dragOut)
        // The canvas holds the drag-out (onLeaveCanvas), which holds the sessions, which hold the canvas.
        defer { sessions = [] }
        let window = try #require(setup.window.window)
        let outside = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: -50, y: -50), modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(setup.window.canvas.leftCanvas(outside))
        // No colour lifted: nothing.
        #expect(!dragOut.begin(setup.window, event: outside))
        #expect(setup.window.canvas.onLeaveCanvas?(outside) == false)
        // Lift the square's white fill and drag it off the canvas.
        let center = Objects.bounds(of: square, in: setup.document.state)!.center
        setup.window.toolManager.mouseDown(setup.event(center))
        setup.window.toolManager.mouseDragged(setup.event(Point(x: center.x + 20, y: center.y)))
        #expect(tool.isDragging)
        setup.window.canvas.mouseDragged(with: outside)
        #expect(sessions.count == 1 && sessions.first?.0 === setup.window.canvas)
        #expect(tool.sample == nil, "the tool's own drag ended without writing")
        let payload = try #require(dragOut.payload)
        #expect(payload.color?.red == 1 && payload.document == setup.document.id)
        let item = EyedropperDragOut.item(payload)
        #expect(item.data(forType: ColorDrag.type).flatMap(ColorRefPasteboard.init(data:)) == payload && item.data(forType: .color) != nil)
        #expect(EyedropperDragOut.operation == .copy)
        #expect(EyedropperDragOut.chip(nil).size == NSSize(width: 16, height: 16))
        for color in [nil, RenderColor(white: 0.5)] { _ = EyedropperDragOut.chip(color).cgImage(forProposedRect: nil, context: nil, hints: nil) }
    }
}
