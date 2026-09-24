import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-003: btn:[Add Effect], the *Effect* pop-up, remove, drag reorder and drop onto a fill in the
/// appearance list, and the vector effect forms with every option of live-effects.adoc -- driven
/// through the Object panel's models and views, as the UI tests of *Done when*.
@Suite @MainActor struct EffectEditorTests {
    /// Adds an effect of `kind` through the list (above `above`, or attached to it when it is a
    /// fill or stroke) and returns the list afterwards.
    @discardableResult
    static func add(_ kind: Wiretuner_Doc_V1_EffectKind, _ fixture: AttributeFixture, above: AttributeRowItem? = nil) async -> AttributesListModel {
        let list = fixture.list()
        _ = await list.perform(list.addEffect(kind, above: above))?.value
        return fixture.list()
    }

    /// The editor of the top effect row.
    static func model(_ fixture: AttributeFixture, selection: Selection? = nil) -> EffectEditorModel {
        let list = fixture.list()
        let index = list.rows.lastIndex { $0.list == .effects }!
        return EffectEditorModel(context: fixture.context(index), selection: selection)
    }

    static func perform(_ command: (any WTModel.Command)?, _ fixture: AttributeFixture) async {
        _ = await fixture.document.perform(command!).value
    }

    /// Commits each edit in turn, as fields commit one after another (a centre is one ATOMIC
    /// value, so each coordinate is written with the other as it stands then).
    static func apply(_ fixture: AttributeFixture, _ edits: [(EffectEditorModel) -> any WTModel.Command]) async {
        for edit in edits { await perform(edit(model(fixture)), fixture) }
    }

    static func settings(_ fixture: AttributeFixture) -> Wiretuner_Doc_V1_EffectSettings {
        fixture.stack().last { $0.row.list == .effects }!.effect.settings
    }

    @Test func addEffectAddsEachKindAtTheObjectLevelOrOnTheSelectedFill() async throws {
        let fixture = await AttributeFixture.make()
        for (kind, name) in EffectEditorModel.kinds {
            let list = await Self.add(kind, fixture)
            #expect(Self.settings(fixture).kind == kind && fixture.document.undoTitle == "Undo Add \(name) effect")
            #expect(list.rows.last?.list == .effects, "nothing selected: the top of the stack")
        }
        #expect(AttributesListView.effectGroups.flatMap { $0 }.count == EffectEditorModel.kinds.count)
        // With the fill selected the effect is attached to it, indented under it in the list.
        let fill = try #require(fixture.list().rows.first { $0.list == .fills })
        let attached = await Self.add(.ragged, fixture, above: fill)
        let entries = EffectReading.entries(fixture.ids[0].opID, in: fixture.document.state)
        #expect(entries.last { $0.attachment != .object }?.attachment == .element(fill.id))
        let tree = PropertiesTree(list: attached)
        #expect(tree.children.contains { $0.title == "↳ Ragged" } && tree.children.contains { $0.title == "Bend" })
        // Above a selected effect: at the object level, directly above it.
        let bend = try #require(attached.rows.first { row in row.list == .effects && entries.first { $0.row == row.id }?.effect.settings.kind == .bend })
        let above = await Self.add(.sketch, fixture, above: bend)
        let index = try #require(above.rows.firstIndex { $0.id == bend.id })
        #expect(EffectReading.entries(fixture.ids[0].opID, in: fixture.document.state).first { $0.row == above.rows[index + 1].id }?.effect.settings.kind == .sketch)
        #expect(fixture.list([]).addEffect(.bend, above: nil) != nil, "nothing selected: the default attributes")
        #expect(PropertiesTree.title(fill, effects: entries) == fill.summary)
    }

