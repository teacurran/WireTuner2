import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Perspective tool through the real event path (perspective.adoc; FX-044): AppKit events sent
/// to the document window reach the canvas, the tool manager's key routing and the tool, as a
/// person's presses and keys do -- the arrow keys mid-drag attach, kbd:[Space] flips (not the
/// temporary Hand), the built-in grid reshapes on the canvas, and attached objects follow the grid.
@Suite(.serialized) @MainActor struct PerspectiveEventPathTests {
    @MainActor
    final class World {
        let setup = SetupWindow(tools: [PointerTool.descriptor, PerspectiveTool.descriptor])
        let features: PerspectiveFeatures
        var window: DocumentWindowController { setup.window }
        var document: DocumentHandle { setup.document }
        var state: EngineState { document.state }
        var nsWindow: NSWindow { window.window! }

        init(showGrid: Bool = true) {
            let setup = setup
            features = PerspectiveFeatures(window: { [weak window = setup.window] in window })
            features.install(commands: setup.environment.commands)
            nsWindow.setContentSize(NSSize(width: 900, height: 900))
            nsWindow.contentView?.layoutSubtreeIfNeeded()
            if showGrid { features.toggleShown(window) }
            window.toolManager.select(PerspectiveTool.id)
        }

        func close() {
            PerspectiveTool.showsGrid = { _ in false }
            setup.close()
        }

        var page: Page { document.pageList.pages[0] }

        /// Fits the page in the canvas.
        func fitPage() {
            let size = window.canvas.viewport.size
            let rect = page.rect
            let zoom = min(size.width / (rect.width + 80), size.height / (rect.height + 80))
            window.canvas.setViewport(Viewport(scrollOrigin: Point(x: rect.midX - size.width / zoom / 2, y: rect.midY - size.height / zoom / 2), zoom: zoom, size: size))
        }

        func mouse(_ type: NSEvent.EventType, _ point: Point, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: setup.windowPoint(point), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        func key(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], up: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: up ? .keyUp : .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: nsWindow.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: keyCode)!
        }

        /// An arrow key as the keyboard sends it (function and numeric-pad flags).
        func arrow(_ keyCode: UInt16, up: Bool = false) -> NSEvent {
            let scalar: Int = switch keyCode {
            case 123: NSLeftArrowFunctionKey
            case 124: NSRightArrowFunctionKey
            case 125: NSDownArrowFunctionKey
            default: NSUpArrowFunctionKey
            }
            return key(String(UnicodeScalar(scalar)!), keyCode, [.function, .numericPad], up: up)
        }

        /// `event` as AppKit hands it to the canvas: a key first offered as a key equivalent (the
        /// window's views and the main menu, which must not take a bare arrow or Space), then to the
        /// canvas as first responder; the mouse to the canvas's handlers.
        func send(_ event: NSEvent) {
            let canvas = window.canvas
            switch event.type {
            case .keyDown:
                #expect(!nsWindow.performKeyEquivalent(with: event) && NSApp.mainMenu?.performKeyEquivalent(with: event) != true, "no key equivalent takes \(event.keyCode)")
                canvas.keyDown(with: event)
            case .keyUp: canvas.keyUp(with: event)
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            case .mouseMoved: canvas.mouseMoved(with: event)
            default: nsWindow.sendEvent(event)
            }
        }

        func press(_ point: Point, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) { send(mouse(.leftMouseDown, point, flags, clicks: clicks)) }
        func drag(_ point: Point, _ flags: NSEvent.ModifierFlags = []) { send(mouse(.leftMouseDragged, point, flags)) }
        func release(_ point: Point, _ flags: NSEvent.ModifierFlags = []) async {
            send(mouse(.leftMouseUp, point, flags))
            await document.settle()
        }

