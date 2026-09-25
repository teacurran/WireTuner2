import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FX-008's raster effect forms, submenu items and resolution sheets, and FX-014's transparency
/// forms -- driven through the Object panel's models and views, as the UI tests of *Done when*.
@Suite(.serialized) @MainActor struct RasterEffectFormTests {
    typealias Editor = EffectEditorTests

    /// Adds `preset` through the list's submenu item and returns the editor of the new effect.
    static func add(_ preset: EffectPreset, _ fixture: AttributeFixture) async -> EffectEditorModel {
        let list = fixture.list()
        _ = await list.perform(list.addEffectPreset(preset, above: nil))?.value
        return Editor.model(fixture)
    }

    @Test func everySubmenuItemAddsItsEffectInItsStyle() async throws {
        let fixture = await AttributeFixture.make()
        for group in EffectPresetMenu.groups {
            for preset in group.presets {
                let model = await Self.add(preset, fixture)
                #expect(model.kind == preset.kind && fixture.document.undoTitle == "Undo Add \(preset.title) effect")
                AttributeFixture.render(EffectEditorView(model: model))
            }
        }
        // Attached to the selected fill; nothing without targets.
        let fill = try #require(fixture.list().rows.first { $0.list == .fills })
        _ = await fixture.list().perform(fixture.list().addEffectPreset(.blur(.basic), above: fill))?.value
        #expect(EffectReading.entries(fixture.ids[0].opID, in: fixture.document.state).contains { $0.attachment == .element(fill.id) })
        let effectRow = try #require(fixture.list().rows.last { $0.list == .effects })
        #expect(fixture.list().addEffectPreset(.blur(.basic), above: effectRow)?.attachTo.isEmpty == true)
        AttributeFixture.render(AttributesListView(model: fixture.list(), state: AttributesState(focus: InspectorFocus()), selection: nil))
    }

    @Test func theBevelAndBlurOptionsRoundTrip() async throws {
        let fixture = await AttributeFixture.make()
        var model = await Self.add(.bevel(.outerBevel), fixture)
        #expect(model.isOuterBevel && !model.isEmboss)
        let red = ColorResolver.inline(Color(red: 1, green: 0, blue: 0))
        await Editor.apply(fixture, [
            { $0.setBevelColor(red) }, { $0.setBevelWidth(-3) }, { $0.setBevelContrast(140) }, { $0.setBevelSoftness(4) },
            { $0.setBevelAngle(-45) }, { $0.setEdgeShape(.ring) }, { $0.setButtonPreset(.inverted) },
        ])
        model = Editor.model(fixture)
        #expect(model.bevelColor == red && model.bevelWidth == 0 && model.bevelContrast == 100 && model.bevelSoftness == 4)
        #expect(model.bevelAngle == 315 && model.edgeShape == .ring && model.buttonPreset == .inverted)
        AttributeFixture.render(EffectEditorView(model: model))
        await Editor.perform(model.setBevelStyle(.raisedEmboss), fixture)
        #expect(Editor.model(fixture).isEmboss && Editor.model(fixture).bevelStyle == .raisedEmboss)
        AttributeFixture.render(EffectEditorView(model: Editor.model(fixture)))
        model = await Self.add(.blur(.basic), fixture)
        await Editor.apply(fixture, [{ $0.setBlurRadius(400) }, { $0.setBlurStyle(.gaussian) }])
        #expect(Editor.model(fixture).blurRadius == 250 && Editor.model(fixture).blurStyle == .gaussian)
        #expect(EffectEditorModel.normalized(725) == 5)
    }

    @Test func theShadowAndSharpenOptionsRoundTrip() async throws {
        let fixture = await AttributeFixture.make()
        _ = await Self.add(.shadow(.dropShadow), fixture)
        let blue = ColorResolver.inline(Color(red: 0, green: 0, blue: 1))
        await Editor.apply(fixture, [
            { $0.setShadowColor(blue) }, { $0.setShadowOffset(12) }, { $0.setShadowOpacity(80) }, { $0.setShadowSoftness(40) }, { $0.setShadowAngle(90) },
        ])
        var model = Editor.model(fixture)
        #expect(model.shadowColor == blue && model.shadowOffset == 12 && model.shadowOpacity == 80 && model.shadowSoftness == 30 && model.shadowAngle == 90)
        #expect(!model.isGlow)
        AttributeFixture.render(EffectEditorView(model: model))
        await Editor.perform(model.setShadowStyle(.innerGlow), fixture)
        #expect(Editor.model(fixture).isGlow)
        AttributeFixture.render(EffectEditorView(model: Editor.model(fixture)))
        _ = await Self.add(.sharpen(.basic), fixture)
        await Editor.apply(fixture, [{ $0.setSharpenAmount(600) }, { $0.setSharpenStyle(.unsharpMask) }, { $0.setSharpenRadius(0) }, { $0.setSharpenThreshold(300) }])
        model = Editor.model(fixture)
        #expect(model.sharpenAmount == 500 && model.sharpenStyle == .unsharpMask && model.sharpenRadius == 0.1 && model.sharpenThreshold == 255)
        AttributeFixture.render(EffectEditorView(model: model))
    }

