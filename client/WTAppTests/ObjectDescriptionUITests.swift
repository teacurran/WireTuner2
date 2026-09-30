import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Replace tab's object attributes (OBJ-023) and the Alt text and Decorative fields (OBJ-040).
@Suite(.serialized) @MainActor struct ObjectDescriptionUITests {
    // MARK: Find & Replace (OBJ-023)

    @Test func theReplaceTabChangesColorsWidthsAndTransformsInOneStep() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 100, y: 0, width: 20, height: 20),
                                                      Rect(x: 300, y: 0, width: 20, height: 40)])
        let nodes = ids.map(\.opID)
        let list = SwatchList(world.state)
        let black = try #require(list.swatches.first { $0.role == .black })
        let selection = ActiveSelection(model: world.window.selection.model, document: world.document)
        selection.editing = world.window.objectEditing
        let state = FindReplaceState()
        state.select(.replace)
        state.attribute = .color
        #expect(state.attribute.title == "Color" && FindReplaceState.Attribute.replaceStrokeWidth.graphicAttribute == .strokeWidth)
        // Incomplete From/To: nothing.
        _ = state.change(selection)
        #expect(state.result == "Fill in From and To")
        let whiteRef = try #require(world.state.props(nodes[0]).rect.appearance.fills.first?.settings.basic.color)
        let blackRef = list.resolver.reference(to: black.id)
        state.graphics.from = whiteRef
        state.graphics.to = blackRef
        let body = FindReplacePanelBody(selection: selection, state: state)
        PanelRendering.host(body)
        body.change()
        await state.graphics.running?.value
        await world.document.settle()
        #expect(state.result == "3 objects changed" && world.document.undoTitle == "Undo Replace color in 3 objects")
        #expect(AttributeQuery(.color(blackRef), in: .document).run(in: world.state).count == 3)
        _ = await world.document.undo().value
        #expect(AttributeQuery(.color(whiteRef), in: .document).run(in: world.state).count == 3, "one undo step")
        // Stroke width with arithmetic, in the selection only.
        world.window.selection.model.set(Selection([ids[0]]))
        state.attribute = .replaceStrokeWidth
        state.scope = .selection
        state.graphics.newWidth = "*4"
        PanelRendering.host(body)
        _ = state.change(selection)
        await state.graphics.running?.value
        #expect(AttributeQuery(.strokeWidth(.exactly(4)), in: .document).run(in: world.state) == [nodes[0]])
        // Rotate each object about its own centre.
        let centres = nodes.map { Objects.bounds(of: $0, in: world.state)!.center }
        state.scope = .document
        state.attribute = .rotate
        state.graphics.angle = "90"
        PanelRendering.host(body)
        _ = state.change(selection)
        await state.graphics.running?.value
        for (node, centre) in zip(nodes, centres) {
            let after = Objects.bounds(of: node, in: world.state)!.center
            #expect(abs(after.x - centre.x) < 1e-6 && abs(after.y - centre.y) < 1e-6)
        }
        #expect(Objects.bounds(of: nodes[2], in: world.state)!.width > 39, "the tall one turned on its side: \(state.result ?? "")")
        // The other attributes' edits.
        let graphics = state.graphics
        graphics.scaleX = "200"
        #expect(graphics.edit(.scale) == .scale(x: 200, y: 200))
        graphics.uniform = false
        graphics.scaleY = "50"
        #expect(graphics.edit(.scale) == .scale(x: 200, y: 50))
        graphics.scaleX = "x"
        #expect(graphics.edit(.scale) == nil)
        graphics.points = "20"
        #expect(graphics.edit(.simplify) == .simplify(points: 20, amount: 50))
        graphics.points = ""
        #expect(graphics.edit(.simplify) == nil)
        graphics.newSteps = "+2"
        graphics.minSteps = "3"
        #expect(graphics.edit(.blendSteps) == .blendSteps(ValueRange(min: 3, max: nil), to: .add(2)))
        graphics.newSteps = ""
        #expect(graphics.edit(.blendSteps) == nil && graphics.edit(.remove) == .remove(.invisible))
        // *Resample at* the printer resolution needs no number (D-090).
        graphics.resample = true
        #expect(graphics.edit(.blendSteps) == .resampleBlends(ValueRange(min: 3, max: nil)))
        PanelRendering.host(Form { GraphicReplaceFields(state: graphics, attribute: .blendSteps, swatches: list.swatches, resolver: list.resolver) })
        graphics.resample = false
        graphics.newWidth = "?"
        graphics.angle = ""
        #expect(graphics.edit(.strokeWidth) == nil && graphics.edit(.rotate) == nil)
        graphics.minWidth = "1"
        graphics.newWidth = "2"
        #expect(graphics.edit(.strokeWidth) == .strokeWidth(ValueRange(min: 1, max: 1), to: .set(2)))
        // Page scope and nothing matched.
        state.scope = .page
        state.attribute = .remove
        graphics.remove = .halftones
        _ = state.change(selection)
        #expect(state.result == "0 objects changed" && graphics.running == nil || state.result == "0 objects changed")
        #expect(graphics.change(.remove, scope: .page, selection: nil) == nil)
        for attribute in GraphicReplaceState.Attribute.allCases {
            PanelRendering.host(Form { GraphicReplaceFields(state: graphics, attribute: attribute, swatches: list.swatches, resolver: list.resolver) })
            #expect(!attribute.title.isEmpty && attribute.id == attribute.rawValue)
        }
    }

    @Test func aReplaceOverTheOpLimitIsOneUndoStep() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles((0..<4).map { Rect(x: Double($0) * 30, y: 0, width: 20, height: 20) })
        let parts = ReplaceGraphics.chunks(.rotate(10), candidates: ids.map(\.opID), limit: 1, in: world.state)
        #expect(parts.count == 4)
        let selection = ActiveSelection(model: world.window.selection.model, document: world.document)
        let graphics = GraphicReplaceState()
        graphics.angle = "10"
        // Performing the parts in one group.
        world.document.beginGroup()
        for part in parts { _ = await world.document.perform(part).value }
        await world.document.settle()
        world.document.endGroup()
        #expect(world.document.undoTitle.hasPrefix("Undo Replace rotation in 4 objects"))
        _ = graphics.change(.rotate, scope: .document, selection: selection)
        await graphics.running?.value
        #expect(graphics.result == "4 objects changed")
    }

    @Test func theColorWellsTakeSwatchesAndDrops() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let list = SwatchList(world.state)
        var value: Wiretuner_Doc_V1_ColorRef?
        let binding = Binding(get: { value }, set: { value = $0 })
        let well = GraphicReplaceFields.colorBinding(binding, swatches: list.swatches, resolver: list.resolver)
        #expect(well.wrappedValue == GraphicReplaceFields.none)
        well.wrappedValue = list.swatches[0].name
        #expect(well.wrappedValue == list.swatches[0].name)
        well.wrappedValue = "not a swatch"
        value = ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0))
        #expect(well.wrappedValue == "Color")
        #expect(!GraphicReplaceFields.dropping(into: binding)([]))
        let payload = ColorRefPasteboard(ref: list.resolver.reference(to: list.swatches[1].id), color: list.swatches[1].color)
        #expect(GraphicReplaceFields.dropping(into: binding)([ColorDrag.itemProvider(payload)]))
        try await Task.sleep(for: .milliseconds(200))
        #expect(value == payload.ref)
        var shown = 0
        let command = GraphicReplaceCommands.command { shown += 1 }
        #expect(command.defaultKey == KeyEquivalent("f", [.command, .option]))
        if case .perform(let run) = command.action { run() }
        #expect(shown == 1)
    }

    // MARK: Alt text (OBJ-040)

    @Test func altTextAndDecorativeOnTheRootRow() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 50, y: 0, width: 20, height: 20)])
        let model = ObjectPanelModel(document: world.document, selection: Selection(ids))
        let section = try #require(model.description)
        #expect(section.alt == "" && section.decorative == .off && !section.readsAsText)
        DescriptionFieldsView.alt(model)("Two squares")
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Change alt text of 2 objects")
        let decorative = DescriptionFieldsView.decorative(section, model)
        #expect(!decorative.wrappedValue)
        decorative.wrappedValue = true
        await world.document.settle()
        let after = try #require(ObjectPanelModel(document: world.document, selection: Selection(ids)).description)
        #expect(after.alt == "Two squares" && after.decorative == .on, "ticking Decorative keeps the alt text")
        PanelRendering.host(Form { DescriptionFieldsView(section: after, model: model) })
        PanelRendering.host(CommonSectionView(section: try #require(model.common), model: model))
        // Mixed values and a text block.
        _ = await world.document.perform(SetAlt([ids[0].opID], alt: "One")).value
        #expect(ObjectPanelModel(document: world.document, selection: Selection(ids)).description?.alt == nil)
        let text = try await world.block("Caption")
        let textModel = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(text)]))
        let textSection = try #require(textModel.description)
        #expect(textSection.readsAsText)
        PanelRendering.host(Form { DescriptionFieldsView(section: textSection, model: textModel) })
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).description == nil)
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).setAlt("x") == nil)
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).setDecorative(true) == nil)
        // VoiceOver's description of the selection.
        world.window.selection.model.set(Selection([SelectionID(text), ids[0], ids[1]]))
        #expect(CanvasDescriptions.description(of: world.window.selection.selection, in: world.state) == "Caption")
        _ = await world.document.perform(SetDecorative([ids[0].opID], decorative: false)).value
        CanvasDescriptions.update(world.window)
        #expect(world.window.canvas.accessibilityHelp() == "One; Caption" || world.window.canvas.accessibilityHelp() == "Caption; One")
    }
}