    @Test func theEffectPopUpChangesTheKindAndKeepsTheOldSettings() async throws {
        let fixture = await AttributeFixture.make()
        await Self.add(.bend, fixture)
        var model = Self.model(fixture)
        #expect(model.kind == .bend && !model.isUnsupported && model.notice == nil)
        await Self.perform(model.setBendSize(33), fixture)
        await Self.perform(Self.model(fixture).setKind(.ragged), fixture)
        #expect(Self.settings(fixture).kind == .ragged && fixture.document.undoTitle == "Undo Change effect to Ragged")
        await Self.perform(Self.model(fixture).setKind(.bend), fixture)
        model = Self.model(fixture)
        #expect(model.bendSize == 33, "switching back finds the settings")
        // Combine on a rectangle: the notice.
        await Self.perform(model.setKind(.combine), fixture)
        #expect(Self.model(fixture).notice == EffectNames.combineNotice)
        // An unknown kind (a newer client's) is shown as unsupported.
        let pairs = Self.model(fixture).pairs
        await Self.perform(EditEffect(pairs, label: "Future", fields: [EffectFields.kind]) { $0.kind = Wiretuner_Doc_V1_EffectKind(rawValue: 99)! }, fixture)
        model = Self.model(fixture)
        #expect(model.isUnsupported && model.kind == nil)
        AttributeFixture.render(EffectEditorView(model: model))
        #expect(PropertiesTree(list: fixture.list()).children.first?.title == EffectNames.unsupported)
    }

    @Test func everyBendDuetAndExpandOptionRoundTrips() async throws {
        let fixture = await AttributeFixture.make()
        await Self.add(.bend, fixture)
        await Self.apply(fixture, [{ $0.setBendSize(-12) }, { $0.setBendCenterX(5) }, { $0.setBendCenterY(-7) }])
        var settings = Self.settings(fixture)
        #expect(settings.bend.size == -12 && settings.bend.center.x == 5 && settings.bend.center.y == -7)
        AttributeFixture.render(EffectEditorView(model: Self.model(fixture)))

        await Self.perform(Self.model(fixture).setKind(.duet), fixture)
        var model = Self.model(fixture)
        #expect(model.duetMode == .reflect && model.duetCopies == 2)
        await Self.apply(fixture, [{ $0.setDuetMode(.rotate) }, { $0.setDuetCenterX(3) }, { $0.setDuetCenterY(4) }, { $0.setDuetAxis(45) },
                                   { $0.setDuetCopies(250) }, { $0.setDuetJoined(true) }, { $0.setDuetClosed(true) }, { $0.setDuetEvenOdd(true) }])
        settings = Self.settings(fixture)
        #expect(settings.duet.mode == .rotate && settings.duet.center.x == 3 && settings.duet.center.y == 4 && settings.duet.axisAngle == 45)
        #expect(settings.duet.copies == 100 && settings.duet.joined && settings.duet.closed && settings.duet.evenOdd)
        model = Self.model(fixture)
        #expect(model.duetMode == .rotate && model.duetCenterX == 3 && model.duetCenterY == 4 && model.duetAxis == 45 && model.duetCopies == 100)
        #expect(model.duetJoined == true && model.duetClosed == true && model.duetEvenOdd == true)
        AttributeFixture.render(EffectEditorView(model: model))

        await Self.perform(model.setKind(.expandPath), fixture)
        model = Self.model(fixture)
        #expect(model.expandDirection == .both && model.expandWidth == 4 && model.expandCap == .butt && model.expandJoin == .miter && model.expandMiter == 4)
        for command in [model.setExpandDirection(.inside), model.setExpandWidth(80), model.setExpandCap(.round), model.setExpandJoin(.bevel), model.setExpandMiter(0)] {
            await Self.perform(command, fixture)
        }
        settings = Self.settings(fixture)
        #expect(settings.expandPath.direction == .inside && settings.expandPath.width == 50 && settings.expandPath.cap == .round)
        #expect(settings.expandPath.join == .bevel && settings.expandPath.miterLimit == 1)
        #expect(!Self.model(fixture).expandWidthOutOfRange)
        // A width written out of range by hand is shown in red.
        let pairs = Self.model(fixture).pairs
        await Self.perform(EditEffect(pairs, label: "Width", fields: [EffectField.expand(2)]) { $0.expandPath.width = 80 }, fixture)
        #expect(Self.model(fixture).expandWidthOutOfRange)
        AttributeFixture.render(EffectEditorView(model: Self.model(fixture)))
        // Unset registers read their defaults.
        await Self.perform(EditEffect(pairs, label: "Clear", fields: [EffectField.expand(1), EffectField.expand(3), EffectField.expand(4), EffectField.expand(5)]) { _ in },
                           fixture)
        model = Self.model(fixture)
        #expect(model.expandDirection == .both && model.expandCap == .butt && model.expandJoin == .miter && model.expandMiter == 4)
    }

