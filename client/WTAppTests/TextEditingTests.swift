import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
import WTText
@testable import WireTuner

/// The Text tool's surroundings: the Object panel's Text section, remote and outgoing carets, the
/// window's Edit menu while editing, the Pointer's double-click, the canvas's text input client,
/// the document's text layout, and the keystroke commands.
@Suite(.serialized) @MainActor struct TextEditingTests {
    static func node(_ document: DocumentHandle, _ text: String, at point: Point = Point(x: 40, y: 60)) async throws -> OpID {
        try #require(await document.addText(text, at: point))
    }

    // MARK: Object panel

    @Test func theTextSectionFormatsWholeBlocks() async throws {
        let document = DocumentHandle.memory(title: "Section")
        let a = try await Self.node(document, "Alpha")
        let b = try await Self.node(document, "Beta", at: Point(x: 40, y: 120))
        let model = ObjectPanelModel(document: document, selection: Selection([SelectionID(a), SelectionID(b)]))
        let section = try #require(model.text)
        #expect(section.nodes == [a, b] && !section.editing)
        #expect(section.family == "Helvetica" && section.style == "Regular" && section.size == 12 && section.alignment == .left)
        #expect(InspectorRegistry.standard.views(for: model).map(\.id).contains("text"))
        _ = await model.setFontSize(18)?.value
        _ = await model.setFontFamily("Courier")?.value
        _ = await model.setFontStyle("Bold")?.value
        _ = await model.setAlignment(.right)?.value
        await document.settle()
        let after = try #require(ObjectPanelModel(document: document, selection: Selection([SelectionID(a), SelectionID(b)])).text)
        #expect(after.size == 18 && after.family == "Courier" && after.style == "Bold" && after.alignment == .right)
        #expect(document.undoTitle == "Undo Alignment")
        // One block differing shows mixed values.
        _ = await ObjectPanelModel(document: document, selection: Selection([SelectionID(a)])).setFontSize(9)?.value
        _ = await ObjectPanelModel(document: document, selection: Selection([SelectionID(a)])).setAlignment(.center)?.value
        let mixed = try #require(ObjectPanelModel(document: document, selection: Selection([SelectionID(a), SelectionID(b)])).text)
        #expect(mixed.size == nil && mixed.alignment == nil)
        #expect(model.setFontSize(0) == nil && model.setFontSize(.infinity) == nil && model.setFontFamily("") == nil && model.setFontStyle("") == nil)
        // A mixed selection has no Text section and formats nothing.
        let rect = await document.addRectangles([Rect(x: 200, y: 200, width: 10, height: 10)])[0]
        let objects = ObjectPanelModel(document: document, selection: Selection([SelectionID(a), rect]))
        #expect(objects.text == nil && objects.setAlignment(.left) == nil && objects.formatText(.with { $0.size = 3 }) == nil)
        // An emptied block reads as the defaults.
        let empty = try #require(await document.perform(CreateTextBlock(.point(Point(x: 5, y: 5)))).value?.createdObjects.first)
        await document.settle()
        #expect(ObjectPanelModel.size([]) == 12 && ObjectPanelModel.family([.with { $0.fontFamily = "" }]) == "Helvetica")
        #expect(ObjectPanelModel.style([.with { $0.fontStyle = "Italic" }]) == "Italic")
        #expect(document.state.textNode(empty)?.length == 0)
        // An emptied block that is selected shows the defaults.
        let emptied = try await Self.node(document, "x", at: Point(x: 300, y: 20))
        _ = await document.perform(DeleteText(node: emptied, from: .start, to: .end)).value
        await document.settle()
        let blank = ObjectPanelModel(document: document, selection: Selection([SelectionID(a), SelectionID(emptied)]))
        #expect(blank.text?.size == nil)
    }

