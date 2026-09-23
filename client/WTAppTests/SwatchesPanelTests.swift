import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// COLOR-007's Swatches panel, COLOR-016's *Restore Deleted Colors…*, COLOR-019's *Import from
/// Document…* and the *Delete Unused Named Colors* preview.
@Suite @MainActor struct SwatchesPanelTests {
    static let grapeColor = RenderColor(red: 0.5, green: 0, blue: 0.5)

    static func panel(_ fixture: ColorPanelFixture, modifiers: NSEvent.ModifierFlags = []) -> SwatchesPanelModel {
        let panel = SwatchesPanelModel(workspace: fixture.workspace)
        panel.modifiers = { modifiers }
        return panel
    }

    @Test func theListShowsSectionsTintsBadgesAndSelection() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape")
        let tint = await fixture.tint(of: grape, 40)
        let lime = await fixture.add(RenderColor(displayP3Red: 0.5, green: 1, blue: 0), name: "Lime", group: "Greens")
        let panel = Self.panel(fixture)
        #expect(panel.rows.map(\.id).count == 7 && panel.rows.contains(.header("Greens", collapsed: false)))
        #expect(panel.list?[tint]?.depth == 1 && panel.list?[lime]?.badge == "P3" && panel.list?[grape]?.badge == "RGB")
        panel.toggleGroup("Greens")
        #expect(!panel.visibleSwatches.contains { $0.id == lime } && panel.rows.contains(.header("Greens", collapsed: true)))
        panel.toggleGroup("Greens")
        // Click, Shift-click, Cmd-click.
        panel.click(grape)
        #expect(panel.selected == [grape])
        panel.modifiers = { .shift }
        panel.click(lime)
        #expect(panel.selected == [grape, tint, lime])
        panel.modifiers = { .command }
        panel.click(tint)
        #expect(panel.selected == [grape, lime])
        panel.click(tint)
        #expect(panel.selected.contains(tint))
        // Option-click loads the Tints panel.
        var loaded: OpID?
        panel.loadTint = { loaded = $0 }
        panel.modifiers = { .option }
        panel.click(tint)
        #expect(loaded == tint)
        #expect(panel.well(.fill) == nil, "nothing selected on the canvas")
        #expect(SwatchesPanelModel(workspace: ColorWorkspace(selection: ActiveSelection())).rows.isEmpty)
    }

    @Test func aClickWithObjectsSelectedAppliesTheSwatchAsOneChange() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape")
        let first = await fixture.rect()
        let second = await fixture.rect()
        fixture.select([first, second])
        let panel = Self.panel(fixture)
        #expect(panel.well(.fill)?.chip == .color(.white) && panel.well(.stroke)?.chip == .color(.black))
        _ = await panel.click(grape)?.value
        let ref = fixture.list.resolver.reference(to: grape)
        #expect(fixture.fill(first) == ref && fixture.fill(second) == ref)
        #expect(fixture.document.undoTitle == "Undo Apply \"Grape\" to 2 objects")
        #expect(panel.selected.isEmpty, "a click that applies does not select")
        fixture.workspace.target = .stroke
        _ = await fixture.workspace.apply(ColorResolver.none, target: .fill)?.value
        _ = await fixture.document.perform(ApplyColor([first], target: .fill, color: ColorResolver.inline(.black))).value
        #expect(panel.well(.fill)?.chip == .mixed, "the objects' fills differ")
    }

    @Test func renamingRefusesATakenNameAndSurvivesRemoteChanges() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape")
        let plum = await fixture.add(RenderColor(red: 0.4, green: 0, blue: 0.4), name: "Plum")
        let tint = await fixture.tint(of: grape, 50)
        let panel = Self.panel(fixture)
        panel.beginRename()
        #expect(panel.renaming == nil, "nothing selected")
        panel.select(grape)
        panel.beginRename()
        #expect(panel.renaming == grape && panel.renameText == "Grape")
        panel.renameText = "Plum"
        #expect(panel.commitRename() == nil && panel.renaming == grape && panel.refusedRenames == 1, "the field shakes and stays open")
        panel.renameText = "  "
        #expect(panel.commitRename() == nil && panel.refusedRenames == 2, "a colour needs a name")
        // A collaborator renames another swatch meanwhile: the field keeps its text.
        panel.renameText = "Aubergine"
        try await fixture.receive(RenameSwatch(plum, to: "Damson"))
        #expect(panel.renaming == grape && panel.renameText == "Aubergine")
        _ = await panel.commitRename()?.value
        #expect(fixture.list[grape]?.name == "Aubergine" && panel.renaming == nil)
        #expect(fixture.document.undoTitle == "Undo Rename \"Grape\" to \"Aubergine\"")
        panel.beginRename(tint)
        #expect(panel.renameText == "50% Aubergine")
        panel.renameText = ""
        _ = await panel.commitRename()?.value
        panel.beginRename(fixture.list.swatches[0].id)
        #expect(panel.renaming == nil, "White cannot be renamed")
        panel.beginRename(grape)
        panel.cancelRename()
        #expect(panel.renaming == nil && panel.commitRename() == nil)
        panel.renaming = OpID(counter: 999, replica: 9)
        #expect(panel.commitRename() == nil && panel.renaming == nil)
    }

    @Test func removingAskesWhenInUseAndOffersEachButton() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape")
        let unused = await fixture.add(RenderColor(red: 0, green: 0, blue: 1), name: "Blue")
        let rect = await fixture.rect(fill: fixture.list.resolver.reference(to: grape))
        let panel = Self.panel(fixture)
        #expect(panel.remove() == nil, "nothing selected")
        panel.select(unused)
        _ = await panel.remove()?.value
        #expect(fixture.list[unused] == nil && fixture.document.undoTitle == "Undo Remove color \"Blue\"")
        panel.select(grape)
        #expect(panel.remove() == nil && fixture.lastSheet == SwatchesPanelModel.removeSheet && panel.pendingRemoval == [grape])
        panel.cancelRemoval()
        #expect(panel.pendingRemoval.isEmpty && fixture.list[grape] != nil)
        panel.select(grape)
        panel.remove()
        _ = await panel.removeUnused()?.value
        #expect(fixture.list[grape] != nil, "Remove Unused Only keeps a colour in use")
        panel.select(grape)
        panel.remove()
        _ = await panel.removeAll()?.value
        #expect(fixture.list[grape] == nil && fixture.fill(rect).map { ColorResolver(fixture.state).isDangling($0) } == true)
        #expect(panel.removeAll() == nil, "nothing pending")
        #expect(RemoveSwatchesSheet.message(count: 1, users: 1) == "This color is used by 1 object.  Removing keeps each object's color as an unnamed color.")
        #expect(RemoveSwatchesSheet.message(count: 2, users: 3).hasPrefix("These 2 colors are used by 3 objects"))
        ColorPanelFixture.render(RemoveSwatchesSheet(count: 2, users: 3, model: panel))
    }

    @Test func dragsReorderAndDropsAddRedefineRebaseAndRecolourTints() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape")
        let plum = await fixture.add(RenderColor(red: 0.4, green: 0, blue: 0.4), name: "Plum")
        let tint = await fixture.tint(of: grape, 50)
        let panel = Self.panel(fixture)
        // Reorder: Plum above Grape (defaults stay first).
        let order = panel.visibleSwatches.map(\.id)
        _ = await panel.move(IndexSet(integer: order.firstIndex(of: plum)!), to: 3)?.value
        #expect(fixture.list.swatches.map(\.id).suffix(3) == [plum, grape, tint])
        #expect(panel.move(IndexSet(integer: 0), to: 5) == nil, "White does not move")
        // Redefine by drop.
        let blue = RenderColor(red: 0, green: 0, blue: 1)
        _ = await panel.drop(ColorRefPasteboard(ref: ColorResolver.inline(blue), color: blue), on: grape)?.value
        #expect(fixture.list[grape]?.color == blue && fixture.list[grape]?.name == "Grape")
        #expect(panel.drop(ColorRefPasteboard(ref: ColorResolver.inline(blue), color: blue), on: fixture.list.swatches[1].id) == nil, "Black is protected")
        #expect(panel.drop(ColorRefPasteboard(ref: ColorResolver.none, color: nil), on: grape) == nil)
        // Add by drop below the list.
        _ = await panel.drop(ColorRefPasteboard(ref: ColorResolver.inline(.white), color: RenderColor(red: 0, green: 1, blue: 0), spot: true), on: nil)?.value
        #expect(fixture.list.named("0r 255g 0b")?.isSpot == true)
        #expect(panel.drop(ColorRefPasteboard(ref: ColorResolver.none, color: nil), on: nil) == nil)
        // The Tints panel's well dragged back onto a tint sets its percentage.
        var tintRef = fixture.list.resolver.tint(of: grape, percent: 30)
        _ = await panel.drop(ColorRefPasteboard(ref: tintRef, color: blue, document: fixture.document.id), on: tint)?.value
        #expect(fixture.list[tint]?.tintPercent == 30)
        // Option-drop of a swatch on a tint re-bases it.
        panel.modifiers = { .option }
        _ = await panel.drop(ColorRefPasteboard(swatch: plum, list: fixture.list, document: fixture.document.id), on: tint)?.value
        #expect(fixture.list[tint]?.base == plum)
        panel.modifiers = { [] }
        tintRef.tint.percent = 10
        // Pasteboard drops.
        fixture.pasteboard.clearContents()
        #expect(!panel.drop(from: fixture.pasteboard, on: nil) && !panel.dropOnWell(from: fixture.pasteboard, target: .fill))
        #expect(!panel.drop(from: fixture.pasteboard, onGroup: "Purples"))
        fixture.put(ColorRefPasteboard(swatch: grape, list: fixture.list, document: fixture.document.id))
        #expect(panel.drop(from: fixture.pasteboard, onGroup: "Purples"))
        await fixture.settle()
        #expect(fixture.list[grape]?.group == "Purples")
        let rect = await fixture.rect()
        fixture.select([rect])
        #expect(panel.dropOnWell(from: fixture.pasteboard, target: .fill))
        await fixture.settle()
        #expect(fixture.fill(rect) == fixture.list.resolver.reference(to: grape))
        fixture.put(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(panel.drop(from: fixture.pasteboard, on: nil) && !panel.drop(from: fixture.pasteboard, onGroup: "Purples"))
        #expect(panel.dragPayload(grape)?.name == "Grape")
        #expect(SwatchesPanelModel(workspace: ColorWorkspace(selection: ActiveSelection())).drop(ColorRefPasteboard(ref: ColorResolver.none, color: nil), on: nil) == nil)
    }

    @Test func aSwatchDroppedFromAnotherDocumentArrivesWithItsTints() async throws {
        let source = ColorPanelFixture(title: "Source")
        let target = ColorPanelFixture(title: "Target")
        await source.settle()
        await target.settle()
        let grape = await source.add(Self.grapeColor, name: "Grape")
        await source.tint(of: grape, 40)
        await source.tint(of: grape, 20)
        _ = await Self.panel(target).drop(ColorRefPasteboard(swatch: grape, list: source.list, document: source.document.id), on: nil)?.value
        await target.settle()
        let imported = try #require(target.list.named("Grape"))
        #expect(imported.id != grape && target.list.tints(of: imported.id).count == 2)
    }

    @Test func theOptionsMenuConvertsGroupsAndDuplicates() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape")
        let panel = Self.panel(fixture)
        var menu = panel.optionsMenu()
        #expect(menu.map(\.title) == ["Duplicate", "Remove", "Make Spot", "Make Process", "Convert to sRGB", "Convert to Display P3", "Convert to CMYK", "Hide Names", "New Group…"])
        #expect(menu.filter(\.isEnabled).map(\.title) == ["Hide Names"])
        #expect(panel.duplicate() == nil && panel.setSpot(true) == nil && panel.convert(to: .cmyk) == nil)
        panel.select(grape)
        menu = panel.optionsMenu(extras: [PanelMenuItem(title: "Extra") {}])
        #expect(!panel.canConvert(to: .sRGB) && panel.canConvert(to: .cmyk) && menu.last?.title == "Extra")
        for item in menu where ["Duplicate", "Make Spot", "Convert to CMYK", "Hide Names"].contains(item.title) { item.action() }
        await fixture.settle()
        #expect(fixture.list.named("Copy of Grape") != nil && fixture.list[grape]?.isSpot == true && fixture.list[grape]?.color.space == .cmyk)
        #expect(panel.namesHidden && panel.optionsMenu().contains { $0.title == "Show Names" })
        _ = await panel.setSpot(false)?.value
        #expect(fixture.list[grape]?.isSpot == false)
        // New Group…
        menu.first { $0.title == "New Group…" }?.action()
        #expect(fixture.lastSheet == SwatchesPanelModel.groupSheet)
        _ = await panel.createGroup(named: " Purples ")?.value
        #expect(fixture.list[grape]?.group == "Purples")
        #expect(panel.createGroup(named: "   ") == nil)
        panel.newGroup()
        panel.cancelGroup()
        for title in ["Remove", "Make Process", "Convert to sRGB", "Convert to Display P3"] { menu.first { $0.title == title }?.action() }
        await fixture.settle()
        ColorPanelFixture.render(NewGroupSheet(model: panel))
        var name = "Reds"
        NewGroupSheet.creating(Binding(get: { name }, set: { name = $0 }), panel)()
        // Converting with objects selected is not offered.
        let rect = await fixture.rect()
        fixture.select([rect])
        #expect(!panel.canConvert(to: .sRGB))
    }

    @Test func thePanelRendersAndItsControlsAct() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape", group: "Purples")
        let tint = await fixture.tint(of: grape, 40)
        let panel = Self.panel(fixture)
        ColorPanelFixture.render(SwatchesPanelBody(model: panel))
        panel.select(grape)
        panel.beginRename(grape)
        ColorPanelFixture.render(SwatchesPanelBody(model: panel))
        ColorPanelFixture.render(SwatchRowView(swatch: try #require(fixture.list[grape]), model: panel))
        panel.cancelRename()
        _ = await fixture.document.perform(RemoveSwatches([grape])).value
        let orphan = await fixture.orphanTint(of: grape)
        #expect(fixture.list[orphan]?.baseRemoved == true && fixture.list[tint] == nil)
        ColorPanelFixture.render(SwatchRowView(swatch: try #require(fixture.list[orphan]), model: panel))
        await fixture.add(RenderColor(red: 0, green: 0, blue: 1), name: "Blue")
        panel.toggleNames()
        ColorPanelFixture.render(SwatchesPanelBody(model: panel))
        ColorPanelFixture.render(SwatchesPanelBody(model: SwatchesPanelModel(workspace: ColorWorkspace(selection: ActiveSelection()))))
        // The body's closures.
        SwatchesPanelBody.selecting(.both, fixture.workspace)()
        #expect(fixture.workspace.target == .both)
        let blue = try #require(fixture.list.named("Blue")).id
        SwatchesPanelBody.clicking(blue, panel)()
        #expect(panel.selected == [blue])
        SwatchesPanelBody.renaming(blue, panel)()
        #expect(panel.renaming == blue)
        #expect(SwatchesPanelBody.returnKey(panel)() == .ignored)
        panel.cancelRename()
        #expect(SwatchesPanelBody.returnKey(panel)() == .handled && panel.renaming == blue)
        SwatchRowView.renameBinding(panel).wrappedValue = "Navy"
        #expect(panel.renameText == "Navy")
        SwatchesPanelBody.toggling("Purples", panel)()
        #expect(panel.collapsed.contains("Purples"))
        #expect(SwatchesPanelBody.dragging(blue, panel)().registeredTypeIdentifiers.contains(ColorRefPasteboard.typeIdentifier))
        #expect(SwatchesPanelBody.dragging(blue, SwatchesPanelModel(workspace: ColorWorkspace(selection: ActiveSelection())))().registeredTypeIdentifiers.isEmpty)
        fixture.pasteboard.clearContents()
        #expect(!SwatchesPanelBody.dropping(on: nil, panel, pasteboard: fixture.pasteboard)([]))
        #expect(!SwatchesPanelBody.droppingOnWell(.fill, panel, pasteboard: fixture.pasteboard)([]))
        #expect(!SwatchesPanelBody.droppingOnGroup("Purples", panel, pasteboard: fixture.pasteboard)([]))
        _ = SwatchesPanelBody.dropping(on: nil, panel)
        _ = SwatchesPanelBody.droppingOnWell(.fill, panel)
        _ = SwatchesPanelBody.droppingOnGroup("x", panel)
        SwatchesPanelBody.moving(panel)(IndexSet(integer: 0), 1)
    }

    // MARK: Sheets

    @Test func restoreDeletedColorsRelinksTheObjectsThatStillUseThem() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape")
        let unused = await fixture.add(RenderColor(red: 0, green: 0, blue: 1), name: "Blue")
        let rect = await fixture.rect(fill: fixture.list.resolver.reference(to: grape))
        _ = await fixture.document.perform(RemoveSwatches([grape, unused])).value
        let model = RestoreDeletedModel(workspace: fixture.workspace)
        #expect(Set(model.entries.map(\.name)) == ["Grape", "Blue"])
        #expect(model.usage(grape) == "Still used by 1 object" && model.usage(unused) == nil)
        ColorPanelFixture.render(RestoreDeletedSheet(model: model))
        let binding = RestoreDeletedSheet.toggling(grape, model)
        binding.wrappedValue = true
        #expect(binding.wrappedValue && model.ticked == [grape])
        model.toggle(unused)
        model.toggle(unused)
        _ = await model.restore()?.value
        #expect(fixture.list[grape] != nil && fixture.list[unused] == nil)
        #expect(fixture.fill(rect).map { ColorResolver(fixture.state).isDangling($0) } == false, "the reference resolves again with no write on the object")
        #expect(RestoreDeletedModel(workspace: fixture.workspace).restore() == nil)
        RestoreDeletedModel(workspace: fixture.workspace).cancel()
        ColorPanelFixture.render(RestoreDeletedSheet(model: RestoreDeletedModel(workspace: ColorWorkspace(selection: ActiveSelection()))))
    }

    @Test func deleteUnusedPreviewsAndWarnsWhenOthersAreEditing() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(Self.grapeColor, name: "Grape")
        await fixture.add(RenderColor(red: 0, green: 0, blue: 1), name: "Blue")
        await fixture.rect(fill: fixture.list.resolver.reference(to: grape))
        let presence = StubPresenceModel(participants: [RemoteParticipant(id: "p", name: "Priya", colorIndex: 1)])
        fixture.selection.presence = presence
        var model = DeleteUnusedModel(workspace: fixture.workspace)
        #expect(model.names == ["Blue"] && model.presenceLine?.hasPrefix("1 person is editing.") == true)
        ColorPanelFixture.render(DeleteUnusedSheet(model: model))
        presence.participants.append(RemoteParticipant(id: "s", name: "Sam", colorIndex: 2))
        #expect(DeleteUnusedModel(workspace: fixture.workspace).presenceLine?.hasPrefix("2 people are editing.") == true)
        _ = await model.remove()?.value
        #expect(fixture.list.named("Blue") == nil)
        fixture.selection.presence = nil
        model = DeleteUnusedModel(workspace: fixture.workspace)
        #expect(model.names.isEmpty && model.presenceLine == nil && model.remove() == nil)
        ColorPanelFixture.render(DeleteUnusedSheet(model: model))
        model.cancel()
        #expect(DeleteUnusedModel(workspace: ColorWorkspace(selection: ActiveSelection())).names.isEmpty)
    }

    @Test func importFromDocumentCopiesTheTickedColours() async throws {
        let source = ColorPanelFixture(title: "Brand")
        let target = ColorPanelFixture(title: "Poster")
        await source.settle()
        await target.settle()
        let grape = await source.add(Self.grapeColor, name: "Grape")
        await source.tint(of: grape, 40)
        let blue = await source.add(RenderColor(red: 0, green: 0, blue: 1), name: "Blue")
        let model = ImportFromDocumentModel(workspace: target.workspace, documents: [target.document, source.document])
        #expect(model.sources.map(\.id) == [source.document.id] && model.colors.count == 3)
        ColorPanelFixture.render(ImportFromDocumentSheet(model: model))
        #expect(model.importColors() == nil, "nothing ticked")
        ImportFromDocumentSheet.sourceBinding(model).wrappedValue = source.document.id
        #expect(ImportFromDocumentSheet.sourceBinding(model).wrappedValue == source.document.id)
        let tick = ImportFromDocumentSheet.toggling(grape, model)
        tick.wrappedValue = true
        #expect(tick.wrappedValue)
        model.toggle(blue)
        model.toggle(blue)
        _ = await model.importColors()?.value
        let imported = try #require(target.list.named("Grape"))
        #expect(imported.id != grape && target.list.tints(of: imported.id).count == 1 && target.list.named("Blue") == nil)
        #expect(target.document.undoTitle.hasPrefix("Undo Import"))
        model.cancel()
        let empty = ImportFromDocumentModel(workspace: target.workspace, documents: [])
        #expect(empty.colors.isEmpty && empty.source == nil)
        ColorPanelFixture.render(ImportFromDocumentSheet(model: empty))
    }
}