    @Test func everyRaggedSketchAndTransformOptionRoundTrips() async throws {
        let fixture = await AttributeFixture.make()
        await Self.add(.ragged, fixture)
        var model = Self.model(fixture)
        let seed = Self.settings(fixture).ragged.seed
        for command in [model.setRaggedSize(-3), model.setRaggedFrequency(20), model.setRaggedCopies(14), model.setRaggedSmooth(true), model.setRaggedUniform(true)] {
            await Self.perform(command, fixture)
        }
        var settings = Self.settings(fixture)
        #expect(settings.ragged.size == 0 && settings.ragged.frequency == 20 && settings.ragged.copies == 10 && settings.ragged.smooth && settings.ragged.uniform)
        model = Self.model(fixture)
        #expect(model.raggedSize == 0 && model.raggedFrequency == 20 && model.raggedCopies == 10 && model.raggedSmooth == true && model.raggedUniform == true)
        EffectEditorView.reseeding(model)()
        await fixture.document.settle()
        #expect(Self.settings(fixture).ragged.seed != seed && fixture.document.undoTitle == "Undo Reseed")
        AttributeFixture.render(EffectEditorView(model: Self.model(fixture)))

        await Self.perform(model.setKind(.sketch), fixture)
        model = Self.model(fixture)
        for command in [model.setSketchAmount(6), model.setSketchCopies(0), model.setSketchClosed(true)] {
            await Self.perform(command, fixture)
        }
        settings = Self.settings(fixture)
        #expect(settings.sketch.amount == 6 && settings.sketch.copies == 1 && settings.sketch.closed)
        model = Self.model(fixture)
        #expect(model.sketchAmount == 6 && model.sketchCopies == 1 && model.sketchClosed == true)
        AttributeFixture.render(EffectEditorView(model: model))

        await Self.perform(model.setKind(.transform), fixture)
        model = Self.model(fixture)
        #expect(model.uniform == true && model.scaleX == 100 && model.transformCopies == 1)
        // Uniform locks Y to X, both ways.
        await Self.perform(model.setScaleX(50), fixture)
        #expect(Self.settings(fixture).transform.scaleY == 50)
        await Self.perform(Self.model(fixture).setScaleY(70), fixture)
        #expect(Self.settings(fixture).transform.scaleX == 70)
        await Self.perform(Self.model(fixture).setUniform(false), fixture)
        model = Self.model(fixture)
        await Self.apply(fixture, [{ $0.setScaleX(120) }, { $0.setScaleY(80) }, { $0.setSkewH(10) }, { $0.setSkewV(-5) }, { $0.setRotate(30) },
                                   { $0.setMoveX(4) }, { $0.setMoveY(-2) }, { $0.setTransformCenterX(6) }, { $0.setTransformCenterY(8) },
                                   { $0.setTransformCopies(5000) }])
        settings = Self.settings(fixture)
        #expect(settings.transform.scaleX == 120 && settings.transform.scaleY == 80 && settings.transform.skewH == 10 && settings.transform.skewV == -5)
        #expect(settings.transform.rotate == 30 && settings.transform.move.x == 4 && settings.transform.center.y == 8 && settings.transform.copies == 1000)
        model = Self.model(fixture)
        #expect(model.moveX == 4 && model.moveY == -2 && model.transformCenterX == 6 && model.transformCenterY == 8 && model.transformCopies == 1000)
        #expect(model.skewH == 10 && model.skewV == -5 && model.rotate == 30)
        await Self.perform(model.setUniform(true), fixture)
        #expect(Self.settings(fixture).transform.scaleY == 120, "Uniform on writes Y equal to X")
        AttributeFixture.render(EffectEditorView(model: Self.model(fixture)))
    }

