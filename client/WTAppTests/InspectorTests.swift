import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// APP-007: the Object panel framework -- the field editors' focus-preservation rule, the
/// section registry, the properties outline and the host.
@Suite @MainActor struct InspectorTests {
    /// A change from another replica, applied as the sync client would deliver it.
    static func receive(_ command: any WTModel.Command, into document: DocumentHandle) async throws {
        var other = DocumentCore(state: document.state, replica: 0xBEEF)
        let outcome = try other.perform(command, recording: DocumentCore.Recording(limit: 10, now: Date()))
        _ = await document.receive(try #require(outcome?.change)).value
    }

    // MARK: Field editors

    @Test func aFieldKeepsItsDraftWhileTheValueChangesUnderIt() {
        var written: [Double] = []
        let editor = FieldEditor(format: .number, value: 4)
        editor.connect { written.append($0) }
        #expect(editor.text == "4" && !editor.draftIsDirty && !editor.remoteChanged)
        editor.bind(selection: 5)
        #expect(editor.text == "5", "an untouched field follows the document")
        editor.bind(selection: 5)
        editor.edit("5")
        #expect(!editor.draftIsDirty, "the same text is no edit")
        editor.edit("12")
        editor.bind(selection: 7)
        #expect(editor.text == "12" && editor.draftIsDirty && editor.remoteChanged && editor.value == 7, "the keystrokes stay")
        #expect(editor.submit() && written == [12] && editor.text == "12" && !editor.remoteChanged && !editor.draftIsDirty)
        #expect(!editor.submit(), "nothing typed: nothing written")
        // Esc discards the draft and shows what the document holds now.
        editor.edit("99")
        editor.bind(selection: 8)
        editor.cancel()
        #expect(editor.text == "8" && !editor.draftIsDirty && !editor.remoteChanged && written == [12])
    }

    @Test func refusedInputBeepsAndFocusLossCommitsOrReverts() {
        var written: [Double] = []
        var beeps = 0
        let editor = FieldEditor(format: .number, value: 1)
        editor.connect { written.append($0) }
        editor.beep = { beeps += 1 }
        editor.edit("abc")
        #expect(!editor.submit() && beeps == 1 && editor.text == "abc" && editor.draftIsDirty)
        editor.focusChanged(false)
        #expect(editor.text == "1" && !editor.draftIsDirty && beeps == 2, "a draft that does not parse reverts on focus loss")
        editor.edit("3")
        editor.focusChanged(true)
        #expect(editor.draftIsDirty, "gaining focus commits nothing")
        editor.focusChanged(false)
        #expect(written == [3] && !editor.draftIsDirty)
        editor.focusChanged(false)
        #expect(written == [3])
    }

    @Test func aDraftCommitsToTheObjectsItWasTypedFor() {
        let unconnected = FieldEditor(format: .number, value: 1)
        #expect(unconnected.step(1) && unconnected.value == 2, "no writer: nothing written, the field still steps")
        var first: [Double] = [], second: [Double] = []
        let editor = FieldEditor(format: .number, value: 1)
        editor.connect { first.append($0) }
        editor.edit("2")
        editor.connect { second.append($0) }
        editor.submit()
        #expect(first == [2] && second.isEmpty)
        editor.edit("3")
        editor.submit()
        #expect(second == [3])
    }

    @Test func arrowsStepByOneOrTenUnits() {
        var written: [Double] = []
        let editor = FieldEditor(format: .measure(.picas), value: 24)
        editor.connect { written.append($0) }
        #expect(editor.text == "2p0" || editor.text == "2p")
        #expect(editor.step(1) && written == [36], "one pica")
        editor.bind(selection: 36)
        #expect(editor.step(-10) && written.last == -84)
        editor.edit("1p6")
        #expect(editor.step(1) && written.last == 30, "a draft steps from what was typed")
        let mixed = FieldEditor(format: .number, value: nil)
        #expect(!mixed.step(1) && mixed.text == "", "a mixed field has nothing to step from")
        let text = FieldEditor(format: .text(), value: "Name")
        #expect(!text.step(1))
        #expect(FieldEditor<Double>.steps(up: true, shift: false) == 1 && FieldEditor<Double>.steps(up: false, shift: true) == -10)
        #expect(FieldEditor<Double>.steps(up: nil, shift: true) == nil)
        #expect(FieldFormat<Double>.number.step?(nil, 1) == nil && FieldFormat<Double>.number.step?(2, -1) == 1)
    }

    @Test func aUnitChangeReformatsAnUntouchedField() {
        let editor = FieldEditor(format: .measure(.points), value: 72)
        editor.reformat(.measure(.inches))
        #expect(editor.text == "1")
        editor.edit("2")
        editor.reformat(.measure(.points))
        #expect(editor.text == "2", "a draft is not reformatted")
    }

    @Test func theFieldViewForwardsKeysToItsEditor() {
        var written: [Double] = []
        let editor = FieldEditor(format: .number, value: 5)
        editor.connect { written.append($0) }
        #expect(InspectorField<Double>.step(editor, key: .upArrow, shift: true) == .handled && written == [15])
        #expect(InspectorField<Double>.step(editor, key: .downArrow, shift: false) == .handled && written == [15, 14])
        #expect(InspectorField<Double>.step(editor, key: .leftArrow, shift: false) == .ignored)
        let binding = InspectorField<Double>.text(editor)
        binding.wrappedValue = "40"
        #expect(binding.wrappedValue == "40" && editor.draftIsDirty)
        editor.bind(selection: 6)
        #expect(InspectorField<Double>.accessibilityValue(editor) == "40, changed by someone else")
        #expect(InspectorField<Double>.highlight(editor) != .clear && !InspectorField<Double>.help(editor).isEmpty)
        InspectorField<Double>.cancelling(editor)()
        #expect(editor.text == "6" && InspectorField<Double>.accessibilityValue(editor) == "6")
        #expect(InspectorField<Double>.highlight(editor) == .clear && InspectorField<Double>.help(editor).isEmpty)
        // Return, focus, a new value and a new unit reach the editor.
        InspectorField<Double>.binding(editor)(6, 9)
        #expect(editor.text == "9")
        binding.wrappedValue = "10"
        InspectorField<Double>.submitting(editor)()
        #expect(written.last == 10)
        binding.wrappedValue = "11"
        InspectorField<Double>.focusing(editor)(true, false)
        #expect(written.last == 11)
        InspectorField<Double>.reformatting(editor, .measure(.inches))(0, 1)
        #expect(editor.text == Measure.format(11, unit: .inches, suffix: false))
        // The view renders with a value, mixed, and a changed unit.
        let host = NSHostingView(rootView: MeasureField(title: "X", value: 1, unit: .points, identifier: "x") { _ in })
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        host.layoutSubtreeIfNeeded()
        host.rootView = MeasureField(title: "X", value: nil, unit: .inches, identifier: "x") { _ in }
        host.layoutSubtreeIfNeeded()
        AttributeFixture.render(CommitTextField(title: "Name", value: "A", identifier: "n") { _ in })
        AttributeFixture.render(CommitField(title: "N", value: 2, identifier: "n") { _ in })
    }

    /// APP-007's *Done when*: editing a value while a remote change lands on the same object never
    /// loses keystrokes -- Return commits them as a later change that wins, Esc shows theirs.
    @Test func editingWhileARemoteChangeLandsNeverLosesKeystrokes() async throws {
        let fixture = await AttributeFixture.make()
        let document = fixture.document
        func common() -> ObjectPanelModel.CommonSection? {
            ObjectPanelModel(document: document, selection: Selection(fixture.ids)).common
        }
        let model = ObjectPanelModel(document: document, selection: Selection(fixture.ids))
        let editor = FieldEditor(format: .measure(model.unit), value: common()?.x)
        editor.connect { model.perform(model.setPosition(x: $0)) }
        editor.edit("4")
        editor.edit("42")
        try await Self.receive(MoveObjects([fixture.ids[0].opID], by: Vector(dx: 100, dy: 0)), into: document)
        #expect(common()?.x == 100, "the canvas shows their value")
        editor.bind(selection: common()?.x)
        #expect(editor.text == "42" && editor.remoteChanged)
        #expect(editor.submit())
        await document.settle()
        #expect(common()?.x == 42 && document.undoTitle == "Undo Move", "the later change wins")
        // Esc takes theirs.
        editor.edit("7")
        try await Self.receive(MoveObjects([fixture.ids[0].opID], by: Vector(dx: 0, dy: 5)), into: document)
        try await Self.receive(MoveObjects([fixture.ids[0].opID], by: Vector(dx: 8, dy: 0)), into: document)
        editor.bind(selection: common()?.x)
        editor.cancel()
        #expect(editor.text == "50" && common()?.x == 50)
    }

    @Test func theSectionViewsRenderAndCommitNameAndNote() async throws {
        let fixture = await AttributeFixture.make()
        let document = fixture.document
        let model = ObjectPanelModel(document: document, selection: Selection(fixture.ids))
        CommonSectionView.name(model)("Box")
        CommonSectionView.note(model)("A note")
        await document.settle()
        let common = try #require(ObjectPanelModel(document: document, selection: Selection(fixture.ids)).common)
        #expect(common.name == "Box" && common.note == "A note")
        AttributeFixture.render(CommonSectionView(section: common, model: model))
        let corners = ObjectPanelModel.RectangleSection(nodes: [fixture.ids[0].opID], radius: 1, uniform: .off, topLeft: 1, topRight: 2, bottomRight: nil, bottomLeft: 4)
        AttributeFixture.render(RectangleSectionView(section: corners, model: model))
        // A horizontal line has no height to scale: H leaves it, W scales it.
        let line = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 10, y: 0)]))
        let flat = ObjectPanelModel(document: document, selection: Selection([line]))
        _ = await flat.perform(flat.setSize(height: 5, proportional: false))?.value
        _ = await flat.perform(flat.setSize(width: 20, proportional: false))?.value
        await document.settle()
        #expect(ObjectPanelModel(document: document, selection: Selection([line])).common?.width == 20)
    }

    // MARK: Registry

    @Test func sectionsShowByKindAndOrder() async throws {
        let fixture = await AttributeFixture.make(2)
        let document = fixture.document
        let path = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 5, y: 5)]))
        let registry = InspectorRegistry.standard
        func ids(_ selection: [SelectionID]) -> [String] {
            registry.views(for: ObjectPanelModel(document: document, selection: Selection(selection))).map(\.id)
        }
        #expect(ids(fixture.ids) == ["rectangle", "common"])
        #expect(ids([path]) == ["path", "common"])
        #expect(ids([path, fixture.ids[0]]) == ["common"], "objects of different kinds show only the common attributes")
        #expect(ids([]).isEmpty)
        let star = try #require(await document.perform(CreatePolygon(PolygonShape(sides: 5, radius: 10), center: .zero)).value?.createdObjects.first)
        await document.settle()
        #expect(ids([SelectionID(star)]) == ["polygon", "common"])
        let contour = try #require(document.path(path)?.contours.first)
        let point = PointReference(node: path.node, contour: contour.id, point: contour.drawn[0].id)
        let pointSelection = Selection().applying([path], sub: [path: .points([point])], mode: .replace)
        #expect(registry.views(for: ObjectPanelModel(document: document, selection: pointSelection)).map(\.id) == ["point", "path", "common"])

        let own = InspectorRegistry()
        own.register(InspectorSection(id: "b", order: 5, kinds: nil) { _ in AnyView(Text("b")) })
        own.register(InspectorSection(id: "a", order: 5, kinds: [.rect]) { _ in nil })
        own.register(InspectorSection(id: "c", order: 1, kinds: nil) { _ in AnyView(Text("c")) })
        own.register(InspectorSection(id: "c", order: 9, kinds: nil) { _ in AnyView(Text("c2")) })
        #expect(own.sections.map(\.id) == ["a", "b", "c"], "ordered, a re-registered id replaced")
        #expect(own.views(for: ObjectPanelModel(document: document, selection: Selection(fixture.ids))).map(\.id) == ["b", "c"], "a section with nothing to show is left out")
        #expect(InspectorSection(id: "x", order: 0, kinds: [.rect]) { _ in nil }.applies(to: [.rect, .rect]))
        #expect(!InspectorSection(id: "x", order: 0, kinds: nil) { _ in nil }.applies(to: []))
        // A row kind without a registered editor names the row instead.
        let context = fixture.context(0)
        AttributeFixture.render(own.rowEditor(context, environment: InspectorRowEnvironment()))
        own.registerRowEditor(for: .fills) { _, _ in AnyView(Text("fill")) }
        AttributeFixture.render(own.rowEditor(context, environment: InspectorRowEnvironment()))
    }

    // MARK: Properties outline

    @Test func theTreeListsTheStackAndAGroupsContents() async throws {
        let fixture = await AttributeFixture.make(2)
        let document = fixture.document
        let list = fixture.list([fixture.ids[0]])
        let tree = PropertiesTree(list: list, members: PropertiesTree.members(list))
        #expect(tree.root.title == "Rectangle" && tree.children.map(\.title) == ["Basic, 1 pt", "Basic"] && tree.rowCount == 2 && tree.members.isEmpty)
        let group = try #require(await document.perform(GroupObjects(fixture.ids.map(\.opID))).value?.createdObjects.first)
        await document.settle()
        let groupList = fixture.list([SelectionID(group)])
        let members = PropertiesTree.members(groupList)
        #expect(Set(members) == Set(fixture.ids.map(\.opID)))
        let grouped = PropertiesTree(list: groupList, members: members)
        #expect(grouped.root.title == "Group" && grouped.children.last?.key == .contents && grouped.rowCount == grouped.children.count - 1)
        #expect(PropertiesTree.members(fixture.list()).isEmpty, "two objects: no Contents")
        // *Contents* subselects the members.
        let selection = SelectionModel(Selection([SelectionID(group)]))
        AttributesListView.openContents(members, selection: selection)
        #expect(Set(selection.ids) == Set(fixture.ids))
        AttributesListView.openContents([], selection: selection)
        #expect(Set(selection.ids) == Set(fixture.ids))
    }

    /// An outline whose clicked row a test sets.
    final class ClickedOutline: PropertiesOutlineView {
        var clicked = -1
        override var clickedRow: Int { clicked }
    }

    @MainActor
    final class Recorder {
        var selected: [AttributesListView.ListSelection] = []
        var visible: [(Int, Bool)] = []
        var moves: [(Int, Int, Bool)] = []
        var drops: [Int] = []
        var removed = 0
        var opened = 0
        var option = false

        var actions: PropertiesOutlineController.Actions {
            PropertiesOutlineController.Actions(
                select: { self.selected.append($0) }, setVisible: { self.visible.append(($0.index, $1)) },
                move: { self.moves.append(($0, $1, $2)) }, dropColor: { self.drops.append($1.index); return true },
                remove: { self.removed += 1 }, openContents: { self.opened += 1 }
            )
        }
    }

    @Test func theOutlineShowsRowsAndReportsSelectionAndVisibility() async throws {
        let fixture = await AttributeFixture.make()
        _ = await fixture.document.perform(AddAppearance.effect([fixture.ids[0].opID], Wiretuner_Doc_V1_Effect())).value
        let list = fixture.list()
        let recorder = Recorder()
        let controller = PropertiesOutlineController()
        #expect(controller.outlineView(NSOutlineView(), numberOfChildrenOfItem: nil) == 0, "no tree yet")
        #expect(controller.row(.root) == nil && !controller.outlineView(NSOutlineView(), isItemExpandable: controller.item(.root)))
        controller.actions = recorder.actions
        let (scroll, outline) = controller.makeOutline()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let tree = PropertiesTree(list: list, members: [OpID(counter: 1, replica: 1)])
        controller.update(tree, selected: .root, in: outline)
        #expect(outline.numberOfRows == 5 && outline.selectedRow == 0 && recorder.selected.isEmpty, "the controller's own selection is no edit")
        #expect(controller.outlineView(outline, numberOfChildrenOfItem: controller.item(.root)) == 4)
        #expect(controller.outlineView(outline, numberOfChildrenOfItem: controller.item(.contents)) == 0)
        #expect(controller.outlineView(outline, isItemExpandable: controller.item(.root)))
        #expect(!controller.outlineView(outline, isItemExpandable: controller.item(.contents)))
        #expect(controller.outlineView(outline, child: 0, ofItem: nil) as? PropertiesItem === controller.item(.root))
        // Cells: the root, hidden, mixed and visible rows.
        let effect = try #require(tree.children.first?.item)
        let root = try #require(controller.outlineView(outline, viewFor: nil, item: controller.item(.root)) as? PropertiesRowCell)
        #expect(root.title.stringValue == "Rectangle" && root.visible.isHidden)
        let effectCell = try #require(controller.outlineView(outline, viewFor: nil, item: controller.item(.row(effect.id))) as? PropertiesRowCell)
        #expect(effectCell.visible.state == .on && !effectCell.visible.isHidden && effectCell.alphaValue == 1)
        #expect((controller.outlineView(outline, viewFor: nil, item: controller.item(.contents)) as? PropertiesRowCell)?.title.stringValue == "Contents")
        #expect(controller.outlineView(outline, viewFor: nil, item: "other") == nil)
        let cell = PropertiesRowCell()
        for (hidden, state) in [(MixedState.on, NSControl.StateValue.off), (.mixed, .mixed)] {
            var item = effect
            item.hidden = hidden
            cell.configure(PropertiesTree.Row(key: .row(item.id), title: "x", icon: "square", item: item), target: nil, action: #selector(NSText.copy(_:)))
            #expect(cell.visible.state == state)
        }
        #expect(cell.alphaValue == 1)
        // Selecting rows: a stack row, then the root; Contents cannot be selected.
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(recorder.selected == [.row(tree.children[1].item!.id), .root])
        #expect(!controller.outlineView(outline, shouldSelectItem: controller.item(.contents)))
        #expect(controller.outlineView(outline, shouldSelectItem: controller.item(.root)))
        controller.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: nil))
        #expect(recorder.selected.count == 2)
        // The controller selects the row the state names; the same tree does not reload.
        controller.update(tree, selected: .row(effect.id), in: outline)
        #expect(outline.selectedRow == 1)
        controller.update(tree, selected: .row(AppearanceRow(.fills, OpID(counter: 99, replica: 9))), in: outline)
        #expect(outline.selectedRow == 1)
        // The visibility checkbox.
        effectCell.visible.state = .off
        controller.toggleVisibility(effectCell.visible)
        effectCell.visible.state = .mixed
        controller.toggleVisibility(effectCell.visible)
        controller.toggleVisibility(NSButton())
        #expect(recorder.visible.map(\.1) == [false, true])
        // Double-clicking Contents opens it; another row does nothing.
        let clicked = ClickedOutline()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("property"))
        clicked.addTableColumn(column)
        clicked.outlineTableColumn = column
        clicked.dataSource = controller
        clicked.delegate = controller
        clicked.reloadData()
        clicked.expandItem(controller.item(.root))
        clicked.clicked = clicked.row(forItem: controller.item(.contents))
        controller.doubleClicked(clicked)
        clicked.clicked = 0
        controller.doubleClicked(clicked)
        #expect(recorder.opened == 1)
        // Delete removes; other keys go to the outline.
        outline.onDelete = recorder.actions.remove
        for code: UInt16 in [51, 117, 0] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                      characters: code == 0 ? "a" : "\u{8}", charactersIgnoringModifiers: code == 0 ? "a" : "\u{8}",
                                                      isARepeat: false, keyCode: code))
            outline.keyDown(with: event)
        }
        #expect(recorder.removed == 2)
        // A removed row's item is dropped from the cache.
        let before = controller.item(.row(effect.id))
        controller.update(PropertiesTree(list: fixture.list([])), selected: .root, in: outline)
        #expect(controller.item(.row(effect.id)) !== before)
    }

    @Test func rowsDragToReorderAndTakeColours() async throws {
        let fixture = await AttributeFixture.make()
        _ = await fixture.document.perform(AddAppearance.effect([fixture.ids[0].opID], Wiretuner_Doc_V1_Effect())).value
        let list = fixture.list()
        let recorder = Recorder()
        let controller = PropertiesOutlineController()
        #expect(controller.outlineView(NSOutlineView(), validateDrop: PasteboardDragging(NSPasteboard(name: .init("x")), at: .zero),
                                       proposedItem: nil, proposedChildIndex: 0) == [])
        controller.actions = recorder.actions
        controller.optionHeld = { recorder.option }
        let (_, outline) = controller.makeOutline()
        let tree = PropertiesTree(list: list, members: [OpID(counter: 1, replica: 1)])
        controller.update(tree, selected: .root, in: outline)
        let effect = tree.children[0], fill = tree.children[2]
        // Dragging a stack row writes its display position; the root and Contents do not drag.
        let writer = try #require(controller.outlineView(outline, pasteboardWriterForItem: controller.item(fill.key)) as? NSPasteboardItem)
        #expect(writer.string(forType: PropertiesOutlineController.rowType) == "2")
        #expect(controller.outlineView(outline, pasteboardWriterForItem: controller.item(.root)) == nil)
        #expect(controller.outlineView(outline, pasteboardWriterForItem: controller.item(.contents)) == nil)
        let rows = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.rows.\(UUID().uuidString)"))
        rows.declareTypes([PropertiesOutlineController.rowType], owner: nil)
        rows.setString("2", forType: PropertiesOutlineController.rowType)
        let drag = PasteboardDragging(rows, at: .zero)
        #expect(controller.outlineView(outline, validateDrop: drag, proposedItem: controller.item(.root), proposedChildIndex: 0) == .move)
        recorder.option = true
        #expect(controller.outlineView(outline, validateDrop: drag, proposedItem: controller.item(.root), proposedChildIndex: 9) == .copy)
        #expect(controller.outlineView(outline, validateDrop: drag, proposedItem: controller.item(fill.key), proposedChildIndex: -1) == [])
        #expect(controller.outlineView(outline, acceptDrop: drag, item: controller.item(.root), childIndex: 9))
        recorder.option = false
        #expect(controller.outlineView(outline, acceptDrop: drag, item: controller.item(.root), childIndex: 0))
        #expect(!controller.outlineView(outline, acceptDrop: drag, item: controller.item(fill.key), childIndex: -1))
        #expect(recorder.moves.map { [$0.0, $0.1, $0.2 ? 1 : 0] } == [[2, 3, 1], [2, 0, 0]])
        // Colours drop on fill and stroke rows, not effects, the root or Contents.
        let colors = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.colors.\(UUID().uuidString)"))
        colors.declareTypes([.color], owner: nil)
        NSColor.red.write(to: colors)
        let colorDrag = PasteboardDragging(colors, at: .zero)
        #expect(controller.outlineView(outline, validateDrop: colorDrag, proposedItem: controller.item(fill.key), proposedChildIndex: NSOutlineViewDropOnItemIndex) == .copy)
        #expect(controller.outlineView(outline, validateDrop: colorDrag, proposedItem: controller.item(effect.key), proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        #expect(controller.outlineView(outline, validateDrop: colorDrag, proposedItem: controller.item(fill.key), proposedChildIndex: 0) == [])
        #expect(controller.outlineView(outline, validateDrop: colorDrag, proposedItem: nil, proposedChildIndex: 0) == [])
        let empty = PasteboardDragging(NSPasteboard(name: NSPasteboard.Name("WireTunerTests.empty.\(UUID().uuidString)")), at: .zero)
        #expect(controller.outlineView(outline, validateDrop: empty, proposedItem: controller.item(fill.key), proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        #expect(controller.outlineView(outline, acceptDrop: colorDrag, item: controller.item(fill.key), childIndex: -1))
        #expect(!controller.outlineView(outline, acceptDrop: colorDrag, item: controller.item(.contents), childIndex: -1))
        #expect(!controller.outlineView(outline, acceptDrop: colorDrag, item: nil, childIndex: -1))
        #expect(recorder.drops == [fill.item!.index])
        #expect(controller.colorTarget(.root) == nil)
    }

    @Test func theRepresentableFeedsTheController() async throws {
        let fixture = await AttributeFixture.make()
        let list = fixture.list()
        let recorder = Recorder()
        let controller = PropertiesOutlineController()
        let outline = PropertiesOutline(tree: PropertiesTree(list: list), selected: .root, actions: recorder.actions, optionHeld: { true })
        let scroll = PropertiesOutline.make(controller)
        outline.update(scroll, controller: controller)
        #expect(controller.tree == PropertiesTree(list: list) && controller.optionHeld())
        (scroll.documentView as? PropertiesOutlineView)?.onDelete?()
        #expect(recorder.removed == 1)
        outline.update(NSScrollView(), controller: controller)
        #expect(!PropertiesOutline(tree: PropertiesTree(list: list), selected: .root, actions: .init()).optionHeld() || NSEvent.modifierFlags.contains(.option))
        let defaults = PropertiesOutlineController.Actions()
        defaults.select(.root)
        defaults.setVisible(list.rows[0], true)
        defaults.move(0, 0, false)
        #expect(!defaults.dropColor(NSPasteboard.general, list.rows[0]))
        defaults.remove()
        defaults.openContents()
        #expect(!PropertiesOutlineController().optionHeld() || NSEvent.modifierFlags.contains(.option))
    }

    // MARK: Host

    @Test func theHostShowsTheSelectedRowsEditorOrTheSections() async throws {
        let fixture = await AttributeFixture.make()
        let active = ActiveSelection(model: SelectionModel(Selection(fixture.ids)), document: fixture.document)
        let state = AttributesState()
        let list = fixture.list()
        AttributeFixture.render(VStack { ObjectPanelBody.lowerHalf(active, list: list, state: state, registry: .standard) })
        for row in list.rows {
            state.select(row.id, targets: list.targets)
            AttributeFixture.render(VStack { ObjectPanelBody.lowerHalf(active, list: list, state: state, registry: .standard) })
        }
        _ = await list.perform(list.addEffect(.shadow, above: nil))?.value
        let effects = fixture.list()
        state.select(effects.displayRows.first?.id, targets: effects.targets)
        AttributeFixture.render(VStack { ObjectPanelBody.lowerHalf(active, list: effects, state: state, registry: .standard) })
        #expect(ObjectPanelBody.model(active) != nil && ObjectPanelBody.model(nil) == nil)
        #expect(ObjectPanelBody.environment(active).widthPresets == PreferenceCatalog.Object.defaultLineWeights.defaultValue)
        // With nothing selected: the defaults, no sections.
        let none = ActiveSelection(model: SelectionModel(), document: fixture.document)
        AttributeFixture.render(ObjectPanelBody(selection: none))
        AttributeFixture.render(VStack { ObjectPanelBody.lowerHalf(none, list: fixture.list([]), state: AttributesState(), registry: .standard) })
        // The list's actions are the model's commands.
        let actions = AttributesListView.actions(list, state, members: fixture.ids.map(\.opID), selection: active.model)
        actions.select(.row(list.rows[0].id))
        #expect(AttributesListView.selectedKey(list, state) == .row(list.rows[0].id))
        actions.select(.root)
        #expect(AttributesListView.selectedKey(list, state) == .root)
        actions.openContents()
        state.select(list.rows[0].id, targets: list.targets)
        actions.remove()
        await fixture.document.settle()
        #expect(fixture.document.undoTitle == "Undo Remove Fill")
    }
}