    @Test func theTextSectionFormatsTheToolsSelection() async throws {
        let document = DocumentHandle.memory(title: "Editing")
        let node = try await Self.node(document, "one two")
        let session = TextEditingSession(document: document, sink: document, target: .node(node))
        session.select(anchor: 4, focus: 7)
        let model = ObjectPanelModel(document: document, selection: Selection([SelectionID(node)]), textSession: session)
        #expect(model.editingText === session && model.text?.editing == true)
        _ = await model.setFontSize(20)?.value
        await session.settle()
        _ = await model.setAlignment(.justified)?.value
        await session.settle()
        await document.settle()
        let text = try #require(document.state.textNode(node))
        #expect(text.values(at: 5).contains(.with { $0.size = 20 }) && !text.values(at: 1).contains(.with { $0.size = 20 }))
        #expect(text.paragraphs.last?.props.alignment == .justified)
        #expect(model.text?.size == 20)
        // At an insertion point the size is the pending format: nothing is written.
        session.select(anchor: 2, focus: 2)
        let changes = document.changeCount
        #expect(model.setFontSize(30) == nil)
        #expect(document.changeCount == changes && model.text?.size == 30)
        session.select(anchor: 7, focus: 7)
        #expect(session.formatRuns.first?.contains(.with { $0.size = 20 }) == true)
        // A session on a block that is not selected is not used.
        let other = ObjectPanelModel(document: document, selection: .empty, textSession: session)
        #expect(other.editingText == nil)
    }

    @Test func theTextSectionViewAndItsBindings() async throws {
        let document = DocumentHandle.memory(title: "View")
        let node = try await Self.node(document, "View")
        let model = ObjectPanelModel(document: document, selection: Selection([SelectionID(node)]))
        let section = try #require(model.text)
        let host = NSHostingView(rootView: TextSectionView(section: section, model: model))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        host.layoutSubtreeIfNeeded()
        let mixedSection = ObjectPanelModel.TextSection(nodes: [node], editing: false, family: nil, style: nil, size: nil, alignment: nil)
        let mixedHost = NSHostingView(rootView: TextSectionView(section: mixedSection, model: model))
        mixedHost.frame = host.frame
        mixedHost.layoutSubtreeIfNeeded()
        #expect(TextSectionView.family(mixedSection, model).wrappedValue == TextSectionView.mixed)
        #expect(TextSectionView.style(mixedSection, model).wrappedValue == TextSectionView.mixed)
        #expect(TextSectionView.alignment(mixedSection, model).wrappedValue == TextSectionView.mixed)
        TextSectionView.family(mixedSection, model).wrappedValue = TextSectionView.mixed
        TextSectionView.style(mixedSection, model).wrappedValue = TextSectionView.mixed
        TextSectionView.alignment(mixedSection, model).wrappedValue = "Nowhere"
        #expect(document.undoTitle == "Undo Type")
        TextSectionView.family(section, model).wrappedValue = "Menlo"
        TextSectionView.style(section, model).wrappedValue = "Bold"
        TextSectionView.alignment(section, model).wrappedValue = "Center"
        await document.settle()
        let after = try #require(ObjectPanelModel(document: document, selection: Selection([SelectionID(node)])).text)
        #expect(after.family == "Menlo" && after.style == "Bold" && after.alignment == .center)
        #expect(TextSectionView.alignment(after, model).wrappedValue == "Center")
        TextSectionView.size(model)(15)
        await document.settle()
        #expect(ObjectPanelModel(document: document, selection: Selection([SelectionID(node)])).text?.size == 15)
        #expect(TextSectionView.families(including: "No Such Family").first == "No Such Family")
        #expect(TextSectionView.families(including: "Helvetica").contains("Helvetica"))
        #expect(TextSectionView.styles(of: "Helvetica", including: "Regular").first == "Regular")
        #expect(TextSectionView.styles(of: "No Such Family", including: nil) == ["Regular"])
        #expect(TextSectionView.styles(of: nil, including: "Odd").first == "Odd")
        #expect(AttributesListModel.kindName(.text) == "Text")
    }

    // MARK: Presence