    @Test func cornersTreatAllOrTheSelectedPointsAndCombineChoosesItsOperation() async throws {
        let fixture = AttributeFixture()
        let path = try #require(await fixture.document.addPath([Point(x: 0, y: 0), Point(x: 40, y: 0), Point(x: 40, y: 40), Point(x: 0, y: 40)], closed: true, filled: true))
        fixture.ids = [path]
        await Self.add(.corners, fixture)
        var model = Self.model(fixture)
        #expect(model.cornerRadius == 6 && model.cornerStyle == .round && model.cornersAll == true)
        await Self.perform(model.setCornerRadius(-4), fixture)
        await Self.perform(Self.model(fixture).setCornerStyle(.chamfer), fixture)
        #expect(Self.settings(fixture).corners.radius == 0 && Self.settings(fixture).corners.style == .chamfer)
        // Nothing selected: no point to add.
        #expect(model.setCornersAll(false) == nil && model.treatAllCorners() == nil)
        // Selected points join the set; All clears it.
        let contour = try #require(fixture.document.path(path)?.contours.first)
        let points = contour.points.prefix(2).map { PointReference(node: path.node, contour: contour.id, point: $0.id) }
        var selection = Selection([path])
        selection.setSubSelection(.points(Set(points)), for: path)
        model = Self.model(fixture, selection: selection)
        #expect(model.selectedPoints(of: path.opID).count == 2)
        EffectEditorView.cornersAll(model).wrappedValue = false
        await fixture.document.settle()
        model = Self.model(fixture, selection: selection)
        #expect(model.cornersAll == false && model.cornerPoints.first?.count == 2 && fixture.document.undoTitle == "Undo Change corners")
        EffectEditorView.changingCorners(model, adding: false)()
        await fixture.document.settle()
        #expect(Self.model(fixture).cornersAll == true)
        await Self.perform(model.changeCornerPoints(adding: true), fixture)
        await Self.perform(Self.model(fixture).treatAllCorners(), fixture)
        #expect(Self.model(fixture).cornersAll == true && Self.model(fixture).cornerStyle == .chamfer)
        AttributeFixture.render(EffectEditorView(model: Self.model(fixture, selection: selection)))
        await Self.perform(Self.model(fixture).setKind(.combine), fixture)
        await Self.perform(Self.model(fixture).setOperation(.exclude), fixture)
        #expect(Self.model(fixture).operation == .exclude)
        AttributeFixture.render(EffectEditorView(model: Self.model(fixture)))
        for (kind, _) in EffectMenu.raster + EffectMenu.transparency {
            await Self.perform(Self.model(fixture).setKind(kind), fixture)
            AttributeFixture.render(EffectEditorView(model: Self.model(fixture)))
        }
        #expect(EffectEditorModel.replacing(EffectEditorModel.point(1, 2), x: nil, y: 5) == EffectEditorModel.point(1, 5))
    }

