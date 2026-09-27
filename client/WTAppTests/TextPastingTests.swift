import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
@testable import WireTuner

/// TYPE-009 in the app (importing-text.adoc, "Pasting", "Dragging text in"): rich text pasted into
/// the Text tool's insertion point and as a new block, a WireTuner copy keeping every attribute,
/// *Paste and Match Style*, and text dragged onto the canvas with its following caret and the
/// kbd:[Option] plain drop.  App-hosted rather than UI tests: they drive the session, the commands
/// and the canvas drop the events reach.
@Suite(.serialized) @MainActor struct TextPastingTests {
    static let bold = Wiretuner_Doc_V1_TextMarkValue.with { $0.fontStyle = "Bold" }

    static func size(_ size: Double) -> Wiretuner_Doc_V1_TextMarkValue { .with { $0.size = size } }

    /// RTF of "Big bold" (24 pt bold) then " small" (9 pt).
    static let rtf = RTFExporter.rtf([ExportStory(paragraphs: [ExportParagraph([
        ExportTextRun("Big bold", attributes: ExportTextAttributes(fontFamily: "Helvetica", size: 24, bold: true)),
        ExportTextRun(" small", attributes: ExportTextAttributes(fontFamily: "Helvetica", size: 9)),
    ])])])

    static func sizes(_ document: DocumentHandle, _ node: OpID) -> [Double?] {
        guard let text = document.state.textNode(node) else { return [] }
        return (0..<text.length).map { offset in
            text.values(at: offset).compactMap { if case .size(let size)? = $0.value { size } else { nil } }.first
        }
    }

    @Test func richTextPastesIntoTheInsertionPointWithItsMarks() async throws {
        let fixture = TextToolTests.Fixture()
        let node = try #require(await fixture.document.addText("[]", at: Point(x: 40, y: 60)))
        fixture.tool.edit(node, at: Point(x: 40, y: 62))
        let session = try #require(fixture.session)
        session.pasteboard = fixture.pasteboard
        session.select(anchor: 1, focus: 1)
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setData(Self.rtf, forType: .rtf)
        #expect(session.canPaste)
        session.paste()
        await fixture.settle()
        #expect(fixture.document.string(node) == "[Big bold small]")
        #expect(Self.sizes(fixture.document, node) == [nil] + Array(repeating: 24, count: 8) + Array(repeating: 9, count: 6) + [nil])
        let text = try #require(fixture.document.state.textNode(node))
        #expect(text.values(at: 1).contains(Self.bold) && !text.values(at: 10).contains(Self.bold))
        #expect(fixture.document.undoTitle == "Undo Paste")
        #expect(session.focusOffset == 15, "the insertion point follows the pasted text")
        // Paste and Match Style: the characters in the look around the insertion point.
        session.select(anchor: 0, focus: 0)
        session.pasteAndMatchStyle()
        await fixture.settle()
        #expect(fixture.document.string(node) == "Big bold small[Big bold small]")
        #expect(Self.sizes(fixture.document, node).prefix(14).allSatisfy { $0 == nil })
        // Over a selection: replaced.
        session.select(anchor: 0, focus: 14)
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("X", forType: .string)
        session.paste()
        await fixture.settle()
        #expect(fixture.document.string(node) == "X[Big bold small]")
        // A pending format applies to plain text.
        session.select(anchor: 1, focus: 1)
        _ = session.format(Self.size(40))
        session.paste()
        await fixture.settle()
        #expect(Self.sizes(fixture.document, node)[1] == 40)
        // Nothing to paste; a pending block types the characters.
        fixture.pasteboard.clearContents()
        session.pasteAndMatchStyle()
        session.paste(TextClip(plain: ""))
        let pending = TextEditingSession(document: fixture.document, sink: fixture.document, target: .pending(.point(Point(x: 200, y: 200))))
        pending.paste(TextClip(plain: "new"))
        await pending.settle()
        await fixture.document.settle()
        #expect(fixture.document.textNodes.contains { fixture.document.string($0) == "new" })
    }

