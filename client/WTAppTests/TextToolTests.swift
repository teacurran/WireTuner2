import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// Text blocks for app tests.
extension DocumentHandle {
    /// Adds an auto-expanding block holding `text` with its top-left at `point`; waits until it
    /// is drawn.
    @discardableResult
    func addText(_ text: String, at point: Point = Point(x: 50, y: 50), frame: CreateTextBlock.Frame? = nil) async -> OpID? {
        let node = await perform(CreateTextBlock(frame ?? .point(point), text: text)).value?.createdObjects.first { state.nodeKind($0) == .text }
        await settle()
        return node
    }

    /// The live string of text node `node`.
    func string(_ node: OpID) -> String? { state.textNode(node)?.string }

    /// The text nodes that exist and are live.
    var textNodes: [OpID] { state.store.nodes.filter { state.nodeKind($0) == .text && state.isLive($0) } }
}

/// TYPE-003 and TYPE-010: the Text tool -- click and drag creation, typing through the text input
/// client, marked text, the selection gestures and keys, Esc and clicking away -- driven with the
/// events the canvas delivers (the UI tests of *Done when*, hosted in the app).
@Suite(.serialized) @MainActor struct TextToolTests {
    static let viewport = Viewport(size: Size(width: 400, height: 300))

    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Text")
        let host = RecordingHost(viewport: TextToolTests.viewport)
        let controller: SelectionController
        let editing: ObjectEditing
        let tool = TextTool()
        var settings = TextToolSettings()
        private(set) var selectedTools: [ToolID] = []
        private(set) var carets: [PresenceCaret?] = []
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.text.\(UUID().uuidString)"))

        init(revert: Bool = true, autoExpand: Bool = true) {
            document.pages = [Rect(x: 0, y: 0, width: 400, height: 300)]
            controller = SelectionController(document: document)
            editing = ObjectEditing(document: document, selection: controller)
            settings = TextToolSettings(autoExpand: autoExpand, revertsToPointer: revert)
            var context = ToolContext(document: document, host: host, selection: controller)
            context.commandSink = editing
            context.objectEditing = editing
            context.text = { [unowned self] in self.settings }
            context.selectTool = { [unowned self] id in self.selectedTools.append(id) }
            context.textCaretChanged = { [unowned self] caret in self.carets.append(caret) }
            tool.activate(in: context)
        }

        var session: TextEditingSession? { tool.session }