    @Test func theTransparencyFormsAndTheGrayRamp() async throws {
        let fixture = await AttributeFixture.make()
        var model = await Self.add(.transparency(.basic), fixture)
        await Editor.perform(model.setTransparencyAmount(35), fixture)
        #expect(Editor.model(fixture).transparencyAmount == 35)
        AttributeFixture.render(EffectEditorView(model: Editor.model(fixture)))
        await Editor.perform(Editor.model(fixture).setTransparencyStyle(.feather), fixture)
        await Editor.apply(fixture, [{ $0.setFeatherRadius(-2) }, { $0.setFeatherSoftness(70) }])
        model = Editor.model(fixture)
        #expect(model.transparencyStyle == .feather && model.featherRadius == 0 && model.featherSoftness == 70)
        AttributeFixture.render(EffectEditorView(model: model))
        // Gradient Mask seeds a black-to-white ramp, drawn in gray.
        await Editor.perform(model.setTransparencyStyle(.gradientMask), fixture)
        model = Editor.model(fixture)
        #expect(model.transparencyStyle == .gradientMask && model.maskType == .linear && model.maskStops.map(\.offset) == [0, 1])
        AttributeFixture.render(EffectEditorView(model: model))
        await Editor.perform(model.setMaskType(.radial), fixture)
        await Editor.perform(Editor.model(fixture).addMaskStop(), fixture)
        model = Editor.model(fixture)
        #expect(model.maskType == .radial && model.maskStops.count == 3 && abs(model.maskStops[1].offset - 0.5) < 1e-9 && abs(model.maskStops[1].gray - 0.5) < 0.02)
        let middle = model.maskStops[1].id
        MaskRampView.moving(model, middle)(25)
        await fixture.document.settle()
        MaskRampView.graying(Editor.model(fixture), middle)(10)
        await fixture.document.settle()
        model = Editor.model(fixture)
        #expect(model.maskStops[1].offset == 0.25 && abs(model.maskStops[1].gray - 0.1) < 0.02)
        #expect(MaskRampView.gradient(model.maskStops).stops.count == 3)
        AttributeFixture.render(MaskRampView(model: model))
        // A remote stop insert shows up while the user edits another.
        let pair = model.pairs[0]
        try await fixture.receive(AddMaskStop(node: pair.node, row: pair.row, offset: 0.8, gray: 0.9))
        #expect(Editor.model(fixture).maskStops.count == 4)
        MaskRampView.removing(Editor.model(fixture), middle)()
        await fixture.document.settle()
        MaskRampView.adding(Editor.model(fixture))()
        await fixture.document.settle()
        #expect(Editor.model(fixture).maskStops.count == 4)
        // The ramp keeps two stops; several selected effects show no ramp.
        while Editor.model(fixture).maskStops.count > 2 {
            await Editor.perform(Editor.model(fixture).removeMaskStop(Editor.model(fixture).maskStops[1].id), fixture)
        }
        #expect(Editor.model(fixture).removeMaskStop(Editor.model(fixture).maskStops[0].id) == nil)
        let two = await AttributeFixture.make(2)
        let list = two.list()
        _ = await list.perform(list.addEffectPreset(.transparency(.gradientMask), above: nil))?.value
        let both = Editor.model(two)
        #expect(both.maskStops.isEmpty && both.addMaskStop() == nil)
        AttributeFixture.render(MaskRampView(model: both))
    }

