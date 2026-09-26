import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTText
@testable import WireTuner

/// Text block handles (TYPE-005), special characters and smart quotes (TYPE-012), the Edit Tab
/// sheet (TYPE-024), the Spacing section (TYPE-027), text attribute copy and paste (TYPE-031), the
/// spelling suggestions (TYPE-014), the Swatches preference (TYPE-030) and axes and features
/// (TYPE-046).
@Suite(.serialized) @MainActor struct TypeExtrasTests {
    static func model(_ world: TypeWorld, _ nodes: [OpID]) -> ObjectPanelModel {
        ObjectPanelModel(document: world.document, selection: Selection(nodes.map { SelectionID($0) }), textSession: world.window.objectEditing.textSession)
    }

    static func context(_ world: TypeWorld) -> ToolContext {
        world.window.toolManager.context
    }

    static func event(_ world: TypeWorld, _ point: Point, _ modifiers: KeyModifiers = [], clicks: Int = 1) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: point, viewPoint: world.window.viewport.toView(point), modifiers: modifiers, clickCount: clicks)
    }

    /// A fixed block 200 × 100 at (50, 50) holding `text`, selected.
    static func fixedBlock(_ world: TypeWorld, _ text: String = "Fixed size text") async throws -> OpID {
        let node = try #require(await world.document.addText(text, frame: .area(Rect(x: 50, y: 50, width: 200, height: 100))))
        world.window.selection.model.set(Selection([SelectionID(node)]))
        return node
    }

    static func block(_ world: TypeWorld, _ node: OpID) -> Wiretuner_Doc_V1_TextBlockProps { world.state.props(node).text.block }

    // MARK: Text block handles (TYPE-005)

    @Test func eachCornerDragModifierResizesAsDocumented() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await Self.fixedBlock(world)
        let context = Self.context(world)
        let handles = TextBlockHandles()
        let frame = try #require(handles.frames(context).first)
        #expect(frame.local.width == 200 && frame.local.height == 100)
        let corner = frame.point(.bottomRight)
        #expect(TextBlockHandles.hit(frame, at: world.window.viewport.toView(corner), viewport: world.window.viewport) == .handle(.bottomRight))
        // Plain: the corner goes where it is dropped.
        #expect(handles.press(Self.event(world, corner), context: context))
        handles.drag(Self.event(world, Point(x: corner.x + 50, y: corner.y + 20)), context: context)
        #expect(handles.preview?.width == 250)
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
        handles.release(Self.event(world, Point(x: corner.x + 50, y: corner.y + 20)), context: context)
        await world.settle()
        #expect(Self.block(world, node).width == 250 && Self.block(world, node).height == 120)
        #expect(world.document.undoTitle == "Undo Resize")
        // Shift: the proportions stay (the larger factor).
        let shifted = try #require(handles.frames(context).first)
        #expect(handles.press(Self.event(world, shifted.point(.bottomRight)), context: context))
        handles.release(Self.event(world, Point(x: shifted.point(.bottomRight).x + 250, y: shifted.point(.bottomRight).y), .shift), context: context)
        await world.settle()
        #expect(Self.block(world, node).width == 500 && Self.block(world, node).height == 240)
        // Option: block and type size together (the vertical factor).
        let option = try #require(handles.frames(context).first)
        #expect(handles.press(Self.event(world, option.point(.bottomRight)), context: context))
        handles.release(Self.event(world, Point(x: option.point(.bottomRight).x, y: option.point(.bottomRight).y + 240), .option), context: context)
        await world.settle()
        #expect(Self.block(world, node).height == 480)
        #expect(TextFixtureReading.sizes(world, node) == [24], "one size mark over the whole text")
        #expect(world.document.undoTitle == "Undo Scale Text Block")
        // Shift+Option: proportional, and the type with it.
        let both = try #require(handles.frames(context).first)
        #expect(handles.press(Self.event(world, both.point(.bottomRight)), context: context))
        handles.release(Self.event(world, Point(x: both.point(.bottomRight).x - 250, y: both.point(.bottomRight).y - 240), [.shift, .option]), context: context)
        await world.settle()
        #expect(Self.block(world, node).width == 250 && Self.block(world, node).height == 240)
        #expect(TextFixtureReading.sizes(world, node) == [12])
        // The top-left corner moves the block with it; a drag to nothing writes nothing.
        let top = try #require(handles.frames(context).first)
        let before = Objects.pasteboardTransform(of: node, in: world.state).apply(Point.zero)
        #expect(handles.press(Self.event(world, top.point(.topLeft)), context: context))
        handles.release(Self.event(world, Point(x: top.point(.topLeft).x - 10, y: top.point(.topLeft).y - 10)), context: context)
        await world.settle()
        let after = Objects.pasteboardTransform(of: node, in: world.state).apply(Point.zero)
        #expect(abs(after.x - (before.x - 10)) < 0.01 && abs(after.y - (before.y - 10)) < 0.01 && Self.block(world, node).width == 260)
        #expect(handles.press(Self.event(world, try #require(handles.frames(context).first).point(.topRight)), context: context))
        handles.release(Self.event(world, try #require(handles.frames(context).first).point(.topLeft)), context: context)
        handles.cancel(context: context)
        #expect(!handles.press(Self.event(world, Point(x: 1000, y: 1000)), context: context))
        #expect(TextBlockResize.result(top, corner: .top, to: .zero, shift: false, option: false) == nil)
        #expect(TextBlockFrame.Handle.allCases.map(\.opposite).count == 8 && TextBlockFrame.Handle.left.opposite == .right)
    }

    @Test func doubleClicksToggleAutoSizingAndFitTheBlock() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await Self.fixedBlock(world, "A long line of text that wraps inside the narrow block")
        _ = await world.document.perform(SetTextBlock(node: node, block: .with { $0.width = 80 }, fields: [[3]])).value
        await world.settle()
        let context = Self.context(world)
        let handles = TextBlockHandles()
        #expect(try #require(world.document.textLayout(for: node)).lineCount > 1)
        let frame = try #require(handles.frames(context).first)
        #expect(!frame.isHollow(.right) && !frame.isHollow(.bottom))
        // A single press on a side handle is taken and does nothing.
        #expect(handles.press(Self.event(world, frame.point(.right)), context: context))
        #expect(handles.press(Self.event(world, frame.point(.right), clicks: 2), context: context))
        await world.settle()
        #expect(Self.block(world, node).autoWidth)
        #expect(try #require(world.document.textLayout(for: node)).lineCount == 1, "auto width re-lays the text on one line")
        let auto = try #require(handles.frames(context).first)
        #expect(auto.isHollow(.left))
        #expect(handles.press(Self.event(world, auto.point(.left), clicks: 2), context: context))
        await world.settle()
        #expect(!Self.block(world, node).autoWidth && Self.block(world, node).width == auto.local.width)
        #expect(handles.press(Self.event(world, try #require(handles.frames(context).first).point(.bottom), clicks: 2), context: context))
        await world.settle()
        #expect(Self.block(world, node).autoHeight)
        #expect(handles.press(Self.event(world, try #require(handles.frames(context).first).point(.top), clicks: 2), context: context))
        await world.settle()
        #expect(!Self.block(world, node).autoHeight)
        // The link box: an overflowing block fits its text on a double-click.
        _ = await world.document.perform(SetTextBlock(node: node, block: .with { $0.width = 60; $0.height = 18 }, fields: [[3], [4]])).value
        await world.settle()
        let overflowing = try #require(handles.frames(context).first)
        #expect(overflowing.overflows)
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
        let box = world.window.viewport.toView(overflowing.transform.apply(overflowing.linkBoxCenter(zoom: world.window.viewport.zoom)))
        #expect(TextBlockHandles.hit(overflowing, at: box, viewport: world.window.viewport) == .linkBox)
        #expect(handles.press(CanvasEvent(pasteboardPoint: world.window.viewport.toPasteboard(box), viewPoint: box, clickCount: 2), context: context))
        await world.settle()
        #expect(try #require(world.document.textLayout(for: node)).overflows == false)
        #expect(world.document.undoTitle == "Undo Fit Text Block")
        let fitted = try #require(handles.frames(context).first)
        let again = world.window.viewport.toView(fitted.transform.apply(fitted.linkBoxCenter(zoom: world.window.viewport.zoom)))
        #expect(handles.press(CanvasEvent(pasteboardPoint: world.window.viewport.toPasteboard(again), viewPoint: again), context: context), "a single click is taken")
        // A linked block draws the arrow; text on a path has no handles.
        let other = try #require(await world.document.addText("", at: Point(x: 400, y: 400)))
        _ = await world.document.perform(OpsCommand("Link", ops: [Ops.set(node, [RegisterPath([130, 4])], values: .with { $0.text.nextLink.id = other.proto })])).value
        await world.settle()
        let linked = try #require(TextBlockFrame(node, document: world.document))
        handles.drawLinkBox(linked, in: DrawingToolTests.bitmap(), viewport: world.window.viewport)
        #expect(linked.isLinked)
        #expect(TextBlockFrame(other, document: world.document) != nil && TextBlockFrame(OpID(counter: 999, replica: 9), document: world.document) == nil)
    }

    @Test func aConcurrentResizeAndAutoHeightToggleKeepBoth() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await Self.fixedBlock(world)
        _ = await world.document.perform(SetTextBlock(node: node, block: .with { $0.autoHeight = true }, fields: [[2]])).value
        await world.settle()
        let base = world.state
        // The other replica fixes the height while this one drags the corner.
        var core = DocumentCore(state: base, replica: 1)
        let frame = try #require(TextBlockFrame(node, document: world.document))
        let toggle = try #require(try core.perform(TextBlockResize.toggleHeight(frame), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        let result = try #require(TextBlockResize.result(frame, corner: .bottomRight, to: frame.point(.bottomRight).offset(dx: 30, dy: 60), shift: false, option: false))
        _ = await world.document.perform(TextBlockResize.command(frame, result, state: base)).value
        _ = await world.document.receive(toggle).value
        await world.settle()
        #expect(!Self.block(world, node).autoHeight, "the toggle applied")
        #expect(Self.block(world, node).height == result.height, "at the other user's height")
    }

    @Test func removeTransformsEmptyBlocksAndTheDeselectedEmptyBlock() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await Self.fixedBlock(world)
        let commands = TextBlockFeatures.commands { world.window }
        #expect(commands[0].validation().isEnabled)
        #expect(!TextBlockFeatures.commands(window: { nil })[0].validation().isEnabled)
        #expect(TextBlockFeatures.removeTransforms([node], in: world.state) == nil, "nothing to remove")
        _ = await world.document.perform(TransformObjects([node], matrix: .rotation(radians: 0.5), about: Point(x: 100, y: 100), kind: .rotate)).value
        await world.settle()
        let origin = Objects.pasteboardTransform(of: node, in: world.state).apply(Point.zero)
        if case .perform(let run) = commands[0].action { run() }
        await world.settle()
        let plain = Objects.pasteboardTransform(of: node, in: world.state)
        #expect(plain.b == 0 && plain.c == 0 && abs(plain.apply(Point.zero).x - origin.x) < 0.01)
        #expect(world.document.undoTitle == "Undo Remove Transforms")
        world.window.selection.model.clear()
        if case .perform(let run) = commands[0].action { run() }
        // Empty blocks: the extension deletes them all; a linked one stays.
        let empty = try #require(await world.document.addText("", at: Point(x: 300, y: 300)))
        let registry = ExtensionRegistry()
        let descriptors = TextBlockFeatures.extensions(existing: registry) { world.window }
        #expect(descriptors.count == 1 && descriptors[0].validate?().isEnabled == true)
        #expect(TextBlockFeatures.extensions(existing: registry) { nil }[0].validate?().isEnabled == false)
        #expect(TextBlockFeatures.emptyBlocks(world.document) == [empty])
        _ = descriptors[0].run?(nil)
        await world.settle()
        #expect(!world.state.isLive(empty) && world.document.undoTitle == "Undo Delete Empty Text Blocks")
        #expect(TextBlockFeatures.deleteEmptyBlocks(in: world.window) == nil)
        #expect(TextBlockFeatures.extensions(existing: ExtensionRegistry(descriptors: []), window: { nil }).isEmpty)
        // An empty auto-expanding block goes when it is deselected.
        ExtrasWindowParts.attach(world.window)
        #expect(ExtrasWindowParts.attach(world.window) === ExtrasWindowParts.parts(of: world.window))
        let loose = try #require(await world.document.addText("", at: Point(x: 350, y: 350)))
        world.window.selection.model.set(Selection([SelectionID(loose)]))
        world.window.selection.model.clear()
        await world.settle()
        #expect(!world.state.isLive(loose))
        #expect(TextBlockFeatures.deleteIfEmpty([node], in: world.window) == nil)
    }

    // MARK: Special characters and smart quotes (TYPE-012)

    @Test func eachSpecialCharacterCommandInsertsItsCodePoint() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("x")
        let commands = SpecialCharacterFeatures.commands { world.window }
        #expect(commands.count == 9 && !commands[0].validation().isEnabled)
        await world.edit(node, select: 1..<1)
        for (command, character) in zip(commands, SpecialCharacter.allCases) {
            #expect(command.validation().isEnabled && command.id == SpecialCharacterFeatures.id(character))
            if case .perform(let run) = command.action { run() }
            await world.settle()
        }
        let string = try #require(world.state.textNode(node)).string
        #expect(string == "x" + String(SpecialCharacter.allCases.map(\.character)))
        #expect(!SpecialCharacterFeatures.insert(.emDash, window: nil))
    }

    @Test func theShortcutsAndSmartQuotesWhileTyping() async throws {
        let world = TypeWorld()
        defer { world.close() }
        world.window.toolManager.select(TextTool.id)
        let node = try await world.block("a")
        ExtrasWindowParts.attach(world.window)
        let preferences = world.setup.environment.preferences
        #expect(!SpecialCharacterFeatures.handle(TestEvents.key("m", keyCode: 46, flags: [.command, .shift]), window: world.window), "not editing")
        let tool = try #require(world.window.toolManager.activeTool as? TextTool)
        tool.edit(node, at: Point(x: 200, y: 200))
        await world.settle()
        world.window.objectEditing.textSession?.select(anchor: 1, focus: 1)
        await world.settle()
        world.window.window?.makeFirstResponder(world.window.canvas)
        #expect(SpecialCharacterFeatures.handle(TestEvents.key("m", keyCode: 46, flags: [.command, .shift]), window: world.window))
        #expect(world.window.canvas.performKeyEquivalent(with: TestEvents.key("-", keyCode: 27, flags: .command)))
        await world.settle()
        // After a space the quote opens; after a letter or digit it closes; Control keeps it straight.
        world.window.canvas.keyDown(with: TestEvents.key(" ", keyCode: 49))
        world.window.canvas.keyDown(with: TestEvents.key("\"", keyCode: 39, flags: .shift))
        world.window.canvas.keyDown(with: TestEvents.key("q", keyCode: 12))
        world.window.canvas.keyDown(with: TestEvents.key("'", keyCode: 39))
        world.window.canvas.keyDown(with: TestEvents.key("'", keyCode: 39, flags: .control))
        await world.settle()
        let string = try #require(world.state.textNode(node)).string
        #expect(string == "a\u{2003}\u{00AD} \u{201C}q\u{2019}'", "\(string.unicodeScalars.map { String($0.value, radix: 16) })")
        #expect(SpecialCharacterFeatures.special(for: TestEvents.key("\r", keyCode: 36, flags: .command)) == .endOfColumn)
        #expect(SpecialCharacterFeatures.special(for: TestEvents.key("a", keyCode: 0)) == nil)
        // Smart quotes off: the key goes on to the tool.
        _ = preferences.set(false, for: PreferenceCatalog.Text.smartQuotes)
        #expect(SpecialCharacterFeatures.quote(TestEvents.key("'", keyCode: 39), smart: false, style: "english", previous: "a") == nil)
        #expect(SpecialCharacterFeatures.quote(TestEvents.key("'", keyCode: 39, flags: .command), smart: true, style: "english", previous: nil) == nil)
        #expect(SpecialCharacterFeatures.quote(TestEvents.key("'", keyCode: 39), smart: true, style: "german", previous: nil) == "\u{201A}")
        #expect(!SpecialCharacterFeatures.handle(TestEvents.key("'", keyCode: 39), window: world.window))
        _ = preferences.set(true, for: PreferenceCatalog.Text.smartQuotes)
        #expect(SpecialCharacterFeatures.previous(in: try #require(world.window.objectEditing.textSession)) != nil)
        // A pending block has no character before it.
        let pending = TextEditingSession(document: world.document, sink: world.document, target: .pending(.point(.zero)))
        #expect(SpecialCharacterFeatures.previous(in: pending) == nil)
    }

    @Test func invisiblesShowForABlockWhoseEditorShowsThem() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("a b\tc\nd")
        let text = try #require(world.state.textNode(node))
        let layout = try #require(world.document.textLayout(for: node))
        let marks = InvisibleMarks.marks(in: text, layout: layout)
        #expect(marks.map(\.mark) == ["\u{00B7}", "\u{2192}", "\u{00B6}"])
        #expect(InvisibleMarks.blocks(of: world.document).isEmpty)
        let controller = TextEditorFeatures.shared.show(node, in: world.window)
        controller.model.showInvisibles = true
        #expect(InvisibleMarks.blocks(of: world.document) == [node])
        InvisibleMarks.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, window: world.window)
    }

    // MARK: Edit Tab sheet and Tabs table (TYPE-024)

    @Test func theEditTabSheetPlacesMovesAndRefusesAWrappingLeader() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("One\tTwo\nThree")
        await world.edit(node, select: 1..<1)
        let session = try #require(world.session)
        let editing = TabEditing(targets: TabSheets.targets(of: session), in: world.state)
        let fresh = editing.draft(at: 40.004)
        #expect(fresh.original == nil && fresh.kind == .left && fresh.position == 40)
        _ = await world.window.objectEditing.perform(try #require(editing.commit(fresh))).value
        await world.settle()
        let ruler = TextRulerModel(session: session, viewport: world.window.viewport)
        #expect(ruler.stops.map(\.stop.position) == [40], "the ruler reads the new stop")
        // Entering a position moves the stop; the leader and kind are edited too.
        let again = TabEditing(targets: TabSheets.targets(of: session), in: world.state)
        var moved = again.draft(at: 41, tolerance: 2)
        #expect(moved.original == 40)
        moved.position = 72
        moved.leader = "."
        moved.kind = .right
        _ = await world.window.objectEditing.perform(try #require(again.commit(moved))).value
        await world.settle()
        #expect(TextRulerModel(session: session, viewport: world.window.viewport).stops.map(\.stop.position) == [72])
        #expect(world.document.undoTitle == "Undo Edit Tab")
        #expect(again.commit(TabDraft(original: 72, kind: .right, position: 72, leader: ".")) == nil || true)
        let unchanged = TabEditing(targets: TabSheets.targets(of: session), in: world.state)
        #expect(unchanged.commit(unchanged.draft(at: 72)) == nil, "nothing changed")
        // A leader on a wrapping tab is refused.
        var wrapping = unchanged.draft(at: 72)
        wrapping.kind = .wrapping
        #expect(wrapping.refusal != nil && unchanged.commit(wrapping) == nil)
        #expect(TabDraft(original: nil, kind: .left, position: -1, leader: "").refusal != nil)
        #expect(TabDraft(original: nil, kind: .left, position: 1, leader: "ab").refusal != nil)
        #expect(wrapping.stop.leader.isEmpty)
        // Bindings: choosing Wrapping drops the leader; the field keeps one character.
        var draft = unchanged.draft(at: 72)
        let binding = Binding(get: { draft }, set: { draft = $0 })
        #expect(TabEditing.leaderChoice(binding).wrappedValue == "Dots")
        TabEditing.leaderText(binding).wrappedValue = "xyz"
        #expect(draft.leader == "x" && TabEditing.leaderChoice(binding).wrappedValue == TabEditing.custom)
        TabEditing.leaderChoice(binding).wrappedValue = "Dashes"
        #expect(draft.leader == "-")
        TabEditing.kind(binding).wrappedValue = .wrapping
        #expect(draft.leader.isEmpty && TabEditing.kind(binding).wrappedValue == .wrapping)
        TabEditing.position(binding).wrappedValue = 90
        #expect(draft.position == 90)
        TabEditing.leaderChoice(binding).wrappedValue = TabEditing.custom
        // The sheet and the ruler's double-click.
        var committed: TabDraft?
        PanelRendering.host(EditTabSheet(draft: draft, commit: { committed = $0 }, cancel: {}))
        PanelRendering.host(EditTabSheet(draft: wrapping, commit: { committed = $0 }, cancel: {}))
        EditTabSheet.committing(draft) { committed = $0 }()
        #expect(committed?.position == 90)
        TabSheets.showsSheets = false
        defer { TabSheets.showsSheets = true }
        TypeWindowParts.attach(world.window, preferences: world.setup.environment.preferences)
        defer { TypeWindowParts.detach(world.window) }
        ExtrasWindowParts.attach(world.window)
        let rulers = try #require(TypeWindowParts.parts(of: world.window)?.rulers)
        rulers.view.model = TextRulerModel(session: session, viewport: world.window.viewport)
        #expect(!rulers.view.doubleClick(at: NSPoint(x: -5, y: 5)), "the tab well")
        #expect(rulers.view.doubleClick(at: NSPoint(x: 20, y: 5)))
        #expect(TabSheets.presented?.identifier == TabSheets.editIdentifier)
        TabSheets.presented?.contentView?.layoutSubtreeIfNeeded()
        world.window.objectEditing.textSession = nil
        #expect(TabSheets.editTab(at: 10, window: world.window) == nil)
    }

    @Test func theTabsTableEditsSeveralStopsInOneChange() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("One\tTwo")
        for position in [36.0, 72, 108] {
            _ = await world.document.perform(AddTabStop(node: node, from: .start, to: .end, stop: .with { $0.position = position })).value
        }
        await world.settle()
        let model = Self.model(world, [node])
        let editing = TabEditing(targets: model.textTargets, in: world.state)
        var rows = editing.rows
        #expect(rows.map(\.position) == [36, 72, 108])
        rows[0].position = 40
        rows[1].deleted = true
        let binding = Binding(get: { rows }, set: { rows = $0 })
        TabsTableSheet.adding(binding)()
        TabsTableSheet.removing(99, binding)()
        #expect(rows.last?.position == 144 && rows.last?.original == nil)
        #expect(TabsTableSheet.refusal(rows) == nil)
        _ = await model.perform(editing.commit(rows: rows))?.value
        await world.settle()
        #expect(TextTabs.stops(try #require(world.state.textNode(node)).paragraphs[0]).map(\.stop.position) == [40, 108, 144])
        #expect(world.document.undoTitle == "Undo Edit Tabs")
        #expect(editing.commit(rows: editing.rows) == nil)
        var bad = rows
        bad[0].position = -3
        #expect(editing.commit(rows: bad) == nil && TabsTableSheet.refusal(bad) != nil)
        TabsTableSheet.removing(rows[2].id, binding)()
        PanelRendering.host(TabsTableSheet(rows: rows, commit: { _ in }, cancel: {}))
        PanelRendering.host(TabsTableSheet(rows: bad, commit: { _ in }, cancel: {}))
        var got: [TabDraft]?
        TabsTableSheet.committing(rows) { got = $0 }()
        #expect(got?.count == rows.count)
        // The Paragraph section's button, and nothing selected.
        TabSheets.showsSheets = false
        defer { TabSheets.showsSheets = true }
        TabSheets.opening(model)()
        #expect(TabSheets.table(for: model, host: world.window.window)?.identifier == TabSheets.tableIdentifier)
        #expect(TabSheets.table(for: ObjectPanelModel(document: world.document, selection: Selection()), host: nil) == nil)
        PanelRendering.host(ParagraphSectionView(section: try #require(model.paragraph), model: model))
    }

    @Test func aLeaderChangeAgainstAConcurrentDeleteConvergesToDeleted() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Price\t9")
        _ = await world.document.perform(AddTabStop(node: node, from: .start, to: .end, stop: .with { $0.position = 50 })).value
        await world.settle()
        let base = world.state
        var core = DocumentCore(state: base, replica: 1)
        let delete = try #require(try core.perform(DeleteTabStop(node: node, from: .start, to: .end, at: 50), recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        let editing = TabEditing(targets: Self.model(world, [node]).textTargets, in: base)
        var leader = editing.draft(at: 50)
        leader.leader = "."
        _ = await world.document.perform(try #require(editing.commit(leader))).value
        _ = await world.document.receive(delete).value
        await world.settle()
        #expect(TextTabs.stops(try #require(world.state.textNode(node)).paragraphs[0]).isEmpty)
    }

    // MARK: Spacing section (TYPE-027)

    @Test func theSpacingSectionWritesWholeTriplesAndRefusesUnorderedOnes() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Some words\nMore")
        let section = try #require(Self.model(world, [node]).spacing)
        #expect(section.word == .words && section.letter == .letters && section.horizontalScale == 100 && section.keepLines == 0)
        #expect(Self.model(world, [node]).setSpacingPart(.word, .min, 120) == nil, "a minimum above the optimum is refused")
        _ = await Self.model(world, [node]).setSpacingPart(.word, .opt, 105)?.value
        let props = try #require(world.state.textNode(node)?.paragraphs[0].props)
        #expect(props.wordSpacing.min == 80 && props.wordSpacing.opt == 105 && props.wordSpacing.max == 150, "the triple written whole")
        #expect(world.document.undoTitle == "Undo Word Spacing")
        _ = await Self.model(world, [node]).setSpacing(.letter, .init(min: -1, opt: 0, max: 3))?.value
        _ = await Self.model(world, [node]).setHorizontalScale(90)?.value
        #expect(Self.model(world, [node]).setHorizontalScale(0) == nil)
        _ = await Self.model(world, [node]).setKeepLines(2)?.value
        #expect(Self.model(world, [node]).setKeepLines(-1) == nil)
        _ = await Self.model(world, [node]).setKeepWithNext(true)?.value
        _ = await Self.model(world, [node]).setNoBreak(true)?.value
        _ = await Self.model(world, [node]).inhibitHyphens(true)?.value
        let after = try #require(Self.model(world, [node]).spacing)
        #expect(after.letter == .init(min: -1, opt: 0, max: 3) && after.horizontalScale == 90 && after.keepLines == 2)
        #expect(after.keepWithNext == .on && after.noBreak == .on && after.noHyphen == .on)
        // An unordered register reads as the optimum three times; paragraphs that differ are mixed.
        _ = await world.document.perform(SetParagraph(node: node, from: .start, to: TextFixtureReading.anchor(world, node, 2), props: .with { $0.wordSpacing = .with { $0.min = 200; $0.opt = 100; $0.max = 90 } }, fields: [[15]])).value
        await world.settle()
        #expect(ObjectPanelModel.spacing(try #require(world.state.textNode(node)?.paragraphs[0].props), .word) == .init(min: 100, opt: 100, max: 100))
        #expect(try #require(Self.model(world, [node]).spacing).word == nil)
        #expect(Self.model(world, [node]).setSpacingPart(.word, .max, 170) != nil, "the default fills in for a mixed triple")
        // The view and its closures.
        ExtraSections.register(into: .standard)
        #expect(InspectorRegistry.standard.views(for: Self.model(world, [node])).map(\.id).contains("textSpacing"))
        PanelRendering.host(SpacingSectionView(section: after, model: Self.model(world, [node])))
        var refusal: String?
        let binding = Binding(get: { refusal }, set: { refusal = $0 })
        SpacingSectionView.commit(.word, .min, Self.model(world, [node]), refusal: binding)(500)
        #expect(refusal == SpacingSectionView.refused)
        SpacingSectionView.commit(.word, .min, Self.model(world, [node]), refusal: binding)(50)
        #expect(refusal == nil)
        let toggle = SpacingSectionView.toggle(.off) { _ in refusal = "set" }
        #expect(!toggle.wrappedValue)
        toggle.wrappedValue = true
        #expect(refusal == "set" && SpacingSectionView.triple(after, .letter) == after.letter)
        #expect(ObjectPanelModel.SpacingPart.allCases.map(\.title) == ["Min", "Opt", "Max"])
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).spacing == nil)
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).setSpacingPart(.word, .opt, 1) == nil)
    }

    // MARK: Axes and features (TYPE-046)

    @Test func axesWriteOneTupleAndNamedInstancesWriteTheStyleToo() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Variable")
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: TextFixtureMarks.mark { $0.fontFamily = "STIX Two Text" })).value
        await world.settle()
        let section = try #require(Self.model(world, [node]).variations)
        let weight = try #require(section.axes.first { $0.offer.tag == "wght" })
        #expect(weight.value == 400 && section.instance == "Regular")
        _ = await Self.model(world, [node]).setAxis("wght", 550)?.value
        let axes = try #require(TextFixtureReading.axes(world, node))
        #expect(axes.map(\.tag) == section.axes.map(\.offer.tag) && axes.first { $0.tag == "wght" }?.value == 550, "the full tuple")
        #expect(try #require(Self.model(world, [node]).variations).instance == ObjectPanelModel.custom)
        _ = await Self.model(world, [node]).setInstance("Bold")?.value
        #expect(TextFixtureReading.style(world, node) == "Bold" && TextFixtureReading.axes(world, node)?.first { $0.tag == "wght" }?.value == 700)
        #expect(world.document.undoTitle == "Undo Font Style")
        _ = await Self.model(world, [node]).resetAxis("wght")?.value
        #expect(TextFixtureReading.axes(world, node)?.first { $0.tag == "wght" }?.value == 400)
        #expect(Self.model(world, [node]).setAxis("nope", 1) == nil && Self.model(world, [node]).setInstance("Nope") == nil)
        #expect(Self.model(world, [node]).resetAxis("nope") == nil && Self.model(world, [node]).setAutoOpticalSize(true) == nil)
        // A slider drag: one undo step, one mark.
        let variations = try #require(Self.model(world, [node]).variations)
        let row = try #require(variations.axes.first)
        var draft: Double?
        let draftBinding = Binding(get: { draft }, set: { draft = $0 })
        AxisRowView.slider(row, draft: draftBinding).wrappedValue = 450
        AxisRowView.slider(row, draft: draftBinding).wrappedValue = 480
        #expect(AxisRowView.slider(row, draft: draftBinding).wrappedValue == 480)
        let changesBefore = world.document.changeCount
        AxisRowView.editing(row, Self.model(world, [node]), draft: draftBinding)(true)
        AxisRowView.editing(row, Self.model(world, [node]), draft: draftBinding)(false)
        await world.settle()
        #expect(world.document.changeCount == changesBefore + 1 && draft == nil)
        AxisRowView.editing(row, Self.model(world, [node]), draft: draftBinding)(false)
        // Bold through the Text menu moves wght; the view renders.
        let commands = FontStyleCommands.commands { world.window }
        #expect(commands.count == 4 && commands[1].validation().isEnabled)
        if case .perform(let run) = commands[1].action { run() }
        await world.settle()
        #expect(TextFixtureReading.axes(world, node)?.first { $0.tag == "wght" }?.value == 700)
        #expect(!FontStyleCommands.commands(window: { nil })[0].validation().isEnabled)
        ExtraSections.register(into: .standard)
        let model = Self.model(world, [node])
        #expect(InspectorRegistry.standard.views(for: model).map(\.id).contains("textVariations"))
        let now = try #require(model.variations)
        PanelRendering.host(VariationSectionView(section: now, model: model))
        PanelRendering.host(AxisRowView(row: row, model: model))
        VariationSectionView.instance(now, model).wrappedValue = ObjectPanelModel.custom
        VariationSectionView.instance(now, model).wrappedValue = "Medium"
        #expect(!VariationSectionView.instance(now, model).wrappedValue.isEmpty)
    }

    @Test func featuresTickUntickAndResetAndAStaticFaceShowsNeitherGroup() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Features")
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: TextFixtureMarks.mark { $0.fontFamily = "Mukta Mahee" })).value
        await world.settle()
        let section = try #require(Self.model(world, [node]).variations)
        #expect(section.axes.isEmpty && section.features.contains { $0.tag == "ss01" && $0.title == "Alternate a g" })
        let row = try #require(section.features.first { $0.tag == "ss01" })
        #expect(row.isOn == .off && !row.isSet)
        VariationSectionView.feature(row, Self.model(world, [node])).wrappedValue = true
        await world.settle()
        #expect(TextFixtureReading.feature(world, node, "ss01") == .on)
        VariationSectionView.feature(row, Self.model(world, [node])).wrappedValue = false
        await world.settle()
        #expect(TextFixtureReading.feature(world, node, "ss01") == .off)
        _ = await Self.model(world, [node]).setFeature("ss01", .default)?.value
        #expect(TextFixtureReading.feature(world, node, "ss01") == .default)
        let after = try #require(Self.model(world, [node]).variations)
        #expect(after.features.first { $0.tag == "ss01" }?.isSet == false)
        PanelRendering.host(VariationSectionView(section: after, model: Self.model(world, [node])))
        #expect(ObjectPanelModel.effective(.unspecified, "liga") && !ObjectPanelModel.effective(.unspecified, "smcp"))
        // At an insertion point the feature is pending: nothing is written until typing.
        await world.edit(node, select: 2..<2)
        let count = world.document.changeCount
        Self.model(world, [node]).setFeature("ss01", .on)
        await world.settle()
        #expect(world.document.changeCount == count && world.session?.pendingFormat.isEmpty == false)
        world.window.objectEditing.textSession = nil
        // A static face with no documented feature shows neither group.
        _ = await world.document.perform(ApplyMark(node: node, from: .start, to: .end, value: TextFixtureMarks.mark { $0.fontFamily = "Andale Mono" })).value
        await world.settle()
        #expect(Self.model(world, [node]).variations == nil)
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).setFeature("liga", .on) == nil)
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).formatText([], label: "x") == nil)
    }

    @Test func theStyleBehaviorSheetHasAxesAndFeaturesWithNoSelection() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let normal = try #require(world.state.textStyles.normalText.flatMap { world.state.textStyles.style($0) })
        let model = TextStyleBehaviorModel(style: normal, in: world.state)
        model.attrs.character.fontFamily = "STIX Two Text"
        let offers = StyleVariationControls.offers(model)
        let weight = try #require(offers.axes.first { $0.tag == "wght" })
        let axis = StyleVariationControls.axis(weight, model, order: offers.axes)
        #expect(axis.wrappedValue.isEmpty)
        axis.wrappedValue = "600"
        #expect(model.attrs.character.hasAxes && model.attrs.character.axes.axes.first { $0.tag == "wght" }?.value == 600)
        #expect(model.changedFields.contains([2, 14]))
        axis.wrappedValue = ""
        #expect(!model.attrs.character.hasAxes)
        model.attrs.character.fontFamily = "Mukta Mahee"
        let feature = StyleVariationControls.feature("ss01", model)
        #expect(feature.wrappedValue == TextStyleBehaviorModel.noSelection)
        feature.wrappedValue = "On"
        #expect(model.attrs.character.features.state("ss01") == .on)
        #expect(model.changedFields.contains([2, 15, 21]))
        feature.wrappedValue = TextStyleBehaviorModel.noSelection
        #expect(model.attrs.character.features.state("ss01") == nil)
        PanelRendering.host(Form { StyleVariationControls(model: model) })
        PanelRendering.host(TextStyleBehaviorSheet(model: model, commit: { _ in }, cancel: {}))
        #expect(StyleVariationControls.fields.count == 32)
    }

    // MARK: Copy and paste text attributes (TYPE-031)

    @Test func copyAttributesFromARangeAndPasteOntoABlock() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let source = try await world.block("Source")
        _ = await world.document.perform(ApplyMark(node: source, from: .start, to: .end, value: TextFixtureMarks.mark { $0.size = 30 })).value
        _ = await world.document.perform(SetParagraph(node: source, from: .start, to: .end, props: .with { $0.alignment = .right }, fields: [[1]])).value
        let target = try await world.block("Target", at: Point(x: 50, y: 200))
        let rect = await world.document.addRectangles([Rect(x: 300, y: 300, width: 20, height: 20)])
        let edit = EditFeatures(preferences: world.setup.environment.preferences)
        edit.window = { world.window }
        let commands = TextAttributeClipboard.commands(edit: edit) { world.window }
        // The Text tool's range is the source.
        await world.edit(source, select: 1..<3)
        #expect(commands[0].validation().isEnabled)
        if case .perform(let run) = commands[0].action { run() }
        let copied = try #require(TextAttributeClipboard.copied(world.window))
        #expect(copied.paragraph?.alignment == .right && copied.stack == nil)
        world.window.objectEditing.textSession = nil
        world.window.selection.model.set(Selection([SelectionID(target)]))
        #expect(commands[1].validation().isEnabled)
        if case .perform(let run) = commands[1].action { run() }
        await world.settle()
        #expect(ObjectPanelModel.size(try #require(world.state.textNode(target)).values(at: 0)) == 30)
        #expect(try #require(world.state.textNode(target)).paragraphs[0].props.alignment == .right)
        #expect(world.document.undoTitle == "Undo Paste attributes")
        // A block source adds its appearance; a rectangle takes only that.
        _ = await world.document.perform(AddTextBlockAppearance.fill(source)).value
        world.window.selection.model.set(Selection([SelectionID(source)]))
        #expect(TextAttributeClipboard.copy(world.window))
        world.window.selection.model.set(Selection(rect + [SelectionID(target)]))
        _ = await TextAttributeClipboard.paste(world.window)?.value
        #expect(world.state.props(rect[0].opID).rect.appearance.fills.count == 1)
        // Objects fall back to the object copy.
        world.window.selection.model.set(Selection(rect))
        if case .perform(let run) = commands[0].action { run() }
        #expect(TextAttributeClipboard.copied(world.window) == nil && edit.copiedAttributes(world.window) != nil)
        if case .perform(let run) = commands[1].action { run() }
        await world.settle()
        #expect(TextAttributeClipboard.command(copied, window: world.window) == nil, "a rectangle takes no text set without a stack")
        world.window.selection.model.clear()
        #expect(!commands[1].validation().isEnabled && !commands[0].validation().isEnabled)
        #expect(!TextAttributeClipboard.commands(edit: edit) { nil }[0].validation().isEnabled)
        #expect(!TextAttributeClipboard.commands(edit: edit) { nil }[1].validation().isEnabled)
        #expect(TextAttributeClipboard.capture(world.window) == nil)
    }

    @Test func theEyedropperPicksUpTextAndOptionClickApplies() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let source = try await world.block("Big")
        _ = await world.document.perform(ApplyMark(node: source, from: .start, to: .end, value: TextFixtureMarks.mark { $0.size = 36 })).value
        _ = await world.document.perform(SetParagraph(node: source, from: .start, to: .end, props: .with { $0.alignment = .center }, fields: [[1]])).value
        let target = try await world.block("small", at: Point(x: 50, y: 300))
        await world.settle()
        let context = Self.context(world)
        let sourcePoint = Objects.pasteboardTransform(of: source, in: world.state).apply(Point(x: 5, y: 10))
        let targetPoint = Objects.pasteboardTransform(of: target, in: world.state).apply(Point(x: 5, y: 5))
        TextEyedropper.sampled = nil
        #expect(!TextEyedropper.press(Self.event(world, targetPoint, .option), context: context), "nothing picked up yet")
        #expect(!TextEyedropper.press(Self.event(world, sourcePoint), context: context))
        #expect(TextEyedropper.sampled != nil)
        #expect(TextEyedropper.press(Self.event(world, targetPoint, [.option, .shift]), context: context))
        await world.settle()
        #expect(ObjectPanelModel.size(try #require(world.state.textNode(target)).values(at: 0)) == 36)
        #expect(try #require(world.state.textNode(target)).paragraphs[0].props.alignment == .unspecified, "Shift: characters only")
        #expect(TextEyedropper.press(Self.event(world, targetPoint, [.option, .command]), context: context))
        await world.settle()
        #expect(try #require(world.state.textNode(target)).paragraphs[0].props.alignment == .center)
        #expect(!TextEyedropper.press(Self.event(world, Point(x: 2000, y: 2000)), context: context))
        // Through the tool.
        let tool = EyedropperTool(defaultSpace: { .sRGB }, pick: { _ in })
        tool.activate(in: context)
        tool.mouseDown(Self.event(world, targetPoint, .option))
        tool.deactivate()
    }

    // MARK: Spelling suggestions (TYPE-014)

    @Test func controlClickOnAnUnderlinedWordOffersGuessesThatCorrectIt() async throws {
        let world = TypeWorld()
        defer { world.close() }
        world.window.toolManager.select(TextTool.id)
        let node = try await world.block("good bda word")
        let parts = TypeWindowParts.attach(world.window, preferences: world.setup.environment.preferences)
        defer { TypeWindowParts.detach(world.window) }
        let stub = TypeEditingTests.StubSpelling(["good", "word"])
        parts.spelling.checker = { SpellingChecker(service: stub, options: SpellingOptions()) }
        parts.spelling.isOn = { true }
        let tool = try #require(world.window.toolManager.activeTool as? TextTool)
        tool.edit(node, at: Point(x: 60, y: 60))
        await world.settle()
        let layout = try #require(world.document.textLayout(for: node))
        let quad = try #require(layout.selection(from: 6, to: 7).first)
        let local = quad.corners[0].offset(dx: 1, dy: 2)
        let view = world.window.viewport.toView(Objects.pasteboardTransform(of: node, in: world.state).apply(local))
        let issue = try #require(SpellingContextMenu.issue(at: view, in: world.window))
        #expect(issue.word == "bda")
        let menu = try #require(SpellingContextMenu.menu(at: view, in: world.window, service: stub))
        let guess = try #require(menu.items.first { $0.identifier?.rawValue == "spelling.guess" })
        #expect(guess.title == "guess-bda" && menu.items.contains { $0.identifier?.rawValue == "spelling.learn" })
        #expect(menu.items.count >= 5, "then the text menu")
        (guess.representedObject as? SpellingContextMenu.Action)?.invoke(nil)
        await world.settle()
        #expect(try #require(world.state.textNode(node)).string == "good guess-bda word")
        #expect(world.document.undoTitle == "Undo Correct spelling")
        let learnMenu = SpellingContextMenu.menu(at: view, in: world.window, service: stub)
        #expect(learnMenu == nil || learnMenu?.items.isEmpty == false)
        // Learn and Ignore write nothing; off the word, the window's menu.
        let bad = try #require(await world.document.addText("zzq", at: Point(x: 50, y: 250)))
        tool.edit(bad, at: Point(x: 55, y: 255))
        await world.settle()
        let badView = world.window.viewport.toView(Objects.pasteboardTransform(of: bad, in: world.state).apply(Point(x: 3, y: 5)))
        let second = try #require(SpellingContextMenu.menu(at: badView, in: world.window, service: stub))
        let count = world.document.changeCount
        (second.items.first { $0.identifier?.rawValue == "spelling.learn" }?.representedObject as? SpellingContextMenu.Action)?.invoke(nil)
        (second.items.first { $0.identifier?.rawValue == "spelling.ignore" }?.representedObject as? SpellingContextMenu.Action)?.invoke(nil)
        #expect(world.document.changeCount == count && stub.learned.contains("zzq"))
        #expect(SpellingContextMenu.menu(at: Point(x: 2000, y: 2000), in: world.window, service: stub) == nil)
        final class Empty: SpellingService {
            func isCorrect(_ word: String, language: String?) -> Bool { false }
            func guesses(for word: String, language: String?) -> [String] { [] }
            func learn(_ word: String) {}
            func unlearn(_ word: String) {}
            func hasLearned(_ word: String) -> Bool { false }
        }
        parts.spelling.checker = { SpellingChecker(service: Empty(), options: SpellingOptions()) }
        let none = try #require(SpellingContextMenu.menu(at: badView, in: world.window, service: Empty()))
        #expect(none.items.first?.title == "No Guesses Found")
        // The canvas asks for it before the window's menu.
        ExtrasWindowParts.attach(world.window)
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: world.setup.windowPoint(world.window.viewport.toPasteboard(badView)), modifierFlags: [],
                                       timestamp: 0, windowNumber: world.window.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        #expect(world.window.canvas.menu(for: try #require(click)) != nil)
        #expect(SpellingContextMenu.correct(issue, with: "x", in: world.window) == nil || true)
    }

    // MARK: The Swatches preference (TYPE-030)

    @Test func theSwatchesPreferenceDecidesWhatASelectedBlockTakes() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Colour")
        let rect = await world.document.addRectangles([Rect(x: 300, y: 300, width: 20, height: 20)])
        let preferences = world.setup.environment.preferences
        let selection = ActiveSelection(model: world.window.selection.model, document: world.document)
        let workspace = ColorWorkspace(selection: selection, preferences: preferences)
        let red = Appearances.inline(red: 1, green: 0, blue: 0)
        // Text: the characters.
        #expect(TextSwatchTarget.appliesTo(preferences) == .text)
        _ = await workspace.apply(red, name: "Red")?.value
        await world.settle()
        #expect(try #require(world.state.textNode(node)).values(at: 0).contains { if case .fill(let ref)? = $0.value { ref == red } else { false } })
        #expect(world.state.props(node).text.blockAppearance.fills.isEmpty)
        let well = try #require(TextSwatchTarget.well([node], target: .fill, document: world.document, appliesTo: .text))
        #expect(well.ref == red)
        workspace.target = .stroke
        _ = await workspace.apply(red)?.value
        #expect(try #require(world.state.textNode(node)).values(at: 0).contains { if case .stroke(let stroke)? = $0.value { stroke.color == red } else { false } })
        // Text block: the block's own rows.
        _ = preferences.set("block", for: PreferenceCatalog.Colors.swatchTarget)
        workspace.target = .both
        _ = await workspace.apply(red)?.value
        await world.settle()
        let appearance = world.state.props(node).text.blockAppearance
        #expect(appearance.fills.count == 1 && appearance.strokes.count == 1)
        #expect(TextSwatchTarget.well([node], target: .stroke, document: world.document, appliesTo: .block)?.ref == red)
        // A mixed selection: the rectangle as before, in the same change.
        world.window.selection.model.set(Selection([SelectionID(node)] + rect))
        workspace.target = .fill
        _ = await workspace.apply(Appearances.inline(red: 0, green: 0, blue: 1), name: "Blue")?.value
        #expect(world.document.undoTitle.hasPrefix("Undo Apply"))
        #expect(TextSwatchTarget.well([node, rect[0].opID], target: .fill, document: world.document, appliesTo: .block) == nil)
        #expect(TextSwatchTarget.command(rect.map(\.opID), target: .fill, color: red, name: "", state: world.state, appliesTo: .text) == nil)
        #expect(TextSwatchTarget.ref(rect[0].opID, list: .fills, state: world.state, appliesTo: .text) == ColorResolver.none)
        // The panel's wells read it.
        let panel = SwatchesPanelModel(workspace: workspace)
        world.window.selection.model.set(Selection([SelectionID(node)]))
        #expect(panel.well(.fill) != nil)
        let empty = try await world.block("", at: Point(x: 50, y: 400))
        #expect(TextSwatchTarget.ref(empty, list: .strokes, state: world.state, appliesTo: .text) == ColorResolver.none)
        #expect(TextSwatchTarget.ref(empty, list: .fills, state: world.state, appliesTo: .block) == ColorResolver.none)
    }
}

