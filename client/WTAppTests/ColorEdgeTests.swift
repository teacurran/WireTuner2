import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The colour panels' edge cases: no document, no list, the less common branches.
@Suite @MainActor struct ColorEdgeTests {
    @Test func withoutADocumentThePanelsStayQuiet() async throws {
        let bare = ColorWorkspace(selection: ActiveSelection())
        let panel = SwatchesPanelModel(workspace: bare)
        #expect(panel.selection.isEmpty && panel.dragPayload(OpID(counter: 1, replica: 1)) == nil)
        let tints = TintsModel(workspace: bare)
        #expect(tints.baseChoices.isEmpty)
        let fixture = ColorPanelFixture()
        fixture.put(NSColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1))
        #expect(tints.dropBase(from: fixture.pasteboard) && tints.dragPayload?.document == "")
        #expect(RestoreDeletedModel(workspace: bare).usage(OpID(counter: 1, replica: 1)) == nil)
        let empty = ImportFromDocumentModel(workspace: bare, documents: [])
        #expect(ImportFromDocumentSheet.sourceBinding(empty).wrappedValue.isEmpty)
        let settings = ColorSettingsModel(workspace: bare)
        #expect(!settings.result.hasRgbProfile)
        let mixer = ColorMixerModel(workspace: bare)
        #expect(mixer.dragPayload(original: true).document.isEmpty && mixer.dragPayload(original: true).color == mixer.current)
        // A pattern colour has no Display P3 form: it reads as black.
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))
        #expect(ColorDrag.color(pattern, defaultSpace: .displayP3) == RenderColor(displayP3Red: 0, green: 0, blue: 0))
        // An unset reference shows no value.
        #expect(ColorWellModel(ref: Wiretuner_Doc_V1_ColorRef(), state: EngineState()).valueText.isEmpty)
    }

    @Test func lessCommonPanelBranches() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape", group: "Purples")
        let plum = await fixture.add(RenderColor(red: 0.4, green: 0, blue: 0.4), name: "Plum")
        let panel = SwatchesPanelModel(workspace: fixture.workspace)
        panel.modifiers = { .command }
        panel.click(grape)
        panel.click(plum)
        _ = await panel.convert(to: .cmyk)?.value
        #expect(fixture.list[grape]?.color.space == .cmyk && fixture.list[plum]?.color.space == .cmyk, "two at once")
        // The views' conditional parts: a collapsed group, a selected chip, a refused rename.
        panel.toggleGroup("Purples")
        ColorPanelFixture.render(SwatchesPanelBody(model: panel))
        panel.toggleGroup("Purples")
        panel.beginRename(plum)
        panel.renameText = "Grape"
        panel.commitRename()
        ColorPanelFixture.render(SwatchRowView(swatch: try #require(fixture.list[plum]), model: panel))
        panel.cancelRename()
        panel.toggleNames()
        ColorPanelFixture.render(SwatchesPanelBody(model: panel))
        // A selected object with no fill: the Fill well shows None.
        let stroked = (await fixture.document.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5)], filled: false))[0].opID
        fixture.select([stroked])
        #expect(panel.well(.fill)?.chip == ColorWellModel.Chip.none)
        // Restore: a colour used by two objects.
        await fixture.rect(fill: fixture.list.resolver.reference(to: grape))
        await fixture.rect(fill: fixture.list.resolver.reference(to: grape))
        _ = await fixture.document.perform(RemoveSwatches([grape])).value
        #expect(RestoreDeletedModel(workspace: fixture.workspace).usage(grape) == "Still used by 2 objects")
    }

    @Test func lessCommonMixerBranches() async throws {
        let fixture = ColorPanelFixture()
        _ = fixture.preferences.set("srgb", for: PreferenceCatalog.Colors.defaultColorSpace)
        let mixer = ColorMixerModel(workspace: fixture.workspace, defaults: fixture.suite.defaults)
        #expect(mixer.mode == .rgb && mixer.current == RenderColor(red: 0, green: 0, blue: 0))
        #expect(ColorMixerModel.values(of: RenderColor(cyan: 0.1, magenta: 0, yellow: 0, black: 0.5), in: .grayscale, defaultSpace: .sRGB)[0] > 50)
        mixer.load(RenderColor(red: 0, green: 0, blue: 1))
        let again = ColorMixerModel(workspace: fixture.workspace, defaults: fixture.suite.defaults)
        #expect(again.original == RenderColor(red: 0, green: 0, blue: 1), "the original persists too")
        // A swatch dragged from another document loads as a colour, not a swatch.
        await fixture.settle()
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        var payload = ColorRefPasteboard(swatch: grape, list: fixture.list, document: "elsewhere")
        payload.document = "elsewhere"
        fixture.put(payload)
        #expect(mixer.drop(from: fixture.pasteboard) && mixer.loadedSwatch == nil)
    }

    @Test func lessCommonSheetAndFeatureBranches() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        // Color Settings: an RGB profile refused for CMYK, Other…, the refusal shown.
        let registry = WTColor.ProfileRegistry.shared
        let directory = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rgbFile = directory.appending(path: "screen.icc")
        try #require(registry.iccData(for: registry.displayP3)).write(to: rgbFile)
        let settings = ColorSettingsModel(workspace: fixture.workspace)
        settings.load(rgbFile, for: .cmyk)
        #expect(settings.refusal?.contains("a CMYK profile") == true)
        ColorPanelFixture.render(ColorSettingsSheet(model: settings), width: 560, height: 900)
        settings.chooseFile = { _ in nil }
        ColorSettingsSheet.other(.cmyk, settings)()
        // Features: the defaults, the Option-click hand-off, the panel menu, the validations.
        let fake = FakeColorLibraries()
        fake.library("lib1", name: "Brand", team: "t1", updated: 10, colors: ColorSettingsAndLibraryTests.library("Brand", RenderColor(red: 1, green: 0, blue: 0)))
        let features = ColorFeatures(selection: fixture.selection, preferences: fixture.preferences, libraryClient: ColorSettingsAndLibraryTests.client(fake)) {
            [TeamLibrariesModel.Team(id: "t1", name: "Design")]
        }
        #expect(ColorFeatures(selection: fixture.selection).teamLibraries.teams().isEmpty)
        let panels = PanelRegistry()
        let commands = CommandRegistry()
        let extensions = ExtensionRegistry()
        features.install(commands: commands, panels: panels, extensions: extensions) { [] }
        #expect(panels.descriptor(for: "swatches")?.optionsMenu().isEmpty == false)
        #expect(commands.command(ColorFeatures.ID.makeTeamLibrary)?.validation().isEnabled == true)
        #expect(commands.command(ColorFeatures.ID.publishLibraryVersion)?.validation().isEnabled == true)
        #expect(extensions.descriptor(for: "sortColorListByName")?.validate?().isEnabled == true)
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let tint = await fixture.tint(of: grape, 30)
        features.swatchesPanel.modifiers = { .option }
        features.swatchesPanel.click(tint)
        #expect(features.tints.loadedTint == tint)
        // The update dot in the menu, once a newer version is listed.
        await features.teamLibraries.refresh()
        _ = await features.teamLibraries.add("lib1")
        fake.library("lib1", name: "Brand", team: "t1", updated: 20, colors: ColorSettingsAndLibraryTests.library("Brand", RenderColor(red: 1, green: 0, blue: 0)))
        await features.teamLibraries.refresh()
        #expect(features.swatchesMenu().contains { $0.title == "Team Libraries… •" })
        // Make Team Color Library… with a chosen team; its failure message shows.
        var team = "t1"
        MakeTeamLibrarySheet.publishing(Binding(get: { team }, set: { team = $0 }), features.teamLibraries)()
        try await Task.sleep(for: .milliseconds(200))
        fake.online = false
        _ = await features.teamLibraries.publish(to: "t1")
        ColorPanelFixture.render(MakeTeamLibrarySheet(model: features.teamLibraries))
        ColorPanelFixture.render(TeamLibrariesSheet(model: features.teamLibraries))
        ColorPanelFixture.render(UpdateFromLibrarySheet(model: features.teamLibraries))
        #expect(fake.published == [fixture.document.id])
        // The palette's first appearance reads its default view; the well's palette.
        UserDefaults.standard.removeObject(forKey: PaletteKind.defaultsKey)
        let model = ColorWellModel(ref: ColorResolver.none, state: fixture.state)
        ColorPanelFixture.render(ColorPaletteView(model: model) { _ in })
        let well = ColorWellView(title: "Color", model: model, actions: ColorWellActions { _ in }, identifier: "well")
        ColorPanelFixture.render(well.palette())
    }
}
