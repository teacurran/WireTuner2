import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-039's client-ui half: menu:Modify[Envelope], the Envelope toolbar's commands and preset
/// pop-up, presets in the preferences, the Object panel's line and the outline's point handles.
@Suite(.serialized) @MainActor struct EnvelopeUITests {
    static let square = Rect(x: 40, y: 40, width: 100, height: 60)

    func features(_ world: GlueWorld) -> EnvelopeFeatures {
        let features = EnvelopeFeatures(target: world.target, store: world.preferences, sheets: world.sheets())
        features.install(commands: world.commands)
        return features
    }

    /// A rectangle wrapped in a rectangular envelope, selected.
    func envelope(_ world: GlueWorld, _ features: EnvelopeFeatures) async throws -> OpID {
        let ids = await world.document.addRectangles([Self.square])
        world.select(ids.map(\.opID))
        #expect(world.commands.perform(EnvelopeFeatures.ID.create))
        await world.document.settle()
        return try #require(await world.waitForSelection(.envelope))
    }

    @Test func createShowMapCopyReleaseAndRemoveAreOneChangeEach() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = features(world)
        let ids = ContextMenuCatalog.ID.self
        // Without a document, then without a selection.
        let none = EnvelopeFeatures(target: { nil }, store: world.preferences)
        #expect(none.commands().allSatisfy { $0.id == EnvelopeFeatures.ID.presets || $0.id == EnvelopeFeatures.ID.deletePreset || !$0.validation().isEnabled })
        #expect(world.commands.command(EnvelopeFeatures.ID.create)?.validation().reason == ObjectMenuCommands.noSelection)
        #expect(world.commands.command(ids.envelopeShowMap)?.validation().reason == EnvelopeFeatures.noEnvelope)
        #expect(world.commands.command(ids.envelopeRelease)?.validation().reason == EnvelopeFeatures.noEnvelope)
        let envelope = try await envelope(world, features)
        #expect(world.document.undoTitle == "Undo Create envelope" && world.state.liveChildren(envelope).count == 1)
        #expect(world.commands.command(ids.envelopeShowMap)?.validation() == .checked(false))
        // Show Map, then Hide Map: local view state, checked while shown.
        #expect(world.commands.perform(ids.envelopeShowMap))
        await world.document.settle()
        #expect(world.state.props(envelope).envelope.showMap && world.commands.command(ids.envelopeShowMap)?.validation() == .checked(true))
        #expect(EnvelopeFeatures.showsMap(world.editing))
        // Copy as Path puts the outline on the clipboard as a path.
        #expect(world.commands.perform(ids.envelopeCopyAsPath))
        let copied = try #require(EnvelopeFeatures.copiedPath(world.editing))
        #expect(PasteAsEnvelope.outline(copied)?.count == 4)
        // Release bakes the warped drawing; undo brings the live envelope back.
        #expect(world.commands.perform(ids.envelopeRelease))
        await world.document.settle()
        #expect(!world.state.isLive(envelope) && world.document.undoTitle == "Undo Release envelope")
        _ = await world.document.undo().value
        #expect(world.state.isLive(envelope))
        // Remove restores the contents.
        world.select([envelope])
        #expect(world.commands.perform(ids.envelopeRemove))
        await world.document.settle()
        #expect(!world.state.isLive(envelope) && world.document.undoTitle == "Undo Remove envelope")
        // Nothing to copy: no envelope selected.
        world.select([])
        #expect(!EnvelopeFeatures.copyAsPath(world.editing) && !EnvelopeFeatures.showsMap(world.editing))
        #expect(features.createCommand(world.editing) == nil && EnvelopeFeatures.pasteCommand(world.editing) == nil)
        // The Object panel says what the envelope is.
        let section = try #require(InspectorRegistry.standard.sections.first { $0.id == "envelope" })
        #expect(section.applies(to: [.envelope]))
    }

    @Test func pasteAsEnvelopeTakesTheCopiedPathsOutline() async throws {
        let world = GlueWorld()
        defer { world.close() }
        _ = features(world)
        let shape = try #require(await world.document.addPath([Point(x: 0, y: 0), Point(x: 200, y: 0), Point(x: 220, y: 120), Point(x: -20, y: 120)], closed: true))
        let targets = await world.document.addRectangles([Rect(x: 20, y: 20, width: 80, height: 40)])
        world.select(targets.map(\.opID))
        #expect(world.commands.command(EnvelopeFeatures.ID.pasteAsEnvelope)?.validation().reason == EnvelopeFeatures.noPath)
        world.select([shape.opID])
        world.editing.copy()
        world.select(targets.map(\.opID))
        #expect(world.commands.command(EnvelopeFeatures.ID.pasteAsEnvelope)?.validation().isEnabled == true)
        #expect(world.commands.perform(EnvelopeFeatures.ID.pasteAsEnvelope))
        await world.document.settle()
        let envelope = try #require(await world.waitForSelection(.envelope))
        #expect(world.document.undoTitle == "Undo Paste as envelope" && EnvelopeReading.contour(envelope, in: world.state)?.points.count == 4)
        world.select([])
        #expect(world.commands.command(EnvelopeFeatures.ID.pasteAsEnvelope)?.validation().reason == ObjectMenuCommands.noSelection)
        // A clipboard of something else offers nothing.
        world.select(targets.map(\.opID))
        world.editing.copy()
        #expect(EnvelopeFeatures.copiedPath(world.editing) == nil, "a rectangle is not a path")
        world.pasteboard.clearContents()
        #expect(EnvelopeFeatures.copiedPath(world.editing) == nil)
    }

    @Test func presetsLiveInThePreferencesAndThePopUpChoosesOne() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = features(world)
        #expect(features.presets == EnvelopePreset.defaults && features.chosenPreset == .rectangle)
        // The pop-up lists every preset, the chosen one checked; choosing one makes it Create's.
        var shown: [NSMenu] = []
        features.presentMenu = { shown.append($0) }
        #expect(world.commands.perform(EnvelopeFeatures.ID.presets))
        let menu = try #require(shown.first)
        #expect(menu.items.map(\.title) == EnvelopePreset.defaults.map(\.name) && menu.items.first?.state == .on)
        let arch = try #require(menu.items.first { $0.title == "Arch" } as? ActionMenuItem)
        arch.choose(nil)
        #expect(features.chosenPreset == .arch && world.preferences[EnvelopePreferences.chosen] == "Arch")
        #expect(world.commands.command(EnvelopeFeatures.ID.deletePreset)?.validation().title == "Delete Preset “Arch”")
        // Create uses the chosen preset.
        let envelope = try await envelope(world, features)
        #expect(EnvelopeReading.contour(envelope, in: world.state)?.points.count == EnvelopePreset.arch.points.count)
        // Save as Preset…: the sheet names the envelope's shape; the defaults stay in the list.
        #expect(world.commands.perform(EnvelopeFeatures.ID.savePreset))
        #expect(world.presented.value.last?.identifier?.rawValue == EnvelopeFeatures.sheet)
        features.save(try #require(EnvelopePreset(name: "Mine", envelope: envelope, in: world.state)))
        #expect(features.presets.map(\.name) == EnvelopePreset.defaults.map(\.name) + ["Mine"] && features.chosenPreset.name == "Mine")
        #expect(world.preferences[EnvelopePreferences.presets].count == 6)
        // Saving under an existing name replaces it.
        features.save(EnvelopePreset(name: "Mine", points: EnvelopePreset.bulge.points, corners: EnvelopePreset.bulge.corners))
        #expect(features.presets.count == 6 && features.chosenPreset.points == EnvelopePreset.bulge.points)
        // Delete Preset removes the chosen one; deleting every preset brings the defaults back.
        #expect(world.commands.perform(EnvelopeFeatures.ID.deletePreset))
        #expect(!features.presets.contains { $0.name == "Mine" } && features.chosenPreset == .rectangle)
        world.preferences.set([EnvelopePreset.flag.encoded], for: EnvelopePreferences.presets)
        features.choose("Flag")
        features.deleteChosen()
        #expect(features.presets == EnvelopePreset.defaults)
        // A chosen name no longer in the list reads as the first preset.
        features.choose("Gone")
        #expect(features.chosenPreset == .rectangle)
        world.select([])
        features.showSavePreset(world.editing)
        #expect(world.presented.value.count == 1, "nothing to save without an envelope")
    }

    @Test func thePresetSheetAndTheObjectPanelLineRender() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = features(world)
        let envelope = try await envelope(world, features)
        var named: [String?] = []
        let finish: @MainActor (String?) -> Void = { named.append($0) }
        EnvelopePresetSheet.cancelling(finish)()
        EnvelopePresetSheet.confirming("  Wave  ", name: "Preset 6", finish: finish)()
        EnvelopePresetSheet.confirming(nil, name: "Preset 6", finish: finish)()
        EnvelopePresetSheet.confirming("   ", name: "Preset 6", finish: finish)()
        #expect(named == [nil, "Wave", "Preset 6", nil])
        var typed: String? = nil
        let text = EnvelopePresetSheet.text(Binding(get: { typed }, set: { typed = $0 }), name: "Preset 6")
        #expect(text.wrappedValue == "Preset 6")
        text.wrappedValue = "Arc"
        #expect(typed == "Arc")
        Render.view(EnvelopePresetSheet(name: "Preset 1", finish: finish))
        // The sheet's OK saves the shape and dismisses.
        features.showSavePreset(world.editing)
        let window = try #require(world.presented.value.last)
        let host = try #require(window.contentViewController as? NSHostingController<EnvelopePresetSheet>)
        host.rootView.finish("Saved")
        #expect(features.presets.contains { $0.name == "Saved" })
        // The Object panel line, with the too-few-points note.
        let model = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(envelope)]))
        #expect(EnvelopeSection.section.make(model) != nil)
        #expect(EnvelopeSection.section.make(ObjectPanelModel(document: world.document, selection: Selection([]))) == nil)
        Render.view(EnvelopeSectionView(title: "Envelope", needsPoints: true))
        Render.view(EnvelopeSectionView(title: "Empty envelope", needsPoints: false))
    }

    @Test func theOutlineHandlesDragPointsAndHandles() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = features(world)
        let envelope = try await envelope(world, features)
        let host = RecordingHost()
        let context = world.context(host)
        let layer = EnvelopeOutlineHandles()
        let outline = try #require(layer.outlines(context).first)
        let corner = try #require(outline.contour.drawn.first)
        let viewport = context.viewport
        let at = viewport.toView(outline.transform.apply(corner.anchor))
        // A press away from every point is the tool's.
        #expect(!layer.press(CanvasEvent(pasteboardPoint: .zero, viewPoint: Point(x: -50, y: -50)), context: context))
        // Drag the corner: one change "Move Point", the outline follows.
        #expect(layer.press(CanvasEvent(pasteboardPoint: viewport.toPasteboard(at), viewPoint: at), context: context))
        let to = Point(x: at.x - 10, y: at.y - 20)
        layer.drag(CanvasEvent(pasteboardPoint: viewport.toPasteboard(to), viewPoint: to), context: context)
        layer.draw(in: world.bitmap(), viewport: viewport, context: context)
        layer.release(CanvasEvent(pasteboardPoint: viewport.toPasteboard(to), viewPoint: to), context: context)
        await world.document.settle()
        let moved = try #require(EnvelopeReading.contour(envelope, in: world.state)?.drawn.first)
        #expect(world.document.undoTitle == "Undo Move Point" && abs(moved.anchor.x - (corner.anchor.x - 10)) < 1e-6)
        // Shift constrains the drag to 45° steps; Esc abandons it.
        let second = try #require(layer.outlines(context).first?.contour.drawn[1])
        let point = viewport.toView(outline.transform.apply(second.anchor))
        #expect(layer.press(CanvasEvent(pasteboardPoint: viewport.toPasteboard(point), viewPoint: point, modifiers: .shift), context: context))
        layer.cancel(context: context)
        #expect(layer.drag == nil)
        layer.drag(CanvasEvent(pasteboardPoint: .zero, viewPoint: .zero), context: context)
        layer.release(CanvasEvent(pasteboardPoint: .zero, viewPoint: .zero), context: context)
        #expect(layer.press(CanvasEvent(pasteboardPoint: viewport.toPasteboard(point), viewPoint: point), context: context))
        let shifted = Point(x: point.x + 30, y: point.y + 4)
        layer.release(CanvasEvent(pasteboardPoint: viewport.toPasteboard(shifted), viewPoint: shifted, modifiers: .shift), context: context)
        await world.document.settle()
        let constrained = try #require(EnvelopeReading.contour(envelope, in: world.state)?.drawn[1])
        #expect(abs(constrained.anchor.y - second.anchor.y) < 1e-6 && abs(constrained.anchor.x - (second.anchor.x + 30)) < 1e-6)
        // A click without a move writes nothing.
        let before = world.document.changeCount
        let now = viewport.toView(outline.transform.apply(constrained.anchor))
        #expect(layer.press(CanvasEvent(pasteboardPoint: viewport.toPasteboard(now), viewPoint: now), context: context))
        layer.release(CanvasEvent(pasteboardPoint: viewport.toPasteboard(now), viewPoint: now), context: context)
        await world.document.settle()
        #expect(world.document.changeCount == before)
        // A curve point's handles: drag each end.
        _ = await world.document.perform(EditEnvelopePoint(node: envelope, contour: outline.contour.id, point: corner.id,
                                                           inHandle: Vector(dx: -10, dy: 0), outHandle: Vector(dx: 10, dy: 0))).value
        #expect(world.document.undoTitle == "Undo Move Handle")
        let curved = try #require(layer.outlines(context).first)
        let anchor = try #require(curved.contour.drawn.first)
        for (handle, part) in [(anchor.outHandle, EnvelopeOutlineHandles.Part.outHandle), (anchor.inHandle, .inHandle)] {
            let end = viewport.toView(curved.transform.apply(anchor.anchor + handle))
            #expect(EnvelopeOutlineHandles.hit(curved, at: end, viewport: viewport)?.part == part)
            #expect(layer.press(CanvasEvent(pasteboardPoint: viewport.toPasteboard(end), viewPoint: end), context: context))
            let pulled = Point(x: end.x, y: end.y + 8)
            layer.drag(CanvasEvent(pasteboardPoint: viewport.toPasteboard(pulled), viewPoint: pulled), context: context)
            layer.draw(in: world.bitmap(), viewport: viewport, context: context)
            layer.release(CanvasEvent(pasteboardPoint: viewport.toPasteboard(pulled), viewPoint: pulled), context: context)
            await world.document.settle()
        }
        let pulled = try #require(EnvelopeReading.contour(envelope, in: world.state)?.drawn.first)
        #expect(pulled.outHandle.dy > 0 && pulled.inHandle.dy > 0)
        // A locked envelope shows no handles.
        _ = await world.document.perform(SetLocked([envelope], locked: true)).value
        #expect(layer.outlines(context).isEmpty)
        #expect(EnvelopeOutlineHandles.outlinePath([], closed: true, transform: .identity).isEmpty)
        #expect(!EnvelopeOutlineHandles.outlinePath(curved.contour.drawn, closed: false, transform: .identity).isEmpty)
    }

    @Test func editingAnEnvelopePointRefusesWhatIsNotThere() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = features(world)
        let envelope = try await envelope(world, features)
        let contour = try #require(EnvelopeReading.contour(envelope, in: world.state))
        let point = contour.points[0].id
        var builder = ChangeBuilder(replica: 9, startCounter: 1)
        let rect = try #require(world.state.liveChildren(envelope).first)
        #expect(throws: EditEnvelopePoint.Failure.notAnEnvelope) {
            try EditEnvelopePoint(node: rect, contour: contour.id, point: point, anchor: .zero).execute(&builder, state: world.state)
        }
        #expect(throws: EditEnvelopePoint.Failure.noSuchPoint) {
            try EditEnvelopePoint(node: envelope, contour: point, point: point, anchor: .zero).execute(&builder, state: world.state)
        }
        #expect(throws: EditEnvelopePoint.Failure.invalidValue) {
            try EditEnvelopePoint(node: envelope, contour: contour.id, point: point).execute(&builder, state: world.state)
        }
        #expect(throws: EditEnvelopePoint.Failure.invalidValue) {
            try EditEnvelopePoint(node: envelope, contour: contour.id, point: point, anchor: Point(x: .nan, y: 0)).execute(&builder, state: world.state)
        }
        // On a reversed contour the drawing's handles are the stored ones swapped.
        _ = await world.document.perform(ReverseEnvelopeContour(node: envelope, contour: contour.id)).value
        _ = await world.document.perform(EditEnvelopePoint(node: envelope, contour: contour.id, point: point, outHandle: Vector(dx: 5, dy: 0))).value
        let stored = try #require(EnvelopeReading.path(envelope, in: world.state).contours.first?.points.first { $0.id == point })
        #expect(stored.inHandle == Vector(dx: 5, dy: 0))
        _ = await world.document.perform(EditEnvelopePoint(node: envelope, contour: contour.id, point: point, inHandle: Vector(dx: 0, dy: 5))).value
        let again = try #require(EnvelopeReading.path(envelope, in: world.state).contours.first?.points.first { $0.id == point })
        #expect(again.outHandle == Vector(dx: 0, dy: 5))
    }
}

/// Test stand-in: sets `reversed` on an envelope contour.
struct ReverseEnvelopeContour: WTModel.Command {
    let node: OpID
    let contour: OpID
    var label: String { "Reverse" }

    func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        var props = Wiretuner_Doc_V1_NodeProps()
        var contour = Wiretuner_Doc_V1_Contour()
        contour.reversed = true
        props.envelope.contours = [contour]
        builder.append(Ops.set(node, [EnvelopeFields.contour(self.contour).child(4)], values: props))
    }
}
