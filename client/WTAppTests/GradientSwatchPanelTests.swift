import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// ATTR-029's gradient swatches in the Swatches panel: listed after the colours with chips, a
/// ramp dragged from the gradient form adds one, a click with objects selected applies it.
@Suite(.serialized) @MainActor struct GradientSwatchPanelTests {
    @MainActor
    final class Fixture {
        let attributes: AttributeFixture
        let selectionModel = SelectionModel()
        let workspace: ColorWorkspace
        let panel: SwatchesPanelModel

        init(_ attributes: AttributeFixture) {
            self.attributes = attributes
            workspace = ColorWorkspace(selection: ActiveSelection(model: selectionModel, document: attributes.document))
            panel = SwatchesPanelModel(workspace: workspace)
        }

        var document: DocumentHandle { attributes.document }
        var state: EngineState { document.state }

        func select(_ ids: [OpID]) {
            selectionModel.set(Selection(ids.map(SelectionID.init)))
        }
    }

    @Test func aRampDropAddsASwatchAndAClickAppliesIt() async throws {
        let f = Fixture(await GradientEditorTests.fixture())
        let editor = GradientEditorTests.model(f.attributes)
        let target = try #require(editor.target)
        #expect(f.panel.gradientSwatches.isEmpty)
        // The ramp's handle carries the object and its fill.
        let provider = GradientRampHandle.dragging(editor)()
        #expect(provider.hasItemConformingToTypeIdentifier(GradientRampDrag.typeIdentifier))
        let ramp = GradientRampDrag(document: f.document.id, node: target.node, row: target.row)
        #expect(GradientRampDrag(data: ramp.data) == ramp && GradientRampDrag(data: Data("1\n2".utf8)) == nil)
        // Dropped below the list: a gradient swatch.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.ramp.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(!f.panel.dropRamp(from: pasteboard))
        pasteboard.declareTypes([GradientRampDrag.type], owner: nil)
        pasteboard.setData(ramp.data, forType: GradientRampDrag.type)
        #expect(f.panel.drop(from: pasteboard, on: nil))
        #expect(await eventually { f.panel.gradientSwatches.count == 1 })
        let swatch = try #require(f.panel.gradientSwatches.first)
        #expect(swatch.name == "Gradient" && f.document.undoTitle == "Undo Add gradient swatch")
        #expect(f.panel.gradientChip(swatch.id) != nil && f.panel.gradientChip(OpID(counter: 999, replica: 9)) == nil)
        // Another document's ramp, or a fill that is no gradient, adds nothing.
        #expect(f.panel.dropRamp(GradientRampDrag(document: "elsewhere", node: target.node, row: target.row)) == nil)
        #expect(f.panel.dropRamp(GradientRampDrag(document: f.document.id, node: target.node, row: AppearanceRow(.strokes, target.row.element))) == nil)
        // A click with nothing selected does nothing; with the object selected it applies.
        #expect(f.panel.clickGradient(swatch.id) == nil)
        f.select([target.node])
        _ = await f.panel.clickGradient(swatch.id)?.value
        #expect(f.document.undoTitle == "Undo Apply gradient")
        GradientSwatchRows.clicking(swatch.id, f.panel)()
        await f.document.settle()
        // The views.
        PanelRendering.host(SwatchesPanelBody(model: f.panel))
        PanelRendering.host(GradientChipView(image: nil))
        PanelRendering.host(GradientRampHandle(model: editor))
        AttributeFixture.render(GradientEditorView(model: editor))
        #expect(SwatchesPanelBody.addDropTypes.contains(GradientRampDrag.utType))
        let empty = SwatchesPanelModel(workspace: ColorWorkspace(selection: ActiveSelection()))
        #expect(empty.gradientSwatches.isEmpty && empty.gradientChip(swatch.id) == nil && empty.dropRamp(ramp) == nil)
        // Two objects: the ramp edits one at a time, so its handle carries nothing.
        let two = await AttributeFixture.make(2)
        let both = GradientEditorModel(context: two.context(0, ids: two.ids))
        #expect(both.target == nil && !GradientRampHandle.dragging(both)().hasItemConformingToTypeIdentifier(GradientRampDrag.typeIdentifier))
    }
}