    @Test func aWireTunerCopyKeepsEveryAttribute() async throws {
        let fixture = TextToolTests.Fixture()
        let source = try #require(await fixture.document.addText("Hello world", at: Point(x: 40, y: 60)))
        let target = try #require(await fixture.document.addText("<>", at: Point(x: 40, y: 160)))
        _ = await fixture.document.perform(ApplyMark(node: source, from: .start, to: TextFixtureAnchors.at(fixture.document, source, 5), value: Self.bold)).value
        _ = await fixture.document.perform(ApplyMark(node: source, from: .start, to: .end, value: Self.size(30))).value
        fixture.tool.edit(source, at: Point(x: 40, y: 62))
        var session = try #require(fixture.session)
        session.pasteboard = fixture.pasteboard
        session.select(anchor: 3, focus: 8)
        #expect(session.copy())
        #expect(fixture.pasteboard.string(forType: .string) == "lo wo")
        #expect(fixture.pasteboard.data(forType: TextPasting.clipType) != nil)
        fixture.tool.edit(target, at: Point(x: 40, y: 162))
        session = try #require(fixture.session)
        session.pasteboard = fixture.pasteboard
        session.select(anchor: 1, focus: 1)
        session.paste()
        await fixture.settle()
        #expect(fixture.document.string(target) == "<lo wo>")
        let text = try #require(fixture.document.state.textNode(target))
        #expect(text.values(at: 1).contains(Self.bold) && text.values(at: 2).contains(Self.bold) && !text.values(at: 3).contains(Self.bold))
        #expect(Self.sizes(fixture.document, target) == [nil, 30, 30, 30, 30, 30, nil])
        // Plain reading takes the characters only.
        #expect(TextPasting.clip(from: fixture.pasteboard, plain: true)?.plain == true)
        let rich = NSPasteboard(name: NSPasteboard.Name("TextPasting-\(UUID().uuidString)"))
        rich.clearContents()
        rich.setData(Self.rtf, forType: .rtf)
        #expect(TextPasting.clip(from: rich, plain: true) == TextClip(plain: "Big bold small"))
        rich.clearContents()
        rich.setData(Data("not rtf".utf8), forType: .rtf)
        #expect(TextPasting.canRead(rich) && TextPasting.clip(from: rich) == nil)
        rich.releaseGlobally()
    }

    @Test func pasteAndMatchStyleCommandsAndTheSharedKey() async throws {
        let fixture = TextToolTests.Fixture()
        let node = try #require(await fixture.document.addText("ab", at: Point(x: 40, y: 60)))
        _ = await fixture.document.perform(ApplyMark(node: node, from: .start, to: .end, value: Self.size(20))).value
        let registry = CommandRegistry()
        ObjectMenuCommands.install(into: registry) { fixture.editing }
        let match = try #require(registry.command(ObjectMenuCommands.ID.pasteAndMatchStyle))
        #expect(match.menuPath?.components == [StandardCommands.Menu.edit] && match.defaultKey == nil)
        #expect(match.validation().isEnabled == false)
        fixture.tool.edit(node, at: Point(x: 40, y: 62))
        let session = try #require(fixture.session)
        session.pasteboard = fixture.pasteboard
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setData(Self.rtf, forType: .rtf)
        session.select(anchor: 1, focus: 1)
        #expect(match.validation().isEnabled)
        registry.perform(ObjectMenuCommands.ID.pasteAndMatchStyle)
        await fixture.settle()
        #expect(fixture.document.string(node) == "aBig bold smallb" && Self.sizes(fixture.document, node).allSatisfy { $0 == 20 })
        // Cmd+Option+Shift+V (Paste Behind's key) is Paste and Match Style while editing text.
        let behind = try #require(registry.command(ContextMenuCatalog.ID.pasteBehind))
        #expect(behind.validation().isEnabled)
        registry.perform(ContextMenuCatalog.ID.pasteBehind)
        await fixture.settle()
        #expect(fixture.document.string(node)?.count == 30 && Self.sizes(fixture.document, node).allSatisfy { $0 == 20 })
    }

    @Test func pasteWithNothingEditedMakesANewBlock() async throws {
        let world = EditWorld()
        defer { world.close() }
        world.pasteboard.clearContents()
        world.pasteboard.setData(Self.rtf, forType: .rtf)
        world.pasteboard.setString("Big bold small", forType: .string)
        world.window.objectEditing.visibleCenter = { Point(x: 300, y: 200) }
        #expect(world.features.takesPaste(from: world.pasteboard))
        #expect(await world.features.pasteRichest(on: world.window))
        await world.document.settle()
        let block = try #require(world.window.selection.selection.ids.first?.opID)
        let text = try #require(world.state.textNode(block))
        #expect(text.string == "Big bold small" && text.props.block.autoWidth && text.props.common.transform.tx == 300)
        #expect(text.values(at: 0).contains(Self.bold) && !text.values(at: 9).contains(Self.bold))
        #expect(world.document.undoTitle == "Undo Paste")
        // Nothing textual: nothing is made.
        let empty = NSPasteboard(name: NSPasteboard.Name("TextPasting-empty-\(UUID().uuidString)"))
        empty.clearContents()
        #expect(await world.features.pasteTextBlock(on: world.window, from: empty) == false)
        empty.releaseGlobally()
    }