    @Test func remoteCaretsSitOnTheirCharacters() async throws {
        let document = DocumentHandle.memory(title: "Carets")
        let node = try await Self.node(document, "abc def")
        let text = try #require(document.state.textNode(node))
        let viewport = Viewport(size: Size(width: 400, height: 300))
        let overlay = PresenceOverlay(document: document, viewport: viewport)
        var priya = RemoteParticipant(id: "p", name: "Priya", colorIndex: 1)
        priya.caret = RemoteCaret(node: SelectionID(node), position: text.chars[4])
        let flag = try #require(overlay.carets([priya]).first)
        let layout = try #require(document.textLayout(for: node))
        let expected = viewport.toView(Point(x: 40, y: 60) + (layout.caret(atOffset: 4)!.top - .zero))
        #expect(abs(flag.rect.minX - expected.x) < 0.01 && flag.rect.height > 5)
        // The end, a range, a character typed before it.
        priya.caret = RemoteCaret(node: SelectionID(node), position: .zero)
        #expect(overlay.caretGeometry(priya.caret!)?.selection.isEmpty == true)
        priya.caret = RemoteCaret(node: SelectionID(node), position: text.chars[0], rangeEnd: text.chars[3])
        #expect(overlay.textSelections([priya]).count == 1)
        let before = try #require(overlay.carets([priya]).first?.rect.minX)
        _ = await document.perform(InsertText(node: node, text: "XY", at: .start)).value
        await document.settle()
        let after = try #require(overlay.carets([priya]).first?.rect.minX)
        #expect(after > before)
        // A deleted character reads where it was; an unknown one is not drawn; nor a deleted block.
        _ = await document.perform(DeleteText(node: node, from: text.anchor(at: 0), to: text.anchor(at: 1))).value
        await document.settle()
        #expect(overlay.carets([priya]).count == 1)
        priya.caret = RemoteCaret(node: SelectionID(node), position: OpID(counter: 999, replica: 99))
        #expect(overlay.caretGeometry(priya.caret!) == nil)
        #expect(overlay.carets([priya]).count == 1)
        let empty = try #require(await document.perform(CreateTextBlock(.point(Point(x: 5, y: 5)))).value?.createdObjects.first)
        await document.settle()
        priya.caret = RemoteCaret(node: SelectionID(empty), position: .zero)
        #expect(overlay.carets([priya]).isEmpty)
        _ = await document.perform(DeleteNodes([node])).value
        await document.settle()
        priya.caret = RemoteCaret(node: SelectionID(node), position: .zero)
        #expect(overlay.carets([priya]).isEmpty && overlay.textSelections([priya]).isEmpty)
        overlay.draw(in: TextToolTests.context(), participants: [priya], options: PresenceDisplayOptions(), clock: CursorLabelClock())
    }

    @Test func theToolsCaretIsPublished() async throws {
        let presence = LocalPresence()
        let publisher = LocalPresencePublisher(presence: presence)
        let node = OpID(counter: 5, replica: 1)
        publisher.caret(PresenceCaret(node: node, text: TextFields.text, position: OpID(counter: 7, replica: 1), rangeEnd: OpID(counter: 9, replica: 1)))
        var update = await presence.presence()
        #expect(update?.caret.node == node.proto && update?.caret.position == OpID(counter: 7, replica: 1).elementID && update?.caret.hasRangeEnd == true)
        #expect(update?.caret.text == TextFields.text.proto)
        publisher.caret(PresenceCaret(node: node, text: TextFields.text, position: .zero, rangeEnd: nil))
        update = await presence.presence()
        #expect(update?.caret.hasRangeEnd == false)
        publisher.caret(nil)
        update = await presence.presence()
        #expect(update?.hasCaret == false)
    }

    /// A change another replica makes against `document`'s state, delivered as the sync client would.
    static func remote(_ command: any WTModel.Command, on document: DocumentHandle, replica: UInt64 = 0xBEEF) async throws -> Wiretuner_Doc_V1_Change {
        var other = DocumentCore(state: document.state, replica: replica)
        let change = try #require(try other.perform(command, recording: DocumentCore.Recording(limit: 10, now: Date()))?.change)
        _ = await document.receive(change).value
        await document.settle()
        return change
    }

    @Test func aRemoteDeleteUnderTheCaretLeavesItAfterTheNearestPredecessor() async throws {
        let document = DocumentHandle.memory(title: "Caret")
        let node = try await Self.node(document, "abcd")
        let session = TextEditingSession(document: document, sink: document, target: .node(node))
        session.select(anchor: 2, focus: 2)
        let text = try #require(document.state.textNode(node))
        // Someone else deletes "c", the character the caret is before, and "b" before it.
        _ = try await Self.remote(DeleteText(node: node, from: text.anchor(at: 1), to: text.anchor(at: 3)), on: document)
        #expect(document.string(node) == "ad" && session.focusOffset == 1)
        session.insert("X")
        await session.settle()
        await document.settle()
        #expect(document.string(node) == "aXd" && session.focusOffset == 2)
    }

