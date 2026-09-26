import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// WEB-022: the Link tool.
@Suite(.serialized) @MainActor struct LinkToolTests {
    /// A window with two pages and a filled square on the first, and a Link tool in it.
    static func world() async throws -> (SetupWindow, OpID, [Page], LinkTool) {
        let setup = SetupWindow()
        await setup.document.addPage().value
        await setup.document.settle()
        let pages = setup.document.pageList.pages
        let origin = pages[0].origin
        let square = await setup.document.addRectangles([Rect(x: origin.x + 100, y: origin.y + 100, width: 60, height: 60)])[0].opID
        let tool = LinkTool()
        tool.activate(in: setup.window.toolManager.context)
        return (setup, square, pages, tool)
    }

    static func center(_ page: Page) -> Point { Point(x: page.rect.midX, y: page.rect.midY) }
    static func center(_ node: OpID, _ setup: SetupWindow) -> Point { Objects.bounds(of: node, in: setup.document.state)!.center }

    static func drag(_ tool: LinkTool, _ setup: SetupWindow, from: Point, to: Point, _ modifiers: KeyModifiers = []) async {
        tool.mouseDown(setup.event(from))
        tool.mouseDragged(setup.event(to, modifiers))
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: setup.window.viewport)
        tool.mouseUp(setup.event(to, modifiers))
        await setup.document.settle()
    }

    static func target(_ node: OpID, _ setup: SetupWindow) -> OpID? { NavigationInfo(node, in: setup.document.state).goToPage }

    @Test func dragToAnotherPageLinksInOneChangeAndTheOwnPageClears() async throws {
        let (setup, square, pages, tool) = try await Self.world()
        defer { setup.close() }
        let before = setup.document.changeCount
        tool.mouseDown(setup.event(Self.center(square, setup)))
        tool.mouseDragged(setup.event(Self.center(pages[1])))
        #expect(tool.targetPage()?.id == pages[1].id && tool.isDragging && tool.hasSomethingToCancel)
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: setup.window.viewport)
        #expect(setup.document.changeCount == before, "nothing is written while dragging")
        tool.mouseUp(setup.event(Self.center(pages[1])))
        await setup.document.settle()
        #expect(Self.target(square, setup) == pages[1].id)
        #expect(setup.document.changeCount == before + 1 && setup.document.undoTitle == "Undo Link to page 2")
        // The badge is taken before the object: dragged to an empty spot on the own page, it clears.
        let badge = try #require(LinkBadges.badges(setup.document).first)
        let badgePoint = setup.window.viewport.toPasteboard(LinkBadges.rect(badge, viewport: setup.window.viewport).center)
        #expect(LinkTool.target(at: setup.event(badgePoint), context: setup.window.toolManager.context) == .source(square, badge: true))
        await Self.drag(tool, setup, from: badgePoint, to: Point(x: pages[0].rect.minX + 20, y: pages[0].rect.maxY - 20))
        #expect(Self.target(square, setup) == nil && setup.document.undoTitle == "Undo Remove page link")
        // Option-drop on the own page links to it.
        await Self.drag(tool, setup, from: Self.center(square, setup), to: Self.center(pages[0]), .option)
        #expect(Self.target(square, setup) == pages[0].id)
        // A badge dragged to another page retargets it.
        let own = try #require(LinkBadges.badges(setup.document).first)
        await Self.drag(tool, setup, from: setup.window.viewport.toPasteboard(LinkBadges.rect(own, viewport: setup.window.viewport).center), to: Self.center(pages[1]))
        #expect(Self.target(square, setup) == pages[1].id)
        // Dropped on the pasteboard: nothing.
        let count = setup.document.changeCount
        await Self.drag(tool, setup, from: Self.center(square, setup), to: Point(x: pages[0].rect.minX - 400, y: pages[0].rect.minY - 400))
        #expect(setup.document.changeCount == count)
    }

    @Test func lockedObjectsShowTheNoCursorAndDoNothing() async throws {
        let (setup, square, pages, tool) = try await Self.world()
        defer { setup.close() }
        let context = setup.window.toolManager.context
        tool.pointerMoved(setup.event(Self.center(square, setup)))
        #expect(tool.hover == .linkable && tool.cursor === LinkTool.chainCursor)
        tool.pointerMoved(setup.event(Point(x: pages[0].rect.minX + 5, y: pages[0].rect.minY + 5)))
        #expect(tool.hover == .none && tool.cursor == .arrow)
        _ = await setup.document.perform(SetLocked([square], locked: true)).value
        await setup.document.settle()
        #expect(LinkTool.target(at: setup.event(Self.center(square, setup)), context: context) == .refused)
        tool.pointerMoved(setup.event(Self.center(square, setup)))
        #expect(tool.hover == .refused && tool.cursor == .operationNotAllowed)
        let count = setup.document.changeCount
        await Self.drag(tool, setup, from: Self.center(square, setup), to: Self.center(pages[1]))
        #expect(setup.document.changeCount == count && Self.target(square, setup) == nil)
    }

    @Test func textBeingEditedIsATextRangeAndRefused() async throws {
        let world = TypeWorld()
        defer { world.close() }
        await world.document.addPage().value
        let pages = world.document.pageList.pages
        let node = try await world.block("Linked words", at: Point(x: pages[0].origin.x + 50, y: pages[0].origin.y + 50))
        await world.edit(node, select: 0..<6)
        let context = world.window.toolManager.context
        let frame = try #require(TextBlockFrame(node, document: world.document))
        let center = frame.transform.apply(frame.local.center)
        let event = CanvasEvent(pasteboardPoint: center, viewPoint: world.window.viewport.toView(center))
        #expect(LinkTool.target(at: event, context: context) == .refused)
    }

    @Test func spacePansMidDragAndEscAbandons() async throws {
        let (setup, square, pages, tool) = try await Self.world()
        defer { setup.close() }
        tool.mouseDown(setup.event(Self.center(square, setup)))
        tool.flagsChanged(setup.event(.zero, .option))
        #expect(tool.drag?.option == true)
        tool.spaceChanged(down: true)
        let viewport = setup.window.viewport
        tool.mouseDragged(CanvasEvent(pasteboardPoint: .zero, viewPoint: Point(x: 300, y: 300)))
        tool.mouseDragged(CanvasEvent(pasteboardPoint: .zero, viewPoint: Point(x: 250, y: 280)))
        #expect(setup.window.viewport.scrollOrigin != viewport.scrollOrigin, "the drag pans")
        tool.spaceChanged(down: false)
        tool.mouseDragged(setup.event(Self.center(pages[1])))
        tool.cancel()
        #expect(tool.drag == nil && !tool.isDragging)
        tool.mouseUp(setup.event(Self.center(pages[1])))
        await setup.document.settle()
        #expect(Self.target(square, setup) == nil)
        // Released while panning: the drop is where the connector was.
        tool.mouseDown(setup.event(Self.center(square, setup)))
        tool.mouseDragged(setup.event(Self.center(pages[1])))
        tool.spaceChanged(down: true)
        tool.mouseUp(setup.event(.zero))
        await setup.document.settle()
        #expect(Self.target(square, setup) == pages[1].id)
        #expect(!tool.keyDown(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a",
                                              charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!))
        tool.flagsChanged(setup.event(.zero))
        tool.mouseDown(setup.event(Point(x: pages[0].rect.minX + 5, y: pages[0].rect.minY + 5)))
        #expect(tool.drag == nil)
        tool.mouseDragged(setup.event(.zero))
        tool.mouseUp(setup.event(.zero))
        tool.deactivate()
        tool.pointerMoved(setup.event(.zero))
        tool.mouseDown(setup.event(.zero))
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: setup.window.viewport)
        #expect(tool.targetPage() == nil)
    }

    @Test func theToolIsInTheCatalogWithItsShortcut() {
        let descriptor = ToolCatalog.all.first { $0.id == LinkTool.id }
        #expect(descriptor?.title == "Link" && descriptor?.shortcuts == [KeyEquivalent("l", .shift)] && descriptor?.make() is LinkTool)
        #expect(ToolCatalog.all.first { $0.id == CropTool.id }?.make() is CropTool)
    }
}