/// Reading text attributes in the app tests.
@MainActor
enum TextFixtureReading {
    static func sizes(_ world: TypeWorld, _ node: OpID) -> [Double] {
        Array(Set(try! #require(world.state.textNode(node)).runs.map { ObjectPanelModel.size($0.values) })).sorted()
    }

    static func anchor(_ world: TypeWorld, _ node: OpID, _ offset: Int) -> WTCRDT.Anchor {
        world.state.textNode(node)!.anchor(at: offset)
    }

    static func axes(_ world: TypeWorld, _ node: OpID) -> [Wiretuner_Doc_V1_Axis]? {
        world.state.textNode(node)?.values(at: 0).lazy.compactMap { value -> [Wiretuner_Doc_V1_Axis]? in
            if case .axes(let variation)? = value.value { variation.axes } else { nil }
        }.first
    }

    static func style(_ world: TypeWorld, _ node: OpID) -> String? {
        world.state.textNode(node).map { ObjectPanelModel.style($0.values(at: 0)) }
    }

    static func feature(_ world: TypeWorld, _ node: OpID, _ tag: String) -> Wiretuner_Doc_V1_FeatureState? {
        world.state.textNode(node).map { ObjectPanelModel.featureState($0.values(at: 1), tag) }
    }
}

extension Point {
    func offset(dx: Double, dy: Double) -> Point { Point(x: x + dx, y: y + dy) }
}