    @Test func effectsReorderByDragAttachByDropAndRemoveWithDelete() async throws {
        let fixture = await AttributeFixture.make()
        await Self.add(.bend, fixture)
        await Self.add(.ragged, fixture)
        var list = fixture.list()
        // Display order: Ragged, Bend, stroke, fill.  Drag Ragged below Bend.
        #expect(list.displayRows.map(\.summary).prefix(2) == ["Ragged", "Bend"])
        AttributesListView.move(IndexSet(integer: 0), to: 2, model: list, duplicate: false)
        await fixture.document.settle()
        list = fixture.list()
        #expect(PropertiesTree(list: list).children.prefix(2).map(\.title) == ["Bend", "Ragged"] && fixture.document.undoTitle == "Undo Reorder effects")
        // Dropped onto the fill: attached to it.
        let fill = try #require(list.rows.first { $0.list == .fills })
        let recorder = AttachRecorder()
        let controller = PropertiesOutlineController()
        controller.actions = AttributesListView.actions(list, AttributesState(focus: InspectorFocus()), members: [], selection: nil)
        let (_, outline) = controller.makeOutline()
        let tree = PropertiesTree(list: list)
        controller.update(tree, selected: .root, in: outline)
        let rows = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.effects.\(UUID().uuidString)"))
        rows.declareTypes([PropertiesOutlineController.rowType], owner: nil)
        rows.setString("0", forType: PropertiesOutlineController.rowType)
        let drag = PasteboardDragging(rows, at: .zero)
        let fillKey = PropertiesKey.row(fill.id)
        #expect(controller.outlineView(outline, validateDrop: drag, proposedItem: controller.item(fillKey), proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        #expect(controller.outlineView(outline, acceptDrop: drag, item: controller.item(fillKey), childIndex: NSOutlineViewDropOnItemIndex))
        await fixture.document.settle()
        var entries = EffectReading.entries(fixture.ids[0].opID, in: fixture.document.state)
        #expect(entries.first { $0.effect.settings.kind == .bend }?.attachment == .element(fill.id))
        // A drag within the attached group keeps it there; back on the root row detaches it.
        list = fixture.list()
        #expect(PropertiesTree(list: list).children.contains { $0.title == "↳ Bend" })
        let bendDisplay = try #require(list.displayRows.firstIndex { row in row.list == .effects && entries.first { $0.row == row.id }?.effect.settings.kind == .bend })
        #expect(list.move(fromDisplay: bendDisplay, toDisplay: list.rows.count, duplicate: false) != nil)
        recorder.list = list
        controller.actions = recorder.actions
        let bendRows = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.effects.\(UUID().uuidString)"))
        bendRows.declareTypes([PropertiesOutlineController.rowType], owner: nil)
        bendRows.setString(String(bendDisplay), forType: PropertiesOutlineController.rowType)
        controller.update(PropertiesTree(list: list), selected: .root, in: outline)
        #expect(controller.outlineView(outline, acceptDrop: PasteboardDragging(bendRows, at: .zero), item: controller.item(.root), childIndex: NSOutlineViewDropOnItemIndex))
        #expect(recorder.attached.count == 1 && recorder.attached[0].1 == nil)
        await fixture.document.settle()
        entries = EffectReading.entries(fixture.ids[0].opID, in: fixture.document.state)
        #expect(entries.allSatisfy { $0.attachment == .object })
        // A fill row does not attach, and an effect is no drop target.
        list = fixture.list()
        #expect(list.attach(fromDisplay: list.displayRows.firstIndex { $0.list == .fills }!, onto: nil) == nil)
        #expect(list.attach(fromDisplay: 99, onto: nil) == nil)
        let effectRow = try #require(list.rows.first { $0.list == .effects })
        #expect(list.attach(fromDisplay: 0, onto: effectRow) == nil)
        controller.update(PropertiesTree(list: list), selected: .root, in: outline)
        #expect(!controller.attachTarget(from: 0, onto: .row(effectRow.id)) && !controller.attachTarget(from: 99, onto: .root))
        #expect(list.reorderEffect(effectRow, toStack: 0) != nil)
        // kbd:[Delete] in the list removes the selected effect.
        let state = AttributesState(focus: InspectorFocus())
        state.select(effectRow.id, targets: list.targets)
        let view = PropertiesOutline(tree: PropertiesTree(list: list), selected: .row(effectRow.id), actions: AttributesListView.actions(list, state, members: [], selection: nil))
        let scroll = PropertiesOutline.make(controller)
        view.update(scroll, controller: controller)
        let deleting = try #require(scroll.documentView as? PropertiesOutlineView)
        deleting.keyDown(with: TestEvents.key("\u{7F}", keyCode: 51))
        await fixture.document.settle()
        #expect(fixture.list().rows.filter { $0.list == .effects }.count == 1 && fixture.document.undoTitle == "Undo Remove effect")
    }

    @MainActor
    final class AttachRecorder {
        var list: AttributesListModel?
        var attached: [(Int, AttributeRowItem?)] = []

        var actions: PropertiesOutlineController.Actions {
            PropertiesOutlineController.Actions(attach: { from, onto in
                self.attached.append((from, onto))
                self.list?.perform(self.list?.attach(fromDisplay: from, onto: onto))
            })
        }
    }

    @Test func aRemoteEditShowsInTheFormAndTheFocusFollowsTheList() async throws {
        let fixture = await AttributeFixture.make()
        await Self.add(.bend, fixture)
        let pairs = Self.model(fixture).pairs
        try await fixture.receive(EditEffect(pairs, label: "Remote", fields: [EffectField.bend(1)]) { $0.bend.size = 44 })
        #expect(Self.model(fixture).bendSize == 44)
        // The focus: set by the list's selection, cleared for other targets.
        let focus = InspectorFocus()
        var redraws = 0
        let token = focus.observe { redraws += 1 }
        let state = AttributesState(focus: focus)
        state.select(pairs[0].row, targets: [pairs[0].node])
        state.select(pairs[0].row, targets: [pairs[0].node])
        #expect(focus.row(for: [pairs[0].node]) == pairs[0].row && focus.row(for: []) == nil && redraws == 1 && focus.observerCount == 1)
        focus.stopObserving(token)
        #expect(focus.observerCount == 0)
    }
}