    @Test func aPublishedSelectionResolvesToTheSameCharactersOnAnotherReplica() async throws {
        let mine = DocumentHandle.memory(title: "Mine")
        let node = try await Self.node(mine, "hello world")
        let session = TextEditingSession(document: mine, sink: mine, target: .node(node))
        session.select(anchor: 6, focus: 11)
        let published = try #require(session.presenceCaret)
        // The other replica has the text and, concurrently, types at the start.
        var theirs = DocumentCore(state: mine.state, replica: 0xCAFE)
        _ = try theirs.perform(InsertText(node: node, text: ">> ", at: .start), recording: DocumentCore.Recording(limit: 10, now: Date()))
        let text = try #require(theirs.state.textNode(node))
        let start = try #require(PresenceOverlay.offset(published.position, in: text))
        let rangeEnd = try #require(published.rangeEnd)
        let end = try #require(PresenceOverlay.offset(rangeEnd, in: text))
        let scalars = Array(text.string.unicodeScalars)
        #expect(String(String.UnicodeScalarView(scalars[start..<end])) == "world")
        #expect(PresenceOverlay.offset(.zero, in: text) == text.length)
    }

    // MARK: Window

    @Test func theEditMenuActsOnTextWhileEditing() async throws {
        let environment = TestEnvironment()
        environment.tools.replace(TextTool.descriptor)
        environment.tools.replace(PointerTool.descriptor)
        let document = DocumentHandle.memory(title: "Menu")
        let controller = DocumentWindowController(document: document, environment: environment.document)
        defer { controller.close() }
        let node = try await Self.node(document, "menu text")
        #expect(controller.textEditor == nil)
        controller.editText(node, at: Point(x: 40, y: 62))
        let session = try #require(controller.textEditor)
        session.pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.menu.\(UUID().uuidString)"))
        #expect(controller.toolManager.activeToolID == TextTool.id && controller.objectEditing.textSession === session)
        #expect(controller.validate(selector: #selector(DocumentWindowController.selectAll(_:))))
        #expect(!controller.validate(selector: #selector(DocumentWindowController.copy(_:))))
        #expect(!controller.validate(selector: #selector(DocumentWindowController.selectNone(_:))))
        #expect(controller.validate(selector: #selector(DocumentWindowController.delete(_:))))
        #expect(controller.validate(selector: #selector(NSResponder.moveLeft(_:))))
        controller.selectAll(nil)
        #expect(session.selectedRange == 0..<9)
        #expect(controller.validate(selector: #selector(DocumentWindowController.cut(_:))))
        controller.copy(nil)
        controller.cut(nil)
        await session.settle()
        await document.settle()
        #expect(document.string(node) == "")
        #expect(controller.validate(selector: #selector(DocumentWindowController.paste(_:))))
        controller.paste(nil)
        await session.settle()
        await document.settle()
        #expect(document.string(node) == "menu text")
        controller.delete(nil)
        await session.settle()
        await document.settle()
        #expect(document.string(node) == "menu tex")
        session.setMarkedText("x", selected: NSRange(location: 1, length: 0))
        #expect(!controller.validate(selector: #selector(DocumentWindowController.delete(_:))))
        session.setMarkedText("", selected: NSRange(location: 0, length: 0))
        // Esc ends editing and returns to the Pointer; the Pointer's double-click on the block
        // hands it back to the Text tool; a click away returns to the Pointer again.
        controller.toolManager.keyDown(TestEvents.escape)
        #expect(controller.toolManager.activeToolID == .pointer && controller.textEditor == nil)
        await document.settle()
        let viewport = controller.canvas.viewport
        let bounds = try #require(document.object(for: SelectionID(node))?.bounds)
        let middle = Point(x: bounds.minX + 3, y: bounds.minY + 3)
        let press = CanvasEvent(pasteboardPoint: middle, viewPoint: viewport.toView(middle), clickCount: 2)
        controller.toolManager.mouseDown(press)
        controller.toolManager.mouseUp(press)
        #expect(controller.toolManager.activeToolID == TextTool.id && controller.textEditor?.node == node)
        let away = Point(x: bounds.maxX + 300, y: bounds.maxY + 300)
        let click = CanvasEvent(pasteboardPoint: away, viewPoint: viewport.toView(away))
        controller.toolManager.mouseDown(click)
        controller.toolManager.mouseUp(click)
        #expect(controller.toolManager.activeToolID == .pointer)
    }