        func bounds(_ node: OpID) -> Rect? { document.object(for: SelectionID(node))?.bounds }
        func wrapper(_ node: OpID) -> OpID? { PerspectiveReading.wrapper(of: node, in: state) }
        var status: String { window.statusBar.message.stringValue }
    }

    @Test func anArrowKeyMidDragAttachesThroughTheWindowsKeyRouting() async throws {
        let world = World()
        defer { world.close() }
        world.fitPage()
        let page = world.page.rect
        let rect = try #require(await world.document.addRectangles([Rect(x: page.minX + 100, y: page.midY + 60, width: 60, height: 40)]).first?.opID)
        let start = try #require(world.bounds(rect)).center
        world.press(start)
        #expect(world.status.contains("arrow key"), "the status line says how to attach: \(world.status)")
        let target = Point(x: page.minX + 150, y: page.midY + 120)
        world.drag(target)
        world.send(world.arrow(123))
        world.send(world.arrow(123, up: true))
        #expect(world.window.toolManager.activeToolID == PerspectiveTool.id)
        #expect(world.status.contains("left wall"), "\(world.status)")
        world.drag(Point(x: target.x + 1, y: target.y))
        await world.release(Point(x: target.x + 1, y: target.y))
        let wrapper = try #require(world.wrapper(rect), "the arrow key reached the tool and the release attached the object")
        #expect(world.state.props(wrapper).perspective.plane == .leftWall && world.document.undoTitle == "Undo Attach to perspective grid")
        // The object lands under the pointer where it was grabbed, not with its corner there.
        let drawn = try #require(world.bounds(wrapper))
        #expect(drawn.insetBy(dx: -2, dy: -2).contains(Point(x: target.x + 1, y: target.y)), "\(drawn) holds the pointer")
        // Without a press the arrow keys still nudge the selection.
        world.window.selection.model.set(Selection([SelectionID(wrapper)]))
        world.send(world.arrow(124))
        _ = await world.window.objectEditing.endNudging()?.value
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Move", "a nudge takes it off the grid, as FreeHand's arrow keys do")
    }

    @Test func spaceMidDragFlipsInsteadOfTakingTheHand() async throws {
        let world = World()
        defer { world.close() }
        world.fitPage()
        let page = world.page.rect
        let rect = try #require(await world.document.addRectangles([Rect(x: page.minX + 100, y: page.midY + 60, width: 60, height: 40)]).first?.opID)
        _ = await world.document.perform(AttachToPerspectiveGrid([rect], plane: .floorRight, at: Point(x: 1, y: 1))).value
        let wrapper = try #require(world.wrapper(rect))
        let center = try #require(world.bounds(wrapper)).center
        world.press(center)
        world.send(world.key(" ", 49))
        #expect(world.window.toolManager.activeToolID == PerspectiveTool.id, "Space mid-press is the flip, not the Hand")
        world.send(world.key(" ", 49, up: true))
        world.send(world.key("2", 19))
        await world.release(center)
        #expect(world.state.props(wrapper).perspective.flipped && world.document.undoTitle == "Undo Flip on grid")
        #expect(world.state.props(wrapper).perspective.cellWidth > 0)
        // Space with nothing pressed is still the temporary Hand.
        world.send(world.key(" ", 49))
        #expect(world.window.toolManager.activeToolID == .hand)
        world.send(world.key(" ", 49, up: true))
        #expect(world.window.toolManager.activeToolID == PerspectiveTool.id)
    }

    @Test func theBuiltInGridReshapesOnTheCanvasAndAttachedObjectsFollow() async throws {
        let world = World()
        defer { world.close() }
        world.fitPage()
        let page = world.page
        let rect = try #require(await world.document.addRectangles([Rect(x: page.rect.minX + 100, y: page.rect.midY + 60, width: 60, height: 40)]).first?.opID)
        _ = await world.document.perform(AttachToPerspectiveGrid([rect], plane: .leftWall, at: Point(x: -6, y: 1))).value
        let wrapper = try #require(world.wrapper(rect))
        let before = try #require(world.bounds(wrapper))
        #expect(PerspectiveReading.grids(world.state).isEmpty, "the page uses the built-in grid")
        // Drag the left vanishing point of the built-in grid.
        let drawing = PerspectiveGridDrawing(page: page, state: world.state)
        let vp = drawing.spec.leftVP
        world.send(world.mouse(.mouseMoved, vp))
        world.press(vp)
        let to = Point(x: vp.x + 40, y: vp.y - 30)
        world.drag(to)
        await world.release(to)
        let grids = PerspectiveReading.grids(world.state)
        #expect(grids.count == 1 && world.document.undoTitle == "Undo Move vanishing point", "\(world.document.undoTitle) \(world.status)")
        #expect(PerspectiveReading.grid(of: world.page, in: world.state) == grids.first?.id)
        let moved = PerspectiveGridDrawing(page: world.page, state: world.state).spec.leftVP
        #expect(abs(moved.x - to.x) < 0.01 && abs(moved.y - to.y) < 0.01)
        // The object attached to the built-in grid is drawn on the reshaped grid.
        let after = try #require(world.bounds(wrapper))
        #expect(after != before, "the attached object re-projects: \(before) → \(after)")
        // One undo puts the built-in grid back, and the object where it was.
        _ = await world.document.undo().value
        await world.document.settle()
        #expect(PerspectiveReading.grids(world.state).isEmpty)
        let undone = try #require(world.bounds(wrapper))
        #expect(abs(undone.minX - before.minX) < 0.01 && abs(undone.minY - before.minY) < 0.01)
    }

    /// Renders `draw` over a white page-sized bitmap, one point a pixel; written as a PNG to the
    /// folder in the `PSP_DUMP` environment variable when it is set.
    static func render(_ name: String, size: Size, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        // View points are y down.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        let image = ctx.makeImage()!
        if let folder = ProcessInfo.processInfo.environment["PSP_DUMP"] {
            let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        return image
    }

    /// How many pixels of `image` in view rectangle `rect` are near `color`.
    static func count(_ color: Color, in image: CGImage, rect: Rect) -> Int {
        let data = CFDataGetBytePtr(image.dataProvider!.data!)!
        let row = image.bytesPerRow
        var hits = 0
        for y in max(0, Int(rect.minY))..<min(image.height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(image.width, Int(rect.maxX)) {
                let p = data + y * row + x * 4
                let r = Double(p[0]) / 255, g = Double(p[1]) / 255, b = Double(p[2]) / 255
                // Thin antialiased lines over white: the tint's hue, however faint.
                let c = color.components
                let tint = [r, g, b].map { 1 - $0 }, want = [c[0], c[1], c[2]].map { 1 - $0 }
                let strength = tint.max()!
                guard strength > 0.06 else { continue }
                if zip(tint, want).allSatisfy({ abs($0 / strength - $1 / want.max()!) < 0.35 }) { hits += 1 }
            }
        }
        return hits
    }

    @Test func theBuiltInGridDrawsEachWallBetweenItsEdgeAndItsVanishingPoint() async throws {
        let world = World()
        defer { world.close() }
        let page = world.page
        let drawing = PerspectiveGridDrawing(page: page, state: world.state)
        let viewport = Viewport(scrollOrigin: page.rect.minPoint, zoom: 1, size: Size(width: page.rect.width, height: page.rect.height))
        let image = Self.render("builtin-grid", size: Size(width: page.rect.width, height: page.rect.height)) { PerspectiveFeatures.draw(drawing, in: $0, viewport: viewport) }
        let spec = drawing.spec
        let corner = spec.leftWallX - page.rect.minX
        let top = 0.0, horizon = spec.horizonY - page.rect.minY
        // Above the horizon (walls only, no floor): the left wall's red left of the corner, the
        // right wall's blue right of it -- as FreeHand's default grid draws them.
        let leftSide = Rect(x: 0, y: top, width: corner - 4, height: horizon - top - 4)
        let rightSide = Rect(x: corner + 4, y: top, width: page.rect.width - corner - 4, height: horizon - top - 4)
        let redLeft = Self.count(PerspectiveGridDrawing.leftColor, in: image, rect: leftSide)
        let redRight = Self.count(PerspectiveGridDrawing.leftColor, in: image, rect: rightSide)
        let blueRight = Self.count(PerspectiveGridDrawing.rightColor, in: image, rect: rightSide)
        let blueLeft = Self.count(PerspectiveGridDrawing.rightColor, in: image, rect: leftSide)
        #expect(redLeft > 100 && redRight < redLeft / 10, "left wall: \(redLeft) px left of the corner, \(redRight) right")
        #expect(blueRight > 100 && blueLeft < blueRight / 10, "right wall: \(blueRight) px right of the corner, \(blueLeft) left")
    }
}
