import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A document with filled rectangles for the attribute tests.
@MainActor
final class AttributeFixture {
    let document = DocumentHandle.memory(title: "Attributes")
    var ids: [SelectionID] = []
    let pasteboard = SystemObjectPasteboard(NSPasteboard(name: NSPasteboard.Name("WireTunerTests.attributes.\(UUID().uuidString)")))

    static func make(_ count: Int = 1) async -> AttributeFixture {
        let fixture = AttributeFixture()
        fixture.ids = await fixture.document.addRectangles((0..<count).map { Rect(x: Double($0) * 20, y: 0, width: 10, height: 10) })
        return fixture
    }

    func list(_ ids: [SelectionID]? = nil) -> AttributesListModel {
        AttributesListModel(document: document, selection: Selection(ids ?? self.ids))
    }

    func stack(_ index: Int = 0) -> [AttributeEntry] {
        AppearanceEditing.entries(ids[index].opID, in: document.state)
    }

    /// The editor context of the row at stack `index`.
    func context(_ index: Int, ids: [SelectionID]? = nil, beep: @escaping @MainActor () -> Void = {}) -> AttributeEditorContext {
        let list = list(ids)
        let item = list.rows[index]
        return AttributeEditorContext(document: document, item: item, entries: list.stacks.map { $0[item.index] }, beep: beep)
    }

    /// A change from another replica, applied as the sync client would deliver it.
    func receive(_ command: any WTModel.Command) async throws {
        var other = DocumentCore(state: document.state, replica: 0xBEEF)
        let outcome = try other.perform(command, recording: DocumentCore.Recording(limit: 10, now: Date()))
        _ = await document.receive(try #require(outcome?.change)).value
    }

    /// Renders `view` once so its body runs.
    static func render<V: View>(_ view: V, width: Double = 420, height: Double = 900) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
    }
}