    @Test func thePointerDoubleClickOnTextAsksToEditIt() async throws {
        let document = DocumentHandle.memory(title: "Pointer")
        let node = try await Self.node(document, "Double")
        let controller = SelectionController(document: document)
        let host = RecordingHost()
        var context = ToolContext(document: document, host: host, selection: controller)
        var asked: [OpID] = []
        context.editText = { node, _ in asked.append(node) }
        let pointer = PointerTool()
        pointer.activate(in: context)
        let bounds = try #require(document.object(for: SelectionID(node))?.bounds)
        let press = CanvasEvent(pasteboardPoint: Point(x: bounds.midX, y: bounds.midY), viewPoint: Point(x: bounds.midX, y: bounds.midY), clickCount: 2)
        pointer.mouseDown(press)
        pointer.mouseUp(press)
        #expect(asked == [node])
        // Option-double-click is the Text Editor's (TYPE-011), not the Text tool's.
        let option = CanvasEvent(pasteboardPoint: press.pasteboardPoint, viewPoint: press.viewPoint, modifiers: .option, clickCount: 2)
        pointer.mouseDown(option)
        pointer.mouseUp(option)
        #expect(asked == [node])
    }

    @Test func thePointerSelectsTextBlocksByAClickAndAMarquee() async throws {
        let document = DocumentHandle.memory(title: "Select")
        let node = try await Self.node(document, "Pick me\nand me")
        let controller = SelectionController(document: document)
        let viewport = Viewport(size: Size(width: 400, height: 300))
        let bounds = try #require(document.object(for: SelectionID(node))?.bounds)
        let middle = viewport.toView(Point(x: bounds.minX + 3, y: bounds.minY + 3))
        for subselect in [false, true] {
            controller.selectNone()
            controller.click(at: middle, viewport: viewport, modifiers: [], subselect: subselect)
            #expect(controller.selection.ids == [SelectionID(node)])
        }
        let area = Rect(viewport.toView(Point(x: bounds.minX - 5, y: bounds.minY - 5)), viewport.toView(Point(x: bounds.maxX + 5, y: bounds.maxY + 5)))
        for subselect in [false, true] {
            controller.selectNone()
            controller.marquee(area, viewport: viewport, modifiers: [], subselect: subselect)
            #expect(controller.selection.ids == [SelectionID(node)])
        }
    }