    @Test func theResolutionSheetsWriteOneChangeOnOK() async throws {
        let setup = SetupWindow()
        defer { setup.close() }
        let features = RasterEffectSettingsFeatures()
        var sheets: [NSWindow] = []
        features.presentSheet = { sheet, _ in sheets.append(sheet) }
        #expect(features.command().validation() == .disabled(RasterEffectSettingsFeatures.noDocument))
        #expect(features.present(.document) == nil)
        let window = setup.window
        features.window = { window }
        #expect(features.command().validation() == .enabled)
        let registry = CommandRegistry()
        registry.replace(features.command())
        #expect(registry.perform(RasterEffectSettingsFeatures.documentID) && sheets.count == 1)
        let document = try #require(features.present(.document))
        #expect(document.title == "Raster Effects" && document.resolution == 72 && !document.optimalCMYK)
        PanelRendering.host(RasterSettingsSheet(model: document))
        document.resolution = 0
        document.ok()
        #expect(document.message != nil)
        document.resolution = 300
        document.optimalCMYK = true
        document.ok()
        await setup.document.settle()
        #expect(ChangeRasterEffectSettings.read(setup.document.state) == (300, true) && features.sheet == nil)
        // An object's own resolution, and back to the document's.
        let ids = await setup.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(!features.objectMenuItem().isEnabled)
        window.selection.model.set(Selection(ids))
        let item = features.objectMenuItem()
        #expect(item.isEnabled && item.title == "Raster Effect Settings…")
        item.action()
        let object = try #require(features.present(.objects(ids.map(\.opID))))
        #expect(object.usesDocument && object.resolution == 300 && object.title == "Raster Effect Settings")
        PanelRendering.host(RasterSettingsSheet(model: object))
        object.usesDocument = false
        object.resolution = 150
        object.ok()
        await setup.document.settle()
        #expect(SetObjectRasterResolution.read(ids[0].opID, in: setup.document.state) == 150)
        let again = try #require(features.present(.objects(ids.map(\.opID))))
        #expect(!again.usesDocument && again.resolution == 150)
        again.usesDocument = true
        again.resolution = 0
        again.ok()
        await setup.document.settle()
        #expect(SetObjectRasterResolution.read(ids[0].opID, in: setup.document.state) == 0)
        features.present(.document)?.cancel()
        features.dismiss()
        // The preview preference reaches the canvas.
        #expect(RasterEffectSettingsFeatures.preview("document") == .document && RasterEffectSettingsFeatures.preview("draft") == .draft)
        #expect(RasterEffectSettingsFeatures.preview("off") == .off && RasterEffectSettingsFeatures.preview("screen") == .screen)
        RasterEffectSettingsFeatures.follow(window, preferences: setup.environment.preferences)
        setup.environment.preferences.set("off", for: PreferenceCatalog.Redraw.rasterEffectPreview)
        setup.environment.preferences.set(true, for: PreferenceCatalog.General.smartGuides)
    }

    @Test func unsetStylesReadAsTheirDefaultsAndTheSheetsDefaultPresenters() async throws {
        let fixture = await AttributeFixture.make()
        let cases: [(EffectPreset, [[UInt32]])] = [
            (.bevel(.outerBevel), [RasterField.bevel(1), RasterField.bevel(7), RasterField.bevel(8)]), (.blur(.basic), [RasterField.blur(1)]),
            (.shadow(.glow), [RasterField.shadow(1)]), (.sharpen(.unsharpMask), [RasterField.sharpen(1)]),
            (.transparency(.gradientMask), [RasterField.transparency(1), EffectFields.field(.transparency, 5) + [1]]),
        ]
        for (preset, fields) in cases {
            let model = await Self.add(preset, fixture)
            await Editor.perform(EditEffect(model.pairs, label: "Unset", fields: fields) { _ in }, fixture)
        }
        let entries = EffectReading.entries(fixture.ids[0].opID, in: fixture.document.state)
        func model(_ kind: Wiretuner_Doc_V1_EffectKind) -> EffectEditorModel {
            let list = fixture.list()
            let row = entries.last { $0.kind == kind }!.row
            let index = list.rows.firstIndex { $0.id == row }!
            return EffectEditorModel(context: fixture.context(index))
        }
        #expect(model(.bevelEmboss).bevelStyle == .innerBevel && model(.bevelEmboss).edgeShape == .flat && model(.bevelEmboss).buttonPreset == .raised)
        #expect(model(.blur).blurStyle == .gaussian && model(.shadow).shadowStyle == .dropShadow && model(.sharpen).sharpenStyle == .basic)
        #expect(model(.transparency).transparencyStyle == .basic && model(.transparency).maskType == .linear)
        // Mixed object resolutions read as the document's; the default presenters show a sheet.
        let setup = SetupWindow()
        defer { setup.close() }
        let ids = await setup.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        _ = await setup.document.perform(SetObjectRasterResolution([ids[0].opID], ppi: 200)).value
        let mixed = RasterSettingsModel(document: setup.document, target: .objects(ids.map(\.opID))) { _ in }
        #expect(mixed.usesDocument && mixed.resolution == 72)
        let features = RasterEffectSettingsFeatures()
        #expect(!features.objectMenuItem().isEnabled)
        let parent = TestWindow.make()
        let sheet = TestWindow.make()
        features.presentSheet(sheet, parent)
        parent.endSheet(sheet)
        let floating = TestWindow.make()
        features.presentSheet(floating, nil)
        floating.orderOut(nil)
        let window = setup.window
        features.window = { window }
        let presented = try #require(features.present(.document))
        presented.cancel()
    }
}
