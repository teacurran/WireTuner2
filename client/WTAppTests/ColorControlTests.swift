import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// COLOR-017: the Color Control sheet's preview (the canvas changes, the document does not),
/// Cancel and Apply, a remote change under the preview, and the Extensions menu's colour entries.
@Suite @MainActor struct ColorControlTests {
    /// The fill colour of the first object's display item as the canvases draw it.
    static func drawnFill(_ document: DocumentHandle, _ id: SelectionID) -> RenderColor? {
        let node = id.node
        guard let index = document.displayList.nodeIDs.firstIndex(of: node), case .path(let item) = document.displayList.items[index],
              case .fill(let fill)? = item.appearance.items.first, case .solid(let color) = fill.paint else { return nil }
        return color
    }

    static func storedFill(_ fixture: AttributeFixture) -> Wiretuner_Doc_V1_ColorRef {
        fixture.stack()[0].fill.settings.basic.color
    }

    @Test func previewDrawsWithoutWritingAndCancelRestores() async throws {
        let fixture = await AttributeFixture.make()
        let document = fixture.document
        let model = ColorControlModel(document: document, nodes: fixture.ids.map(\.opID))
        let before = try #require(Self.drawnFill(document, fixture.ids[0]))
        let stored = Self.storedFill(fixture)
        let undoable = document.canUndo
        #expect(ColorControlModel.components(.cmyk).count == 4 && ColorControlModel.components(.rgb).count == 3)
        model.setValue(1, -50)
        #expect(document.isPreviewing && model.values.y == -50 && model.deltas.y == -0.5)
        let previewed = try #require(Self.drawnFill(document, fixture.ids[0]))
        #expect(previewed != before && Self.storedFill(fixture) == stored && document.canUndo == undoable, "nothing written")
        // A remote change to the object redraws with the preview still over it.
        try await fixture.receive(AddAppearance.stroke(fixture.ids.map(\.opID)))
        #expect(document.isPreviewing && Self.drawnFill(document, fixture.ids[0]) == previewed)
        model.setPreviewing(false)
        #expect(!document.isPreviewing && Self.drawnFill(document, fixture.ids[0]) == before)
        model.setPreviewing(true)
        model.setValue(0, 999)
        #expect(model.values.x == 360)
        ColorControlSheet.cancelling(model) {}()
        #expect(!document.isPreviewing && Self.drawnFill(document, fixture.ids[0]) == before && Self.storedFill(fixture) == stored)
        // Switching modes starts again from no change.
        model.setMode(.rgb)
        model.setMode(.rgb)
        #expect(model.values == SIMD4(repeating: 0) && !document.isPreviewing && model.deltas == SIMD4(repeating: 0))
        #expect(model.apply() == nil, "nothing to apply")
        AttributeFixture.render(ColorControlSheet(model: model) {})
    }

    @Test func applyWritesOneChange() async throws {
        let fixture = await AttributeFixture.make()
        let document = fixture.document
        let model = ColorControlModel(document: document, nodes: fixture.ids.map(\.opID))
        ColorControlSheet.mode(model).wrappedValue = .cmyk
        ColorControlSheet.value(3, model).wrappedValue = 40
        ColorControlSheet.preview(model).wrappedValue = true
        #expect(ColorControlSheet.mode(model).wrappedValue == .cmyk && ColorControlSheet.value(3, model).wrappedValue == 40 && ColorControlSheet.preview(model).wrappedValue)
        let stored = Self.storedFill(fixture)
        var closed = 0
        ColorControlSheet.applying(model) { closed += 1 }()
        await document.settle()
        #expect(closed == 1 && !document.isPreviewing && Self.storedFill(fixture) != stored && document.undoTitle == "Undo Adjust colors")
        // A preview that writes nothing (a command that fails) shows the document.
        document.preview(AdjustColors([OpID(counter: 999, replica: 999)], .lighten))
        #expect(!document.isPreviewing)
        document.preview(nil)
    }

    @Test func theExtensionsColorsEntriesRunOnTheSelection() async throws {
        let fixture = await AttributeFixture.make()
        let editing = ObjectEditing(document: fixture.document, selection: SelectionController(document: fixture.document))
        let presenter = SheetPresenter()
        presenter.present = { _ in }
        let features = EffectFeatures(target: { editing }, sheets: presenter)
        let registry = ExtensionRegistry()
        features.install(commands: CommandRegistry(), tools: ToolRegistry(), extensions: registry)
        let colorControl = try #require(registry.descriptor(for: "colorControl"))
        #expect(registry.validation(of: colorControl).reason == ObjectMenuCommands.noSelection)
        #expect(!features.colorControlMenuItem().isEnabled)
        editing.selection.model.set(Selection(fixture.ids))
        #expect(registry.validation(of: colorControl).isEnabled && features.colorControlMenuItem().isEnabled)
        #expect(registry.perform("colorControl") && presenter.sheets[ColorControlModel.sheet] != nil)
        features.colorControlMenuItem().action()
        let before = Self.storedFill(fixture)
        for id in ["lightenColors", "darkenColors", "saturateColors", "desaturateColors", "convertToGrayscale", "randomizeNamedColors"] {
            #expect(registry.perform(id), "\(id)")
            await fixture.document.settle()
        }
        #expect(Self.storedFill(fixture) != before && fixture.document.canUndo)
        let none = EffectFeatures(target: { nil }, sheets: presenter)
        #expect(none.extensionDescriptors(existing: registry).allSatisfy { $0.validate?().reason == BlendMenu.noDocument })
        none.showCreateBrush()
        none.showBlendSteps([])
        #expect(presenter.sheets[EffectFeatures.createBrush] == nil && presenter.sheets[EffectFeatures.blendSteps] == nil)
        _ = none.extensionDescriptors(existing: registry).map { $0.run?(nil) }
    }
}