        func click(_ x: Double, _ y: Double, _ modifiers: KeyModifiers = [], count: Int = 1) {
            let event = CanvasEvent(pasteboardPoint: Point(x: x, y: y), viewPoint: Point(x: x, y: y), modifiers: modifiers, clickCount: count)
            tool.mouseDown(event)
            tool.mouseUp(event)
        }

        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) {
            tool.mouseDown(CanvasEvent(pasteboardPoint: from, viewPoint: from, modifiers: modifiers))
            tool.mouseDragged(CanvasEvent(pasteboardPoint: to, viewPoint: to, modifiers: modifiers))
            tool.mouseUp(CanvasEvent(pasteboardPoint: to, viewPoint: to, modifiers: modifiers))
        }

        /// Types `text` one keystroke at a time through the input client, then waits for it.
        func type(_ text: String) async {
            for character in text { tool.insertText(String(character), replacementRange: nil) }
            await settle()
        }

        func settle() async {
            await session?.settle()
            await document.settle()
            await session?.settle()
            await document.settle()
        }

        /// The one text block of the document.
        var node: OpID? { document.textNodes.first }
    }

    // MARK: Creation

    @Test func clickMakesAnAutoExpandingBlockOnlyWhenTheFirstCharacterIsTyped() async throws {
        let fixture = Fixture()
        fixture.click(40, 60)
        let session = try #require(fixture.session)
        #expect(session.target == .pending(.point(Point(x: 40, y: 60))))
        #expect(fixture.document.textNodes.isEmpty && fixture.tool.isEditingText)
        #expect(session.caret != nil && session.frameCorners.count == 4)
        await fixture.type("hello world")
        let node = try #require(fixture.node)
        #expect(fixture.document.string(node) == "hello world")
        let props = fixture.document.state.props(node).text
        #expect(props.block.autoWidth && props.block.autoHeight)
        #expect(Objects.transform(of: node, in: fixture.document.state) == .translation(x: 40, y: 60))
        #expect(fixture.controller.selection.ids == [SelectionID(node)])
        #expect(session.focusOffset == 11 && session.selectedRange.isEmpty)
        // Typing grouped by words: "hello " (with the block) and "world".
        #expect(fixture.document.undoTitle == "Undo Type")
        _ = await fixture.document.undo().value
        await fixture.settle()
        #expect(fixture.document.string(node) == "hello ")
        _ = await fixture.document.undo().value
        await fixture.settle()
        #expect(fixture.document.textNodes.isEmpty)
        // Undoing the creation ends editing.
        #expect(fixture.session == nil)
    }

    @Test func dragMakesAFixedSizeBlockSquaredWithShiftAndCentredWithOption() async throws {
        let fixture = Fixture()
        fixture.drag(Point(x: 20, y: 20), Point(x: 120, y: 80))
        #expect(fixture.session?.target == .pending(.area(Rect(x: 20, y: 20, width: 100, height: 60))))
        await fixture.type("Fixed")
        let node = try #require(fixture.node)
        let block = fixture.document.state.props(node).text.block
        #expect(block.width == 100 && block.height == 60 && !block.autoWidth && !block.autoHeight)
        fixture.tool.cancel()
        #expect(fixture.selectedTools == [.pointer])
        #expect(fixture.tool.dragRect(start: TestEvents.point(10, 10), end: TestEvents.point(60, 30, .shift)) == Rect(x: 10, y: 10, width: 50, height: 50))
        #expect(fixture.tool.dragRect(start: TestEvents.point(50, 50), end: TestEvents.point(60, 70, .option)) == Rect(x: 40, y: 30, width: 20, height: 40))
        #expect(fixture.tool.dragRect(start: TestEvents.point(50, 50), end: TestEvents.point(40, 20, .shift)) == Rect(x: 20, y: 20, width: 30, height: 30))
        #expect(fixture.tool.dragRect(start: TestEvents.point(50, 50), end: TestEvents.point(51, 51)) == nil)
        #expect(fixture.tool.dragRect(start: TestEvents.point(50, 50), end: TestEvents.point(50, 90)) == nil)
    }

    @Test func aClickWithAutoExpandOffMakesADefaultSizedBlock() async throws {
        let fixture = Fixture(autoExpand: false)
        fixture.click(10, 10)
        let size = TextToolSettings.defaultSize
        #expect(fixture.session?.target == .pending(.area(Rect(x: 10, y: 10, width: size.width, height: size.height))))
    }

    @Test func anAbandonedEmptyBlockNeverReachesTheDocument() async {
        let fixture = Fixture()
        fixture.click(40, 60)
        #expect(fixture.tool.hasSomethingToCancel)
        fixture.tool.cancel()
        await fixture.settle()
        #expect(fixture.document.textNodes.isEmpty && fixture.document.changeCount == 1, "the fixture's page alone")
        #expect(fixture.session == nil && fixture.selectedTools == [.pointer])
        // Emptying a block and leaving it deletes it.
        fixture.click(40, 60)
        await fixture.type("ab")
        let node = fixture.node
        fixture.tool.doCommand("deleteBackward:")
        fixture.tool.doCommand("deleteBackward:")
        await fixture.settle()
        #expect(node.flatMap { fixture.document.string($0) } == "")
        fixture.tool.endEditing(revert: false)
        await fixture.settle()
        #expect(fixture.document.textNodes.isEmpty)
    }

    @Test func keystrokesTypedWhileTheBlockIsBeingCreatedFollowIt() async throws {
        let fixture = Fixture()
        fixture.click(40, 60)
        let session = try #require(fixture.session)
        session.insert("a")
        session.insert("b")
        session.insert("c")
        session.delete(.backspace)
        session.delete(.forwardDelete)
        #expect(session.target == .creating(.point(Point(x: 40, y: 60))) && session.inflight == 1)
        await fixture.settle()
        #expect(fixture.node.flatMap { fixture.document.string($0) } == "ab")
    }

    @Test func marksAndParagraphChosenBeforeTheFirstCharacterAreItsFormat() async throws {
        let fixture = Fixture()
        fixture.click(40, 60)
        let session = try #require(fixture.session)
        session.format(.with { $0.size = 30 })
        session.format(.with { $0.size = 24 })
        session.align(.center)
        #expect(session.pendingFormat.count == 1 && session.paragraphProps == [.with { $0.alignment = .center }])
        #expect(session.formatRuns == [[.with { $0.size = 24 }]])
        await fixture.type("Big")
        let node = try #require(fixture.node)
        let text = try #require(fixture.document.state.textNode(node))
        #expect(text.values(at: 0).contains(.with { $0.size = 24 }))
        #expect(text.paragraphs.last?.props.alignment == .center)
    }

    // MARK: Input method

    @Test func markedTextIsNotSentUntilItIsCommitted() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("ab", at: Point(x: 40, y: 60)))
        fixture.tool.edit(node, at: Point(x: 200, y: 62))
        let session = try #require(fixture.session)
        #expect(session.focusOffset == 2)
        let changes = fixture.document.changeCount
        fixture.tool.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
        fixture.tool.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        await fixture.settle()
        #expect(fixture.document.changeCount == changes && fixture.document.string(node) == "ab")
        #expect(fixture.tool.hasMarkedText && fixture.tool.markedRange == NSRange(location: 2, length: 1))
        #expect(fixture.tool.selectedRange == NSRange(location: 3, length: 0))
        #expect(session.caretBaseline != nil)
        fixture.tool.drawOverlay(in: TextToolTests.context(), viewport: TextToolTests.viewport)
        fixture.tool.unmarkText()
        await fixture.settle()
        #expect(fixture.document.string(node) == "abに" && !fixture.tool.hasMarkedText)
        // A commit through insertText replaces the composition.
        fixture.tool.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        fixture.tool.insertText("火", replacementRange: nil)
        await fixture.settle()
        #expect(fixture.document.string(node) == "abに火")
        // The press-and-hold accent menu replaces the letter before the caret.
        fixture.tool.insertText("e", replacementRange: nil)
        await fixture.settle()
        fixture.tool.insertText("é", replacementRange: NSRange(location: 4, length: 1))
        await fixture.settle()
        #expect(fixture.document.string(node) == "abに火é")
        #expect(fixture.tool.attributedSubstring(NSRange(location: 0, length: 2))?.string.string == "ab")
        #expect(fixture.tool.attributedSubstring(NSRange(location: 99, length: 2)) == nil)
        #expect(fixture.tool.caretRect != nil)
        fixture.tool.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        #expect(!fixture.tool.hasMarkedText)
        // A composition in progress takes Esc through the tool manager.
        fixture.tool.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0))
        fixture.tool.endEditing(revert: false)
        await fixture.settle()
        #expect(fixture.document.string(node) == "abに火éx")
    }

    @Test func surrogatePairsMapBetweenUTF16AndScalars() {
        let scalars = Array("a😀b".unicodeScalars)
        #expect(TextNavigation.utf16Offset(2, in: scalars) == 3)
        #expect(TextNavigation.scalarOffset(3, in: scalars) == 2)
        #expect(TextNavigation.scalarOffset(2, in: scalars) == 2)
        #expect(TextNavigation.scalarOffset(9, in: scalars) == 3)
        #expect(TextNavigation.scalarRange(NSRange(location: 1, length: 2), in: scalars) == 1..<2)
        #expect(TextNavigation.scalarRange(NSRange(location: -1, length: -4), in: scalars) == 0..<0)
    }

    // MARK: Selection and navigation

    @Test func keyboardMovementAndExtension() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("hello world\nsecond line", at: Point(x: 40, y: 60)))
        fixture.tool.edit(node, at: Point(x: 40, y: 62))
        let session = try #require(fixture.session)
        #expect(session.focusOffset == 0)
        func check(_ selector: String, _ offset: Int, _ range: Range<Int>? = nil) {
            #expect(fixture.tool.doCommand(selector), "\(selector)")
            #expect(session.focusOffset == offset, "\(selector) → \(session.focusOffset)")
            if let range { #expect(session.selectedRange == range, "\(selector) range \(session.selectedRange)") }
        }
        check("moveRight:", 1)
        check("moveWordRight:", 5)
        check("moveWordRight:", 11)
        check("moveToEndOfLine:", 11)
        check("moveToBeginningOfLine:", 0)
        check("moveDown:", 12)
        check("moveToEndOfLine:", 23)
        check("moveUp:", 11)
        check("moveUp:", 0)
        check("moveToEndOfDocument:", 23)
        check("moveDown:", 23)
        check("moveToBeginningOfParagraph:", 12)
        check("moveParagraphBackward:", 0)
        check("moveToEndOfParagraph:", 11)
        check("moveToEndOfParagraph:", 23)
        check("moveWordLeftAndModifySelection:", 19, 19..<23)
        check("moveLeft:", 19, 19..<19)
        check("moveRightAndModifySelection:", 20, 19..<20)
        check("moveRight:", 20, 20..<20)
        check("moveToBeginningOfDocumentAndModifySelection:", 0, 0..<20)
        check("moveWordLeft:", 0)
        check("moveLeft:", 0)
        check("selectAll:", 23, 0..<23)
        #expect(session.selectedText == "hello world\nsecond line")
        #expect(session.selectionQuads.count == 2)
        #expect(session.caret == nil)
        #expect(!fixture.tool.doCommand("noSuchSelector:"))
        #expect(fixture.carets.last??.node == node)
    }

    @Test func clickDoubleClickTripleClickShiftClickAndDragSelect() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("one two three\nnext", at: Point(x: 40, y: 60)))
        let layout = try #require(fixture.document.textLayout(for: node))
        func point(_ offset: Int, line: Int = 0) -> Point {
            let caret = layout.caret(atOffset: offset)!
            return Point(x: 40 + caret.baseline.x, y: 60 + caret.baseline.y - 3)
        }
        let session: TextEditingSession
        // A click in an existing block edits it at the click.
        let at5 = point(5)
        fixture.click(at5.x + 0.5, at5.y)
        session = try #require(fixture.session)
        #expect(session.node == node && session.focusOffset == 5)
        #expect(fixture.controller.selection.ids == [SelectionID(node)])
        fixture.click(point(9).x, point(9).y, .shift)
        #expect(session.selectedRange == 5..<9)
        fixture.click(at5.x + 0.5, at5.y, count: 2)
        #expect(session.selectedText == "two")
        // Dragging after a double click extends by words.
        fixture.tool.mouseDown(CanvasEvent(pasteboardPoint: at5, viewPoint: at5, clickCount: 2))
        fixture.tool.mouseDragged(TestEvents.point(point(10).x, point(10).y))
        fixture.tool.mouseUp(TestEvents.point(point(10).x, point(10).y))
        #expect(session.selectedText == "two three")
        fixture.tool.mouseDown(CanvasEvent(pasteboardPoint: point(10), viewPoint: point(10), clickCount: 2))
        fixture.tool.mouseDragged(TestEvents.point(point(1).x, point(1).y))
        fixture.tool.mouseUp(TestEvents.point(point(1).x, point(1).y))
        #expect(session.selectedText == "one two three")
        fixture.click(at5.x, at5.y, count: 3)
        #expect(session.selectedText == "one two three\n")
        // A plain drag selects characters.
        fixture.tool.mouseDown(TestEvents.point(point(1).x, point(1).y))
        fixture.tool.mouseDragged(TestEvents.point(point(3).x, point(3).y))
        fixture.tool.mouseUp(TestEvents.point(point(3).x, point(3).y))
        #expect(session.selectedRange == 1..<3)
        fixture.tool.drawOverlay(in: TextToolTests.context(), viewport: TextToolTests.viewport)
        #expect(fixture.tool.caretRect != nil)
        // Dragging without a click in the block does nothing to the selection.
        session.drag(to: point(8))
        #expect(session.selectedRange == 1..<8)
    }

    @Test func wordAndParagraphBoundaries() {
        let text = Array("Hi, you're\nthere  now".unicodeScalars)
        #expect(TextNavigation.wordRange(at: 1, in: text) == 0..<2)
        #expect(TextNavigation.wordRange(at: 2, in: text) == 0..<2)
        #expect(TextNavigation.wordRange(at: 3, in: text) == 2..<4)
        #expect(TextNavigation.wordRange(at: 5, in: text) == 4..<10)
        #expect(TextNavigation.wordRange(at: 10, in: text) == 4..<10)
        #expect(TextNavigation.wordRange(at: 11, in: text) == 11..<16)
        #expect(TextNavigation.wordRange(at: 99, in: text) == 18..<21)
        #expect(TextNavigation.wordRange(at: 16, in: text) == 11..<16)
        #expect(TextNavigation.wordRange(at: 17, in: text) == 16..<18)
        #expect(TextNavigation.wordRange(at: 0, in: []) == 0..<0)
        #expect(TextNavigation.wordRange(at: 1, in: Array("a\nb".unicodeScalars)) == 0..<1)
        #expect(TextNavigation.wordRange(at: 2, in: Array("a \n".unicodeScalars)) == 2..<3)
        #expect(TextNavigation.wordStart(before: 10, in: text) == 4)
        #expect(TextNavigation.wordEnd(after: 2, in: text) == 10)
        #expect(TextNavigation.paragraphRange(at: 3, in: text) == 0..<11)
        #expect(TextNavigation.paragraphRange(at: 15, in: text) == 11..<21)
        #expect(TextNavigation.paragraphStart(before: 11, in: text) == 0)
        #expect(TextNavigation.paragraphEnd(after: 10, in: text) == 21)
        #expect(TextGranularity(clickCount: 0) == .character && TextGranularity(clickCount: 2) == .word && TextGranularity(clickCount: 5) == .paragraph)
        // Lines: a soft wrap keeps its boundary on the earlier line upstream.
        let lines = [0..<4, 4..<8]
        let wrapped = Array("abc defg".unicodeScalars)
        #expect(TextNavigation.lineIndex(of: 4, in: lines, upstream: true) == 0)
        #expect(TextNavigation.lineIndex(of: 4, in: lines, upstream: false) == 1)
        #expect(TextNavigation.lineIndex(of: 4, in: [], upstream: false) == nil)
        #expect(TextNavigation.lineStart(of: 6, in: [], upstream: false) == 0)
        #expect(TextNavigation.lineEnd(of: 1, in: lines, scalars: wrapped, upstream: false) == (3, false))
        #expect(TextNavigation.lineEnd(of: 1, in: [], scalars: wrapped, upstream: false) == (8, false))
        let unbroken = Array("abcdefgh".unicodeScalars)
        #expect(TextNavigation.lineEnd(of: 1, in: lines, scalars: unbroken, upstream: false) == (4, true))
    }

    @Test func deletingTypingOverASelectionAndLineDeletes() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("hello big world", at: Point(x: 40, y: 60)))
        fixture.tool.edit(node, at: Point(x: 40, y: 62))
        let session = try #require(fixture.session)
        fixture.tool.doCommand("moveToEndOfLine:")
        fixture.tool.doCommand("deleteWordBackward:")
        await fixture.settle()
        #expect(fixture.document.string(node) == "hello big ")
        fixture.tool.doCommand("moveToBeginningOfLine:")
        fixture.tool.doCommand("deleteForward:")
        await fixture.settle()
        #expect(fixture.document.string(node) == "ello big ")
        fixture.tool.doCommand("deleteWordForward:")
        await fixture.settle()
        #expect(fixture.document.string(node) == " big ")
        fixture.tool.doCommand("deleteBackward:")
        await fixture.settle()
        #expect(fixture.document.string(node) == " big ")
        session.select(anchor: 1, focus: 4)
        fixture.tool.insertText("small", replacementRange: nil)
        await fixture.settle()
        #expect(fixture.document.string(node) == " small ")
        #expect(session.focusOffset == 6 && session.selectedRange.isEmpty)
        #expect(fixture.document.undoTitle == "Undo Type")
        session.select(anchor: 1, focus: 6)
        fixture.tool.doCommand("deleteBackward:")
        await fixture.settle()
        #expect(fixture.document.string(node) == "  ")
        fixture.tool.doCommand("insertNewline:")
        await fixture.type("abcdef")
        fixture.tool.doCommand("insertLineBreak:")
        await fixture.type("end")
        #expect(fixture.document.string(node) == " \nabcdef\u{2028}end ")
        // The end of line (U+2028) starts a line: Cmd-Delete removes back to it.
        fixture.tool.doCommand("deleteToBeginningOfLine:")
        await fixture.settle()
        #expect(fixture.document.string(node) == " \nabcdef\u{2028} ")
        fixture.tool.doCommand("deleteToEndOfLine:")
        await fixture.settle()
        #expect(fixture.document.string(node) == " \nabcdef\u{2028}")
        fixture.tool.doCommand("deleteToEndOfLine:")
        session.select(anchor: 0, focus: 1)
        fixture.tool.doCommand("deleteToBeginningOfLine:")
        fixture.tool.doCommand("insertTab:")
        await fixture.settle()
        #expect(fixture.document.string(node) == "\t\nabcdef\u{2028}")
        session.delete(.deleteSelection)
        #expect(fixture.tool.doCommand("cancelOperation:"))
        #expect(fixture.session == nil && fixture.selectedTools == [.pointer])
    }

    @Test func copyCutAndPastePlainText() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("copy me", at: Point(x: 40, y: 60)))
        fixture.tool.edit(node, at: Point(x: 40, y: 62))
        let session = try #require(fixture.session)
        session.pasteboard = fixture.pasteboard
        #expect(!session.copy())
        session.select(anchor: 0, focus: 4)
        #expect(session.copy())
        #expect(fixture.pasteboard.string(forType: .string) == "copy")
        session.cut()
        await fixture.settle()
        #expect(fixture.document.string(node) == " me")
        fixture.tool.doCommand("moveToEndOfDocument:")
        #expect(session.canPaste)
        session.paste()
        await fixture.settle()
        #expect(fixture.document.string(node) == " mecopy")
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("a\r\nb\rc", forType: .string)
        session.paste()
        await fixture.settle()
        #expect(fixture.document.string(node) == " mecopya\nb\nc")
        fixture.pasteboard.clearContents()
        #expect(!session.canPaste)
        session.paste()
    }

    // MARK: Finishing

    @Test func clickingAwayFinishesAndRevertsToThePointer() async throws {
        let fixture = Fixture()
        fixture.click(40, 60)
        await fixture.type("Label")
        let node = try #require(fixture.node)
        fixture.click(300, 250)
        #expect(fixture.session == nil && fixture.selectedTools == [.pointer])
        #expect(fixture.controller.selection.ids == [SelectionID(node)])
        #expect(fixture.carets.last.map { $0 == nil } == true)
    }

    @Test func withoutRevertingAClickAwayStartsTheNextBlockAndAClickInAnotherBlockEditsIt() async throws {
        let fixture = Fixture(revert: false)
        let other = try #require(await fixture.document.addText("Other", at: Point(x: 200, y: 200)))
        fixture.click(40, 60)
        await fixture.type("First")
        fixture.click(300, 100)
        #expect(fixture.selectedTools.isEmpty)
        #expect(fixture.session?.target == .pending(.point(Point(x: 300, y: 100))))
        let bounds = try #require(fixture.document.object(for: SelectionID(other))?.bounds)
        fixture.click(bounds.midX, bounds.midY)
        #expect(fixture.session?.node == other)
        // A click in yet another block while editing switches to it.
        let first = try #require(fixture.document.textNodes.first { $0 != other })
        let firstBounds = try #require(fixture.document.object(for: SelectionID(first))?.bounds)
        fixture.click(firstBounds.midX, firstBounds.midY, count: 2)
        #expect(fixture.session?.node == first && fixture.session?.selectedText == "First")
        // A click on nothing starts a new block.
        fixture.click(390, 290)
        #expect(fixture.session?.target == .pending(.point(Point(x: 390, y: 290))))
    }

    @Test func aRemoteDeleteOfTheBlockEndsEditing() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("Shared", at: Point(x: 40, y: 60)))
        fixture.tool.edit(node, at: Point(x: 40, y: 62))
        #expect(fixture.session != nil)
        _ = await fixture.document.perform(DeleteNodes([node])).value
        await fixture.settle()
        #expect(fixture.session == nil)
        fixture.tool.deactivate()
        #expect(fixture.tool.keyDown(TestEvents.key("a", keyCode: 0)) == false)
    }

    @Test func lockedTextIsNotEditedByAClick() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("Locked", at: Point(x: 40, y: 60)))
        _ = await fixture.document.perform(SetLocked([node], locked: true)).value
        await fixture.settle()
        let bounds = try #require(fixture.document.object(for: SelectionID(node))?.bounds)
        fixture.click(bounds.midX, bounds.midY)
        #expect(fixture.session?.node == nil)
    }

    @Test func anIdleToolAnswersNothing() async throws {
        let tool = TextTool()
        tool.edit(OpID(counter: 1, replica: 1), at: .zero)
        tool.mouseDown(TestEvents.point(1, 1))
        #expect(tool.session == nil && !tool.hasSomethingToCancel)
        #expect(tool.markedRange.location == NSNotFound && tool.selectedRange.location == NSNotFound && tool.caretRect == nil)
        #expect(!tool.doCommand("moveLeft:") && !tool.hasMarkedText && tool.attributedSubstring(NSRange(location: 0, length: 1)) == nil)
        tool.insertText("x", replacementRange: nil)
        tool.setMarkedText("x", selectedRange: NSRange(location: 0, length: 0))
        tool.unmarkText()
        tool.endEditing(revert: true)
        // While a new block is dragged out there is something to cancel.
        let fixture = Fixture()
        fixture.tool.mouseDown(TestEvents.point(10, 10))
        #expect(fixture.tool.hasSomethingToCancel && fixture.session == nil)
        fixture.tool.cancel()
        #expect(!fixture.tool.hasSomethingToCancel && fixture.selectedTools.isEmpty)
    }

    @Test func aClickInAFixedSizeBlocksEmptyPartEditsIt() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("x", frame: .area(Rect(x: 100, y: 100, width: 200, height: 100))))
        fixture.click(250, 180)
        #expect(fixture.session?.node == node && fixture.session?.focusOffset == 1)
    }

    @Test func overflowingEmptiedAndDegenerateBlocks() async throws {
        let fixture = Fixture()
        // Nothing of a block too short for a line is laid out: no caret, clicks keep the insertion point.
        let hidden = try #require(await fixture.document.addText("hidden", frame: .area(Rect(x: 10, y: 10, width: 100, height: 1))))
        let session = TextEditingSession(document: fixture.document, sink: fixture.document, target: .node(hidden))
        session.select(anchor: 2, focus: 2)
        #expect(session.caret == nil && session.offset(at: Point(x: 20, y: 20)) == 2)
        // An emptied block has a caret from its own container.
        let emptied = try #require(await fixture.document.addText("ab", at: Point(x: 10, y: 150)))
        let empty = TextEditingSession(document: fixture.document, sink: fixture.document, target: .node(emptied))
        empty.selectAll()
        empty.delete(.backspace)
        await empty.settle()
        await fixture.document.settle()
        #expect(empty.caret != nil && empty.localFrame.height > 5 && empty.offset(at: Point(x: 50, y: 160)) == 0)
        #expect(empty.caretBaseline != nil && empty.frameCorners.count == 4 && empty.selectionQuads.isEmpty)
        // A block placed by a singular transform still answers.
        let flat = try #require(await fixture.document.addText("flat", at: Point(x: 200, y: 200)))
        var values = Wiretuner_Doc_V1_NodeProps()
        values.text.common.transform = .with { $0.tx = 5 }
        _ = await fixture.document.perform(OpsCommand("Flatten", ops: [Ops.set(flat, [RegisterPath([130, 1, 4])], values: values)])).value
        await fixture.document.settle()
        let degenerate = TextEditingSession(document: fixture.document, sink: fixture.document, target: .node(flat))
        #expect(!degenerate.contains(Point(x: -100, y: -100)))
        fixture.click(-50, -50)
        #expect(fixture.session?.node == nil)
    }

    @Test func aNewBlockBeforeItsFirstCharacter() async throws {
        let fixture = Fixture()
        fixture.click(40, 60)
        let session = try #require(fixture.session)
        #expect(session.scalars.isEmpty && session.text == nil && session.selectedText.isEmpty && session.presenceCaret == nil)
        session.select(anchor: 1, focus: 2)
        session.selectAll()
        session.move(.right, extend: false)
        session.delete(.backspace)
        session.deleteToLineEdge(end: true)
        session.drag(to: Point(x: 80, y: 60))
        session.insert("")
        #expect(session.markedUTF16Range.location == NSNotFound && session.selectedUTF16Range == NSRange(location: 0, length: 0))
        session.setMarkedText("ä", selected: NSRange(location: 1, length: 0))
        #expect(session.caretBaseline != nil)
        fixture.tool.drawOverlay(in: TextToolTests.context(), viewport: TextToolTests.viewport)
        session.unmarkText()
        await fixture.settle()
        #expect(fixture.node.flatMap { fixture.document.string($0) } == "ä")
        // A fixed-size new block measures its caret in its own rectangle.
        fixture.tool.endEditing(revert: false)
        fixture.drag(Point(x: 100, y: 100), Point(x: 200, y: 150))
        #expect(fixture.session?.caret != nil && fixture.session?.localFrame.width == 100)
    }

    @Test func tripleClickDragExtendsByParagraphs() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("first\nsecond\nthird", at: Point(x: 40, y: 60)))
        let layout = try #require(fixture.document.textLayout(for: node))
        func point(_ offset: Int) -> Point {
            let caret = layout.caret(atOffset: offset)!
            return Point(x: 40 + caret.baseline.x, y: 60 + caret.baseline.y - 3)
        }
        fixture.tool.mouseDown(CanvasEvent(pasteboardPoint: point(2), viewPoint: point(2), clickCount: 3))
        fixture.tool.mouseDragged(TestEvents.point(point(8).x, point(8).y))
        fixture.tool.mouseUp(TestEvents.point(point(8).x, point(8).y))
        #expect(fixture.session?.selectedText == "first\nsecond\n")
    }

    @Test func thePendingFormatShowsOverTheCharacterBefore() async throws {
        let fixture = Fixture()
        let node = try #require(await fixture.document.addText("big", at: Point(x: 40, y: 60)))
        _ = await fixture.document.perform(ApplyMark(node: node, from: .start, to: .end, value: .with { $0.size = 30 })).value
        await fixture.settle()
        fixture.tool.edit(node, at: Point(x: 300, y: 70))
        let session = try #require(fixture.session)
        #expect(session.formatRuns == [[.with { $0.size = 30 }]])
        session.format(.with { $0.size = 40 })
        #expect(session.formatRuns == [[.with { $0.size = 40 }]])
        session.move(.left, extend: false)
        #expect(session.formatRuns == [[.with { $0.size = 30 }]])
    }

    // MARK: Keys

    @Test func keysWithoutAnInputContextFallBackToTheBindings() async throws {
        let fixture = Fixture()
        #expect(!fixture.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        let node = try #require(await fixture.document.addText("ab", at: Point(x: 40, y: 60)))
        fixture.tool.edit(node, at: Point(x: 200, y: 62))
        let session = try #require(fixture.session)
        #expect(fixture.tool.keyDown(TestEvents.key("c", keyCode: 8)))
        #expect(fixture.tool.keyDown(TestEvents.key("\r", keyCode: 36, flags: .shift)))
        #expect(fixture.tool.keyDown(TestEvents.key("\u{F702}", keyCode: 123)))
        #expect(!fixture.tool.keyDown(TestEvents.key("z", keyCode: 6, flags: .command)))
        #expect(!fixture.tool.keyDown(TestEvents.key("\u{1B}", keyCode: 53)))
        await fixture.settle()
        #expect(fixture.document.string(node) == "abc\u{2028}")
        #expect(session.focusOffset == 3)
        let cases: [(UInt16, NSEvent.ModifierFlags, String)] = [
            (123, [], "moveLeft:"), (123, .option, "moveWordLeft:"), (123, .command, "moveToLeftEndOfLine:"),
            (124, .shift, "moveRightAndModifySelection:"), (124, [.shift, .option], "moveWordRightAndModifySelection:"),
            (126, [], "moveUp:"), (126, .option, "moveToBeginningOfParagraph:"), (126, .command, "moveToBeginningOfDocument:"),
            (125, [], "moveDown:"), (125, [.command, .shift], "moveToEndOfDocumentAndModifySelection:"),
            (51, [], "deleteBackward:"), (51, .option, "deleteWordBackward:"), (51, .command, "deleteToBeginningOfLine:"),
            (117, [], "deleteForward:"), (117, .option, "deleteWordForward:"), (36, [], "insertNewline:"), (76, [], "insertNewline:"),
            (48, [], "insertTab:"),
        ]
        for (code, flags, selector) in cases {
            #expect(TextKeys.selector(for: TestEvents.key("x", keyCode: code, flags: flags)) == selector, "\(code) \(flags)")
            #expect(TextKeys.moves[selector] != nil || !selector.hasPrefix("move"))
        }
        #expect(TextKeys.selector(for: TestEvents.key("x", keyCode: 7)) == nil)
    }

    @Test func theToolManagerKeepsKeysForTextWhileEditing() async throws {
        let environment = TestEnvironment()
        environment.tools.replace(TextTool.descriptor)
        let document = DocumentHandle.memory(title: "Keys")
        let host = RecordingHost(viewport: TextToolTests.viewport)
        var context = ToolContext(document: document, host: host)
        let manager = ToolManager(registry: environment.tools, context: context, initialTool: TextTool.id)
        context.selectTool = { [weak manager] id in manager?.select(id) }
        let tool = try #require(manager.activeTool as? TextTool)
        tool.activate(in: context)
        #expect(!manager.isEditingText && manager.textInput == nil)
        let down = CanvasEvent(pasteboardPoint: Point(x: 20, y: 20), viewPoint: Point(x: 20, y: 20))
        manager.mouseDown(down)
        manager.mouseUp(down)
        #expect(manager.isEditingText && manager.textInput === tool)
        manager.keyDown(TestEvents.key("h", keyCode: 4))
        manager.keyDown(TestEvents.space)
        manager.keyUp(TestEvents.spaceUp)
        manager.flagsChanged(.command)
        #expect(manager.activeToolID == TextTool.id)
        manager.flagsChanged([])
        await tool.session?.settle()
        await document.settle()
        #expect(document.textNodes.first.flatMap { document.string($0) } == "h ")
        // A composition takes Esc; with none Esc ends editing and returns to the Pointer.
        tool.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0))
        #expect(manager.keyDown(TestEvents.escape))
        #expect(manager.activeToolID == TextTool.id)
        tool.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        manager.keyDown(TestEvents.escape)
        #expect(manager.activeToolID == .pointer)
    }

    // MARK: Overlay

    static func context() -> CGContext {
        CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    @Test func theOverlayDrawsTheDragTheBlockTheSelectionAndTheCaret() async throws {
        let fixture = Fixture()
        let ctx = Self.context()
        fixture.tool.drawOverlay(in: ctx, viewport: Self.viewport)
        fixture.tool.mouseDown(TestEvents.point(10, 10))
        fixture.tool.mouseDragged(TestEvents.point(80, 60))
        fixture.tool.flagsChanged(TestEvents.point(80, 60, .shift))
        #expect(fixture.tool.current?.modifiers == .shift)
        fixture.tool.drawOverlay(in: ctx, viewport: Self.viewport)
        fixture.tool.mouseUp(TestEvents.point(80, 60))
        fixture.tool.drawOverlay(in: ctx, viewport: Self.viewport)
        #expect(fixture.tool.caretRect != nil && fixture.tool.cursor == .iBeam)
        fixture.tool.mouseDragged(TestEvents.point(1, 1))
        fixture.tool.flagsChanged(TestEvents.point(1, 1))
        #expect(fixture.host.overlayRequests > 0)
    }
}
