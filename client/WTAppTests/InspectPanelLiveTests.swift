import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// COLLAB-037's rest: the *Inspect unit* and *Inspect scale* preferences behind the panel's
/// pop-ups, the attribution flash on the rows a collaborator's change altered, and inspecting a
/// collaborator's selection (the command, the name tag, following and stopping).
@Suite(.serialized) @MainActor struct InspectPanelLiveTests {
    /// A panel over `world`'s window with the glue installed on its registries.
    func panel(_ world: GlueWorld, attach: Bool = true) -> (ModelGlueFeatures, InspectPanelModel) {
        let glue = ModelGlueFeatures(preferences: world.preferences)
        let window = world.window
        glue.install(commands: world.commands, panels: world.setup.environment.panels, extensions: ExtensionRegistry()) { window }
        if attach { glue.attach(window) }
        glue.inspect.pasteboard = world.pasteboard
        return (glue, glue.inspect)
    }

    @Test func unitAndScaleAreThePreferences() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (_, model) = panel(world)
        #expect(model.unitChoice == InspectPanelModel.documentUnit && model.scale == 1)
        let rects = await world.document.addRectangles([Rect(x: 10, y: 20, width: 100, height: 50)])
        world.select([rects[0].opID])
        model.selectionDidChange()
        let object = try #require(model.object)
        // Document units: the document reads points.
        #expect(model.unit == .points && model.layout(object)[2].value == "100pt")
        _ = world.document.setUnits(.millimeters)
        await world.document.settle()
        #expect(model.unit == .millimeters)
        for (unit, expected) in [(LengthUnit.pixels, SnippetUnit.pixels), (.inches, .inches), (.decimalInches, .inches), (.kyus, .millimeters),
                                 (.centimeters, .centimeters), (.picas, .points)] {
            #expect(InspectPanelModel.snippetUnit(for: unit) == expected)
        }
        // The pop-ups write the preferences; the Preferences window's rows reach the pop-ups.
        model.unit = .inches
        model.scale = 2
        #expect(world.preferences[PreferenceCatalog.Sync.inspectUnit] == "inches" && world.preferences[PreferenceCatalog.Sync.inspectScale] == 2)
        world.preferences.set("centimeters", for: PreferenceCatalog.Sync.inspectUnit)
        world.preferences.set(1.5, for: PreferenceCatalog.Sync.inspectScale)
        #expect(model.unitChoice == "centimeters" && model.scale == 1.5)
        #expect(model.scaleChoices == [1, 2, 3, 1.5] && InspectPanelModel.scaleTitle(1.5) == "1.5×" && InspectPanelModel.scaleTitle(2) == "2×")
        model.scale = 3
        #expect(model.scaleChoices == [1, 2, 3])
        #expect(InspectPanelModel.unitChoices.first?.1 == "Document units" && InspectPanelModel.unitChoices.count == 6)
        // Both are local rows of *Sync and collaboration*.
        for key in [PreferenceCatalog.Sync.inspectUnit.erased, PreferenceCatalog.Sync.inspectScale.erased] {
            #expect(key.scope == .local && key.category == .sync && PreferenceCatalog.keys(in: .sync).contains { $0.id == key.id })
        }
        #expect(!world.preferences.set(40, for: PreferenceCatalog.Sync.inspectScale), "outside 0.25...16")
        // Re-attaching reads the store again.
        model.attach(preferences: world.preferences)
        #expect(model.unitChoice == "centimeters" && model.scale == 3)
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 900))
    }

    @Test func aCollaboratorsChangeFlashesTheRowsItAltered() async throws {
        let world = GlueWorld()
        defer { world.close() }
        // Not attached: the test drives the comparison itself rather than racing the document's observer.
        let (_, model) = panel(world, attach: false)
        model.unit = .points
        let rects = await world.document.addRectangles([Rect(x: 10, y: 20, width: 100, height: 50)])
        let node = rects[0].opID
        world.select([node])
        model.selectionDidChange()
        // A change nobody is credited with (the local user's own) flashes nothing.
        _ = await world.document.perform(SetShapeSize(node: node, size: Size(width: 120, height: 50))).value
        model.rowsMayHaveChanged()
        #expect(model.flashing.isEmpty)
        // Priya resizes it: the pulse is hers, and the Width row (and the Code) flash in her colour.
        let change = try #require(await world.document.perform(SetShapeSize(node: node, size: Size(width: 140, height: 50))).value)
        world.window.collaboration.flashes.changeApplied(change, author: SessionAuthor(name: "Priya", colorIndex: 3))
        model.rowsMayHaveChanged()
        #expect(model.flash("Width")?.colorIndex == 3 && model.flash("Height") == nil && model.flash("Code") != nil)
        #expect(model.flash("Width")?.color == InspectPanelModel.RowFlash(colorIndex: 3, started: .distantPast).color)
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 900))
        #expect(InspectPanelBody.flashBackground(model, "Width") != .clear && InspectPanelBody.flashBackground(model, "X") == .clear)
        // The flash ends after 1.5 s.
        let later = Date().addingTimeInterval(2)
        model.now = { later }
        #expect(model.flash("Width") == nil)
        // A document change after a selection change compares with the new selection, not the old.
        model.now = { Date() }
        model.flashClearDelay = .zero
        model.documentDidChange()
        await Task.yield()
        #expect(await eventually { model.flashing.isEmpty })
    }

    @Test func inspectingACollaboratorsSelectionFollowsItUntilILookElsewhere() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (_, model) = panel(world)
        let presence = try #require(world.window.presence as? StubPresenceModel)
        let rects = await world.document.addRectangles([Rect(x: 10, y: 20, width: 100, height: 50), Rect(x: 200, y: 20, width: 30, height: 30)])
        var priya = RemoteParticipant(id: "p1", name: "Priya", colorIndex: 4, selection: [rects[1]])
        presence.participants = [priya]
        world.select([rects[0].opID])
        model.selectionDidChange()
        #expect(model.object.map { Int($0.bounds.width) } == 100)
        // The command names her and points the panel at her selection.
        let command = try #require(world.commands.command(RemoteSelectionInspection.ID.inspectSelection))
        #expect(command.validation().title == "Inspect Priya's Selection")
        #expect(world.commands.perform(RemoteSelectionInspection.ID.inspectSelection))
        #expect(model.remote.isActive && model.remote.title == "Priya's selection" && model.remote.colorIndex == 4)
        #expect(model.object.map { Int($0.bounds.width) } == 30)
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 900))
        // She selects the other rectangle: the panel follows.
        priya.selection = [rects[0]]
        priya.name = "Priya S"
        presence.participants = [priya]
        #expect(model.object.map { Int($0.bounds.width) } == 100 && model.remote.name == "Priya S")
        // An object not received yet: waiting.
        priya.selection = [SelectionID(NodeID(counter: 999, replica: 77))]
        presence.participants = [priya]
        #expect(model.object == nil && model.isWaitingForRemote)
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 900))
        // Nothing selected.
        priya.selection = []
        presence.participants = [priya]
        #expect(model.object == nil && !model.isWaitingForRemote)
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 900))
        // A local selection change ends it.
        world.select([rects[1].opID])
        model.selectionDidChange()
        #expect(!model.remote.isActive && model.object.map { Int($0.bounds.width) } == 30)
        // Stop, and leaving, end it too.
        model.inspect(priya)
        InspectPanelBody.stopRemote(model)()
        #expect(!model.remote.isActive)
        model.stopInspectingRemote()
        model.inspect(priya)
        presence.participants = []
        #expect(!model.remote.isActive)
        #expect(command.validation().reason == CollaborationCommands.nobodyElse)
        model.presenceDidChange()
    }

    @Test func aClickOnHerNameTagInInspectModeInspectsHerSelection() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (_, model) = panel(world)
        defer { InspectTool.nameTagClicked = nil }
        let presence = try #require(world.window.presence as? StubPresenceModel)
        let rects = await world.document.addRectangles([Rect(x: 100, y: 100, width: 80, height: 40)])
        let priya = RemoteParticipant(id: "p1", name: "Priya", colorIndex: 2, selection: [rects[0]])
        presence.participants = [priya]
        let overlay = SelectionOverlay(document: world.document, viewport: world.window.viewport)
        let tag = try #require(overlay.remoteMarks(for: [priya]).first?.tagRect)
        #expect(RemoteSelectionInspection.participant(atTag: tag.center, in: world.window)?.id == "p1")
        #expect(RemoteSelectionInspection.participant(atTag: Point(x: tag.minX - 50, y: tag.minY - 50), in: world.window) == nil)
        let controller = InspectModeController(window: world.window)
        controller.enter()
        defer { controller.leave() }
        let tool = try #require(controller.tool)
        tool.mouseDown(CanvasEvent(pasteboardPoint: world.window.viewport.toPasteboard(tag.center), viewPoint: tag.center, modifiers: []))
        #expect(model.remote.participantID == "p1", "the click inspected")
        // Elsewhere, the click selects as before.
        let inside = Point(x: 140, y: 120)
        tool.mouseDown(CanvasEvent(pasteboardPoint: inside, viewPoint: world.window.viewport.toView(inside), modifiers: []))
        #expect(world.window.selection.selection.ids == [rects[0]])
        // With selections hidden there is no tag to click.
        world.preferences.set(false, for: PreferenceCatalog.Sync.showSelections)
        #expect(RemoteSelectionInspection.participant(atTag: tag.center, in: world.window) == nil)
        // Without a handler nothing is taken.
        InspectTool.nameTagClicked = nil
        #expect(!tool.inspectsNameTag(at: tag.center))
        let remote = RemoteSelectionInspection()
        #expect(!remote.stop() && !remote.presenceDidChange([priya]) && remote.participant(in: [priya]) == nil)
    }
}