    @Test func textDraggedOntoTheCanvasFollowsWithACaretAndDrops() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let window = setup.window
        let canvas = window.canvas
        let drop = CanvasTextDrop(window: window)
        canvas.textDrop = drop
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TextDrop-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let page = setup.page.rect
        let origin = Point(x: page.minX + 100, y: page.minY + 100)
        let node = try #require(await setup.document.addText("abcdef", at: origin))
        _ = await setup.document.perform(ApplyMark(node: node, from: .start, to: .end, value: Self.size(12))).value
        await setup.document.settle()
        let layout = try #require(setup.document.textLayout(for: node))
        let middle = try #require(layout.caret(atOffset: 3, upstream: false))
        let over = Objects.pasteboardTransform(of: node, in: setup.document.state).apply(Point(x: middle.baseline.x + 0.5, y: (middle.top.y + middle.bottom.y) / 2))
        pasteboard.clearContents()
        pasteboard.setData(Self.rtf, forType: .rtf)
        // Over the block: the caret follows at the boundary the drop would insert at.
        #expect(canvas.draggingEntered(PasteboardDragging(pasteboard, at: setup.windowPoint(over))) == .copy)
        #expect(drop.caret?.node == node && drop.caret?.offset == 3)
        #expect(drop.caretLine(viewport: window.viewport) != nil)
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        drop.draw(in: context, viewport: window.viewport)
        canvas.draggingExited(nil)
        #expect(drop.caret == nil && drop.caretLine(viewport: window.viewport) == nil)
        drop.draw(in: context, viewport: window.viewport)
        // Dropped there: inserted with its marks.
        #expect(canvas.performDragOperation(PasteboardDragging(pasteboard, at: setup.windowPoint(over))))
        await setup.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        await setup.document.settle()
        #expect(setup.document.string(node) == "abcBig bold smalldef")
        #expect(Self.sizes(setup.document, node)[3] == 24)
        // Option drops plain text: the look around the drop point.
        canvas.dragModifiers = { .option }
        #expect(canvas.performDragOperation(PasteboardDragging(pasteboard, at: setup.windowPoint(over))))
        await setup.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        await setup.document.settle()
        let text = try #require(setup.document.state.textNode(node))
        #expect(text.string.count == 34 && (0..<text.length).filter { text.values(at: $0).contains(Self.bold) }.count == 8)
        canvas.dragModifiers = { [] }
        // On empty space: a new block at the drop point, selected.
        let empty = Point(x: page.minX + 300, y: page.minY + 400)
        #expect(canvas.draggingUpdated(PasteboardDragging(pasteboard, at: setup.windowPoint(empty))) == .copy)
        #expect(drop.caret == nil)
        let task = drop.drop(pasteboard, at: window.viewport.toView(empty), viewport: window.viewport, plain: false)
        let change = await task?.value
        let block = try #require(change?.createdObjects.first { setup.document.state.nodeKind($0) == .text })
        #expect(window.selection.selection.ids.map(\.opID) == [block])
        #expect(abs(setup.document.state.props(block).text.common.transform.tx - empty.x) < 0.5)
        // Anything but text is not a text drop.
        pasteboard.clearContents()
        #expect(!drop.update(pasteboard, at: .zero, viewport: window.viewport) && drop.drop(pasteboard, at: .zero, viewport: window.viewport, plain: false) == nil)
        drop.window = nil
        pasteboard.setString("x", forType: .string)
        #expect(!drop.update(pasteboard, at: .zero, viewport: window.viewport) && drop.caretLine(viewport: window.viewport) == nil)
        #expect(TextPasting.target(at: Point(x: -9999, y: -9999), in: setup.document) == nil)
    }
}

/// Anchors for the app's text tests.
@MainActor
enum TextFixtureAnchors {
    static func at(_ document: DocumentHandle, _ node: OpID, _ offset: Int) -> Anchor {
        document.state.textNode(node)?.anchor(at: offset) ?? .end
    }
}
