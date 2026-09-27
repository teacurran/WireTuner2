import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// Linking text blocks on the canvas (TYPE-007): the link-box drag, unlinking, the link lines and
/// the chain-aware frames.
@Suite(.serialized) @MainActor struct TextLinksTests {
    typealias Fixture = TypeExtrasTests

    static let story = String(repeating: "Linked text flows from block to block. ", count: 10)

    static func area(_ world: TypeWorld, _ text: String = "", _ rect: Rect) async throws -> OpID {
        try #require(await world.document.addText(text, frame: .area(rect)))
    }

    /// A drag from `frame`'s link box to `point`.
    static func drag(_ handles: TextBlockHandles, _ frame: TextBlockFrame, to point: Point, world: TypeWorld) async {
        let context = Fixture.context(world)
        let viewport = world.window.viewport
        let box = frame.transform.apply(frame.linkBoxCenter(zoom: viewport.zoom))
        #expect(handles.press(Fixture.event(world, box), context: context))
        handles.drag(Fixture.event(world, point), context: context)
        handles.draw(in: DrawingToolTests.bitmap(), viewport: viewport, context: context)
        handles.release(Fixture.event(world, point), context: context)
        await world.settle()
    }

    @Test func dragsFromTheLinkBoxLinkRelinkAndUnlink() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let head = try await Self.area(world, Self.story, Rect(x: 50, y: 50, width: 200, height: 40))
        let empty = try await Self.area(world, "", Rect(x: 50, y: 200, width: 200, height: 300))
        let full = try await Self.area(world, "taken", Rect(x: 400, y: 50, width: 100, height: 40))
        world.window.selection.model.set(Selection([SelectionID(head)]))
        let handles = TextBlockHandles()
        let context = Fixture.context(world)
        let frame = try #require(handles.frames(context).first)
        #expect(frame.overflows && !frame.isLinked)
        // Onto the empty block: linked, the overflow flows on.
        await Self.drag(handles, frame, to: Point(x: 150, y: 300), world: world)
        #expect(TextChains.chain(of: head, in: world.state) == [head, empty])
        #expect(world.document.undoTitle == "Undo Link text blocks")
        let linked = try #require(handles.frames(context).first)
        #expect(linked.isLinked && !linked.overflows)
        let member = try #require(TextBlockFrame(empty, document: world.document))
        #expect(member.local.width == 200 && !member.isLinked)
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
        // Onto a block holding text: refused.
        await Self.drag(handles, linked, to: Point(x: 450, y: 60), world: world)
        #expect(TextChains.chain(of: head, in: world.state) == [head, empty])
        // Barely moving does nothing; Esc drops a drag.
        await Self.drag(handles, linked, to: linked.transform.apply(linked.linkBoxCenter(zoom: world.window.viewport.zoom)), world: world)
        #expect(world.document.undoTitle == "Undo Link text blocks")
        #expect(handles.press(Fixture.event(world, linked.transform.apply(linked.linkBoxCenter(zoom: world.window.viewport.zoom))), context: context))
        handles.cancel(context: context)
        #expect(handles.linking.dragging == nil)
        // Onto an empty spot: unlinked.
        await Self.drag(handles, linked, to: Point(x: 900, y: 900), world: world)
        #expect(TextChains.chain(of: head, in: world.state) == [head] && world.document.undoTitle == "Undo Unlink text blocks")
        // Onto an empty spot with no link: nothing.
        let unlinked = try #require(handles.frames(context).first)
        await Self.drag(handles, unlinked, to: Point(x: 900, y: 900), world: world)
        #expect(world.document.undoTitle == "Undo Unlink text blocks")
        _ = full
    }

    @Test func dragsOntoAPathMakeItATextContainerAndTheLineReachesIt() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let head = try await Self.area(world, Self.story, Rect(x: 50, y: 50, width: 200, height: 40))
        let path = try #require(await world.document.addPath([Point(x: 50, y: 200), Point(x: 300, y: 200), Point(x: 300, y: 400), Point(x: 50, y: 400)],
                                                           closed: true, filled: true))
        world.window.selection.model.set(Selection([SelectionID(head)]))
        let handles = TextBlockHandles()
        let frame = try #require(handles.frames(Fixture.context(world)).first)
        await Self.drag(handles, frame, to: Point(x: 50, y: 300), world: world)
        let container = try #require(TextChains.next(head, in: world.state))
        #expect(Objects.parent(of: path.opID, in: world.state) == container)
        #expect(TextLinkDrag.entry(container, document: world.document, viewport: world.window.viewport) != nil)
        #expect(TextLinkDrag.anchor(container, document: world.document, viewport: world.window.viewport) == nil, "text in a path has no link box")
        #expect(TextLinkDrag.entry(OpID(counter: 999, replica: 9), document: world.document, viewport: world.window.viewport) == nil)
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: Fixture.context(world))
    }

    @Test func aBlockWhoseLinkWasCutShowsTheOverflowDotAndDeletingAMiddleBlockSplices() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let x = try await Self.area(world, "x", Rect(x: 50, y: 50, width: 200, height: 40))
        let y = try await Self.area(world, "", Rect(x: 50, y: 150, width: 200, height: 40))
        func set(_ node: OpID, _ field: UInt32, _ target: OpID) -> Wiretuner_Doc_V1_Op {
            Ops.set(node, [RegisterPath([130, field])], values: .with {
                if field == 4 { $0.text.nextLink.id = target.proto } else { $0.text.prevLink.id = target.proto }
            })
        }
        _ = await world.document.perform(OpsCommand("Loop", ops: [set(x, 4, y), set(y, 5, x), set(y, 4, x), set(x, 5, y)])).value
        await world.settle()
        let small = min(x, y)
        #expect(try #require(TextBlockFrame(small, document: world.document)).overflows, "the cut block shows the dot")
        _ = await world.document.perform(UnlinkTextBlocks(max(x, y))).value
        _ = await world.document.perform(UnlinkTextBlocks(small)).value
        let z = try await Self.area(world, "", Rect(x: 50, y: 250, width: 200, height: 40))
        _ = await world.document.perform(LinkTextBlocks(from: x, to: y)).value
        _ = await world.document.perform(LinkTextBlocks(from: y, to: z)).value
        #expect(try #require(TextBlockFrame(z, document: world.document)).local.height == 40)
        _ = await world.document.perform(ClearObjects([y])).value
        await world.settle()
        #expect(TextChains.chain(of: x, in: world.state) == [x, z])
    }

    /// TYPE-007: a click and typing in any member of a linked chain edit the story -- the head's
    /// text -- at the place that member draws, never the member's dormant text; the caret, the
    /// selection and the frame are drawn in the member that lays the characters out, and the Text
    /// Editor opens the story from any member.
    @Test func typingIntoAMemberEditsTheStory() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let head = try await Self.area(world, Self.story, Rect(x: 50, y: 50, width: 200, height: 40))
        let member = try await Self.area(world, "", Rect(x: 50, y: 200, width: 200, height: 300))
        _ = await world.document.perform(LinkTextBlocks(from: head, to: member)).value
        await world.settle()
        #expect(TextChains.chain(of: head, in: world.state) == [head, member])
        let session = TextEditingSession(document: world.document, sink: world.document, target: .node(member))
        #expect(session.node == head && session.flow?.chain == [head, member])
        let flow = try #require(session.flow)
        // A click in the member lands in the member's part of the story.
        let click = Point(x: 52, y: 205)
        let local = try #require(Objects.pasteboardTransform(of: member, in: world.state).inverted()).apply(click)
        let expected = try #require(flow.layout.offset(at: local, inContainer: 1))
        #expect(expected > 0 && expected < Array(Self.story.unicodeScalars).count)
        session.click(at: click, granularity: .character, extend: false)
        await session.settle()
        #expect(session.focusOffset == expected && session.activeContainer == 1)
        #expect(session.contains(Point(x: 100, y: 300)) && session.contains(Point(x: 100, y: 60)) && !session.contains(Point(x: 700, y: 700)))
        let corners = session.frameCorners
        #expect(abs(corners[0].x - 50) < 0.01 && abs(corners[0].y - 200) < 0.01, "the frame is the member's")
        let caret = try #require(session.caret)
        #expect(caret.top.y >= 199 && caret.bottom.y <= 500, "the caret is drawn in the member")
        session.insert("Z")
        await session.settle()
        await world.settle()
        let story = try #require(world.state.textNode(head))
        #expect(Array(story.string.unicodeScalars)[expected] == "Z")
        #expect(world.state.textNode(member)?.length == 0, "the member's own text stays dormant")
        // A selection across the two members is drawn in both.
        session.select(anchor: 0, focus: expected + 1)
        await session.settle()
        let quads = session.selectionQuads
        #expect(quads.contains { $0.allSatisfy { $0.y < 100 } } && quads.contains { $0.allSatisfy { $0.y > 190 } })
        #expect(session.caretBaseline != nil)
        // A remote caret in the story is drawn in the member that lays its character out.
        let overlay = PresenceOverlay(document: world.document, viewport: world.window.viewport)
        let char = try #require(story.anchor(at: expected).char as OpID?)
        let remote = RemoteCaret(node: SelectionID(head), position: char)
        let geometry = try #require(overlay.caretGeometry(remote))
        let top = world.window.viewport.viewToPasteboard.apply(geometry.top)
        #expect(top.y > 190, "drawn in the member, not the head")
        // The Text tool's hit test finds the member by its container of the story; the editor
        // opens the story.
        let editor = TextEditorModel(document: world.document, node: member, sink: world.document)
        #expect(editor.node == head && editor.text?.string == story.string)
        #expect(TextFrames.frame(ofBlock: member, document: world.document)?.height == 300)
        #expect(TextEditingSession.story(.pending(.point(.zero)), in: world.state) == .pending(.point(.zero)))
        // Emptying the story does not delete its head: the members still hold the flow.
        session.selectAll()
        session.delete(.deleteSelection)
        await session.settle()
        await world.settle()
        #expect(session.end() == head)
        await world.settle()
        #expect(world.state.isLive(head) && TextChains.chain(of: head, in: world.state) == [head, member])
    }
}