/// ATTR-003: the Attributes list in the Object panel.
@Suite @MainActor struct AttributesListTests {
    @Test func oneObjectListsItsStackTopFirst() async throws {
        let fixture = await AttributeFixture.make()
        let list = fixture.list()
        #expect(list.targets == [fixture.ids[0].opID] && !list.isDefaults && list.rootTitle == "Rectangle")
        #expect(list.rows.map(\.list) == [.fills, .strokes], "a new object has its fill with the stroke above")
        #expect(list.displayRows.map(\.summary) == ["Basic, 1 pt", "Basic"])
        #expect(list.rows.map(\.icon) == ["square.fill", "square"])
        #expect(list.item(list.rows[1].id) == list.rows[1] && list.item(nil) == nil)
        #expect(AttributesListModel.kindName(.path) == "Path" && AttributesListModel.kindName(.ellipse) == "Ellipse"
                && AttributesListModel.kindName(.polygon) == "Polygon" && AttributesListModel.kindName(.group) == "Group"
                && AttributesListModel.kindName(.layer) == "Layer")
        #expect([NodeKind.chart, .symbol, .instance, .barcode].map(AttributesListModel.kindName) == ["Chart", "Symbol", "Instance", "Barcode"])
        #expect(AttributeRowItem(index: 0, list: .effects, kind: nil, summary: "", hidden: .off, targets: list.rows[0].targets).icon == "sparkles")
    }

    @Test func addRemoveDuplicateHideAndSelect() async throws {
        let fixture = await AttributeFixture.make()
        let document = fixture.document
        let state = AttributesState()
        var list = fixture.list()
        let fill = list.rows[0]
        // Add Stroke above the selected fill: it lands between the fill and the stroke, selected.
        state.select(fill.id, targets: list.targets)
        await AttributesListView.add(list.add(.strokes, above: AttributesListView.selected(list, state)), model: list, state: state).value
        list = fixture.list()
        #expect(list.rows.map(\.list) == [.fills, .strokes, .strokes])
        #expect(AttributesListView.selected(list, state)?.index == 1 && document.undoTitle == "Undo Add Stroke")
        await AttributesListView.add(list.add(.fills, above: nil), model: list, state: state).value
        #expect(fixture.list().rows.last?.list == .fills, "nothing above: the top of the stack")
        await AttributesListView.add(list.addEffect(.blur, above: nil), model: list, state: state).value
        list = fixture.list()
        #expect(list.displayRows.first?.summary == "Blur" && AttributesListView.selected(list, state)?.list == .effects)
        #expect(await list.performAdding(nil) == nil)

        // Duplicate and remove the selected row; remove selects the root row.
        AttributesListView.duplicate(list, state)
        await document.settle()
        list = fixture.list()
        #expect(list.rows.filter { $0.list == .effects }.count == 2 && document.undoTitle == "Undo Duplicate Effect")
        AttributesListView.remove(list, state)
        await document.settle()
        list = fixture.list()
        #expect(list.rows.filter { $0.list == .effects }.count == 1 && AttributesListView.selected(list, state) == nil)
        AttributesListView.remove(list, state)
        AttributesListView.duplicate(list, state)
        #expect(document.undoTitle == "Undo Remove Effect", "nothing selected: nothing to remove")

        // The visibility checkbox.
        let binding = AttributesListView.visibility(list.rows[0], list)
        #expect(binding.wrappedValue)
        binding.wrappedValue = false
        await document.settle()
        #expect(fixture.list().rows[0].hidden == .on && document.undoTitle == "Undo Hide Fill")

        // The selection binding.
        let selection = AttributesListView.selection(list, state)
        #expect(selection.wrappedValue == .root)
        selection.wrappedValue = .row(list.rows[1].id)
        #expect(AttributesListView.selected(list, state)?.id == list.rows[1].id)
        #expect(selection.wrappedValue == .row(list.rows[1].id))
        selection.wrappedValue = .root
        #expect(state.selected == nil)
        #expect(state.selection(for: [WellKnown.settings]) == nil, "another selection resets the row")
    }

    @Test func draggingRowsReordersOrDuplicates() async throws {
        let fixture = await AttributeFixture.make()
        let document = fixture.document
        var list = fixture.list()
        let fill = list.rows[0].id, stroke = list.rows[1].id
        // Display order is top first: [stroke, fill].  Drag the fill (display 1) to the top.
        AttributesListView.move(IndexSet(integer: 1), to: 0, model: list, duplicate: false)
        await document.settle()
        list = fixture.list()
        #expect(list.rows.map(\.id) == [stroke, fill] && document.undoTitle == "Undo Reorder Attributes")
        // Drag it back below the stroke: the insertion point after the last row.
        AttributesListView.move(IndexSet(integer: 0), to: 2, model: list, duplicate: false)
        await document.settle()
        #expect(fixture.list().rows.map(\.id) == [fill, stroke])
        list = fixture.list()
        #expect(list.move(fromDisplay: 0, toDisplay: 0, duplicate: false) == nil, "dropped where it was")
        #expect(list.move(fromDisplay: 5, toDisplay: 0, duplicate: false) == nil)
        AttributesListView.move(IndexSet(), to: 0, model: list, duplicate: false)
        // Option-drag the stroke to the bottom: a copy there, the original stays.
        AttributesListView.move(IndexSet(integer: 0), to: 2, model: list, duplicate: true)
        await document.settle()
        list = fixture.list()
        #expect(list.rows.map(\.list) == [.strokes, .fills, .strokes] && list.rows[2].id == stroke && list.rows[0].id != stroke)
        #expect(document.undoTitle == "Undo Duplicate Stroke")
    }

    @Test func aDroppedColourRecolorsThatRowOnly() async throws {
        let fixture = await AttributeFixture.make()
        let list = fixture.list()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.drop.\(UUID().uuidString)"))
        #expect(!AttributesListView.drop(from: pasteboard, on: list.rows[0], model: list), "no colour on the pasteboard")
        pasteboard.clearContents()
        pasteboard.declareTypes([.color], owner: nil)
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).write(to: pasteboard)
        #expect(AttributesListView.drop(from: pasteboard, on: list.rows[0], model: list))
        await fixture.document.settle()
        let stack = fixture.stack()
        #expect(stack[0].fill.settings.basic.color == Appearances.inline(red: 1, green: 0, blue: 0))
        #expect(stack[1].stroke.settings.basic.color == Appearances.inline(red: 0, green: 0, blue: 0), "the stroke keeps its colour")
        var effect = list.rows[0]
        effect.list = .effects
        #expect(list.drop(ColorBridge.none, on: effect) == nil && !AttributesListView.drop(from: pasteboard, on: effect, model: list))
        #expect(AttributesListView.colorTypes == ColorDrag.dropTypes)
    }

    @Test func severalObjectsShareRowsOnlyWhenTheirStacksMatch() async throws {
        let fixture = await AttributeFixture.make(2)
        let document = fixture.document
        var list = fixture.list()
        #expect(list.rootTitle == "2 objects" && list.rows.count == 2 && list.rows[1].targets.count == 2)
        // Different widths: the row reads Mixed; one checkbox hides both.
        _ = await document.perform(SetStrokeWidth([(node: fixture.ids[0].opID, element: list.rows[1].targets[0].row.element)], width: 3)).value
        list = fixture.list()
        #expect(list.rows[1].summary == "Mixed" && list.rows[1].kind == .stroke(.basic))
        _ = await list.perform(list.setHidden(list.rows[0], true))?.value
        #expect(fixture.list().rows[0].hidden == .on && document.undoTitle == "Undo Hide Fill of 2 objects")
        _ = await document.perform(SetAppearanceHidden([fixture.list().rows[0].targets[0].pair], hidden: false)).value
        #expect(fixture.list().rows[0].hidden == .mixed)
        // Add Fill adds to each; when the stacks then differ only the root row remains.
        _ = await document.perform(AddAppearance.fill([fixture.ids[0].opID])).value
        list = fixture.list()
        #expect(list.rows.isEmpty)
        _ = await list.perform(list.add(.fills, above: nil))?.value
        #expect(fixture.stack(0).count == 4 && fixture.stack(1).count == 3)
        // A selection without stacks, and the root titles.
        #expect(AttributesListModel(document: document, selection: Selection([SelectionID(NodeID(counter: 999, replica: 9))])).targets.isEmpty)
        let none = AttributesListModel(document: document, selection: Selection([SelectionID(NodeID(counter: 999, replica: 9))]))
        #expect(none.rootTitle == "No attributes" && none.add(.fills, above: nil) == nil && none.addEffect(.blur, above: nil) == nil)
        #expect(none.perform(nil) == nil)
        let gone = AttributesListModel(document: document, selection: Selection([fixture.ids[0]]))
        #expect(gone.rootTitle == "Rectangle")
    }

    @Test func withNothingSelectedTheDefaultsAreListed() async throws {
        let fixture = await AttributeFixture.make()
        let state = AttributesState()
        var list = AttributesListModel(document: fixture.document, selection: .empty)
        #expect(list.isDefaults && list.rootTitle == "Default attributes" && list.rows.isEmpty)
        await AttributesListView.add(list.add(.fills, above: nil), model: list, state: state).value
        list = AttributesListModel(document: fixture.document, selection: .empty)
        #expect(list.rows.count == 1 && AttributesListView.selected(list, state)?.list == .fills)
        #expect(fixture.document.state.props(WellKnown.settings).settings.defaults.appearance.fills.count == 1)
    }

    @Test func aRemoteInsertKeepsTheSelectedRowAndItsEditor() async throws {
        let fixture = await AttributeFixture.make()
        let state = AttributesState()
        var list = fixture.list()
        let stroke = list.rows[1]
        state.select(stroke.id, targets: list.targets)
        try await fixture.receive(AddAppearance.fill([fixture.ids[0].opID], above: fill(list)))
        list = fixture.list()
        #expect(list.rows.count == 3)
        #expect(AttributesListView.selected(list, state)?.id == stroke.id, "the selection follows the element, not the index")
        #expect(AttributesListView.selected(list, state)?.index == 2)
    }

    private func fill(_ list: AttributesListModel) -> AppearanceRow { list.rows[0].id }

    @Test func thePanelShowsTheListAndTheSelectedEditor() async throws {
        let fixture = await AttributeFixture.make()
        let selectionModel = SelectionModel(Selection(fixture.ids))
        let active = ActiveSelection(model: selectionModel, document: fixture.document)
        #expect(ObjectPanelBody.attributes(active) != nil && ObjectPanelBody.attributes(nil) == nil)
        #expect(ObjectPanelBody.widthPresets(active) == PreferenceCatalog.Object.defaultLineWeights.defaultValue)
        let environment = TestEnvironment()
        active.preferences = environment.preferences
        _ = environment.preferences.set(["3", "6"], for: PreferenceCatalog.Object.defaultLineWeights)
        #expect(ObjectPanelBody.widthPresets(active) == ["3", "6"])
        let state = AttributesState()
        #expect(ObjectPanelBody.showsObjectSections(active, state) && ObjectPanelBody.showsObjectSections(nil, state))
        AttributeFixture.render(ObjectPanelBody(selection: active))
        let list = fixture.list()
        for row in list.rows {
            state.select(row.id, targets: list.targets)
            #expect(!ObjectPanelBody.showsObjectSections(active, state))
            AttributeFixture.render(AttributesListView(model: list, state: state, pasteboard: fixture.pasteboard))
        }
        _ = await list.perform(list.addEffect(.shadow, above: nil))?.value
        let effects = fixture.list()
        state.select(effects.rows.last?.id, targets: effects.targets)
        AttributeFixture.render(AttributesListView(model: effects, state: state))
        AttributeFixture.render(AttributeRowView(item: effects.rows[0], visible: .constant(true)))
        // Differing stacks show the note.
        let two = await AttributeFixture.make(2)
        _ = await two.document.perform(AddAppearance.fill([two.ids[0].opID])).value
        AttributeFixture.render(AttributesListView(model: two.list(), state: AttributesState()))
    }

    @Test func theControlsActionsAreTheModelsCommands() async throws {
        let fixture = await AttributeFixture.make()
        let document = fixture.document
        let state = AttributesState()
        var list = fixture.list()
        AttributesListView.adding(list.add(.strokes, above: nil), model: list, state: state)()
        while fixture.list().rows.count < 3 { await Task.yield() }
        await document.settle()
        list = fixture.list()
        #expect(AttributesListView.selected(list, state)?.index == 2)
        AttributesListView.duplicating(list, state)()
        await document.settle()
        list = fixture.list()
        AttributesListView.removing(list, state)()
        await document.settle()
        #expect(fixture.list().rows.count == 3 && state.selected == nil)
        list = fixture.list()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.drop.\(UUID().uuidString)"))
        pasteboard.declareTypes([.color], owner: nil)
        NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).write(to: pasteboard)
        #expect(AttributesListView.dropping(on: list.rows[0], model: list, pasteboard: pasteboard)([]))
        _ = AttributesListView.dropping(on: list.rows[0], model: list)
        AttributesListView.moving(list, optionHeld: { false })(IndexSet(integer: 0), 3)
        await document.settle()
        #expect(document.undoTitle == "Undo Reorder Attributes")
        let view = AttributesListView(model: list, state: state)
        #expect(!view.optionHeld())
        // Hidden and mixed rows render dimmed with their checkbox value.
        var hidden = list.rows[0]
        hidden.hidden = .on
        AttributeFixture.render(AttributeRowView(item: hidden, visible: .constant(false)))
        hidden.hidden = .mixed
        AttributeFixture.render(AttributeRowView(item: hidden, visible: .constant(false)))
    }
}