    @Test func theCanvasIsATextInputClientWhileTextIsEdited() async throws {
        let environment = TestEnvironment()
        environment.tools.replace(TextTool.descriptor)
        let document = DocumentHandle.memory(title: "Input")
        let controller = DocumentWindowController(document: document, environment: environment.document)
        defer { controller.close() }
        let canvas = controller.canvas
        #expect(canvas.inputContext == nil && !canvas.interpretKeys(TestEvents.key("a", keyCode: 0)))
        canvas.insertText("ignored", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(canvas.selectedRange().location == NSNotFound && canvas.markedRange().location == NSNotFound && !canvas.hasMarkedText())
        #expect(canvas.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil) == .zero)
        #expect(canvas.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: nil) == nil)
        let node = try await Self.node(document, "ab")
        controller.editText(node, at: Point(x: 400, y: 62))
        #expect(canvas.inputContext != nil)
        canvas.insertText(NSAttributedString(string: "c"), replacementRange: NSRange(location: NSNotFound, length: 0))
        await controller.textEditor?.settle()
        canvas.setMarkedText("d", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(canvas.hasMarkedText() && canvas.markedRange() == NSRange(location: 3, length: 1))
        canvas.unmarkText()
        canvas.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        await controller.textEditor?.settle()
        await document.settle()
        #expect(document.string(node) == "abcd")
        #expect(canvas.selectedRange() == NSRange(location: 3, length: 0))
        var actual = NSRange(location: 0, length: 0)
        #expect(canvas.attributedSubstring(forProposedRange: NSRange(location: 1, length: 2), actualRange: &actual)?.string == "bc")
        #expect(actual == NSRange(location: 1, length: 2))
        #expect(canvas.validAttributesForMarkedText().isEmpty && canvas.characterIndex(for: .zero) == NSNotFound)
        #expect(canvas.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil).height > 0)
        #expect(CanvasView.string(42) == "")
        #expect(canvas.interpretKeys(TestEvents.key("e", keyCode: 14)))
        #expect(controller.toolManager.keyDown(TestEvents.key("f", keyCode: 3)))
        let loose = CanvasView(document: document, tiles: CanvasView.makeFallbackTiles())
        #expect(loose.screenRect(ofPasteboardRect: Rect(x: 0, y: 0, width: 10, height: 10)).width > 0)
    }

    // MARK: Document

    @Test func theDocumentLaysTextOutWithItsOwnEngine() async throws {
        let document = DocumentHandle.memory(title: "Engine")
        let node = try await Self.node(document, "Engine")
        let first = try #require(document.textLayout(for: node))
        #expect(document.textLayout(for: node)?.characterCount == first.characterCount)
        #expect(document.textLayout(for: WellKnown.layers) == nil)
        let engine = TextLayoutEngine(fonts: FontManager())
        let before = document.changeCount
        document.useTextEngine(engine)
        #expect(document.textEngine === engine && document.changeCount == before)
        document.useTextEngine(engine)
        #expect(document.object(for: SelectionID(node))?.kind == .text)
        #expect(document.textLayout(for: node)?.characterCount == 6)
    }

    // MARK: Commands

    @Test func keystrokeCommandsResolveAtTheirTurn() async throws {
        let document = DocumentHandle.memory(title: "Keystrokes")
        let node = try await Self.node(document, "ab")
        func perform(_ action: TextKeystroke.Action, _ start: WTCRDT.Anchor, _ end: WTCRDT.Anchor) async -> Wiretuner_Doc_V1_Change? {
            let change = await document.perform(TextKeystroke(node: node, from: start, to: end, action)).value
            await document.settle()
            return change
        }
        #expect(TextKeystroke(node: node, from: .start, to: .start, .insert("x")).label == "Type")
        #expect(TextKeystroke(node: node, from: .start, to: .start, .backspace).label == "Delete text")
        #expect(await perform(.backspace, .start, .start) == nil)
        #expect(await perform(.forwardDelete, .end, .end) == nil)
        #expect(await perform(.insert(""), .start, .start) == nil)
        #expect(await perform(.deleteSelection, .start, .start) == nil)
        #expect(await perform(.forwardDelete, .start, .end) != nil)
        #expect(document.string(node) == "")
        _ = await perform(.insert("one two"), .start, .start)
        let text = try #require(document.state.textNode(node))
        _ = await perform(.deleteWordForward, text.anchor(at: 3), text.anchor(at: 3))
        #expect(document.string(node) == "one")
        _ = await perform(.deleteWordForward, .start, .start)
        #expect(document.string(node) == "")
        _ = await perform(.insert("ontwo"), .start, .start)
        let ontwo = try #require(document.state.textNode(node))
        _ = await perform(.forwardDelete, ontwo.anchor(at: 1), ontwo.anchor(at: 3))
        #expect(document.string(node) == "owo")
        _ = await perform(.deleteWordBackward, .start, .end)
        #expect(document.string(node) == "")
        let idle = TextKeystroke(node: node, from: .start, to: .start, .backspace)
        _ = await document.perform(idle).value
        #expect(idle.coalescing == .none)
        _ = await perform(.insert("keep"), .start, .start)
        let kept = try #require(document.state.textNode(node))
        _ = await perform(.insert(""), kept.anchor(at: 1), kept.anchor(at: 3))
        #expect(document.string(node) == "kp")
        let missing = TextKeystroke(node: WellKnown.layers, from: .start, to: .end, .backspace)
        var builder = ChangeBuilder(replica: 1, startCounter: 1)
        #expect(throws: TextEditError.self) { try missing.execute(&builder, state: document.state) }
        // The first character of a new block opens the undo step; more than one does not.
        let many = TypeNewTextBlock(CreateTextBlock(.point(.zero), text: "ab"), typing: true)
        _ = await document.perform(many).value
        #expect(many.coalescing == .none && many.label == "Type")
        let newline = TypeNewTextBlock(CreateTextBlock(.point(.zero), text: "\n"), typing: true)
        _ = await document.perform(newline).value
        #expect(newline.coalescing == .none)
        let one = TypeNewTextBlock(CreateTextBlock(.point(.zero), text: "a"), typing: true)
        _ = await document.perform(one).value
        if case .text(nil, .text(let key)?) = one.coalescing { #expect(key.kind == .typing) } else { Issue.record("opens a typing step") }
        // After other ops of the same change the ids still count from the change's start.
        let batched = TypeNewTextBlock(CreateTextBlock(.point(.zero), text: "b"), typing: true)
        var batch = ChangeBuilder(replica: 7, startCounter: 100)
        batch.append(Ops.set(node, [RegisterPath([130, 1, 1])], values: .with { $0.text.common.name = "n" }))
        try batched.execute(&batch, state: document.state)
        if case .text(nil, .text(let key)?) = batched.coalescing { #expect(key.caret.counter > 101 && key.node.counter > 100) } else { Issue.record("opens a step") }
        // Words and lines at the edges.
        #expect(TextNavigation.wordStart(before: 3, in: Array("ab cd".unicodeScalars)) == 0)
        #expect(TextNavigation.lineIndex(of: 0, in: [2..<4], upstream: false) == 0)
    }
}
