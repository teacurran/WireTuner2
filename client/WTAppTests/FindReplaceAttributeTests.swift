import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Find & Replace attributes OBJ-023 left out (*Include tints*, *Remove > Overprinting* and
/// *Contents*, *Path shape* with *Paste In*; the Select tab's *Color*, *Style*, *Fill type* and
/// *Stroke type*), a text style dropped from the Styles panel (TYPE-035) and *Show text handles
/// when ruler is off* (TYPE-010).
@Suite(.serialized) @MainActor struct FindReplaceAttributeTests {
    /// A pasteboard holding one payload.
    final class Held: ObjectPasteboard {
        var bytes: [UInt8]?
        func write(_ payload: [UInt8]) { bytes = payload }
        func read() -> [UInt8]? { bytes }
    }

    static func active(_ world: TypeWorld) -> ActiveSelection {
        ActiveSelection(model: world.window.selection.model, document: world.document, editing: world.window.objectEditing)
    }

    @Test func theReplaceTabTakesTintsRemovalsAndPastedShapes() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let held = Held()
        world.window.objectEditing.pasteboard = held
        let active = Self.active(world)
        let state = FindReplaceState()
        state.select(.replace)
        #expect(FindReplaceState.Attribute.available(in: .replace).contains(.replacePathShape))
        #expect(FindReplaceState.Attribute.replacePathShape.graphicAttribute == .pathShape && FindReplaceState.Attribute.replacePathShape.title == "Path shape")
        let graphics = state.graphics
        // *Include tints* rides on the colour edit.
        let list = SwatchList(world.state)
        graphics.from = list.resolver.reference(to: list.swatches[0].id)
        graphics.to = list.resolver.reference(to: list.swatches[1].id)
        graphics.includeTints = true
        #expect(graphics.edit(.color) == .color(from: graphics.from!, to: graphics.to!, tints: true))
        // *Remove* offers overprinting and contents.
        graphics.remove = .overprinting
        #expect(graphics.edit(.remove) == .remove(.overprinting))
        // *Path shape*: nothing until both are pasted in; the sample must be a path or shape.
        state.attribute = .replacePathShape
        #expect(graphics.edit(.pathShape) == nil)
        #expect(!graphics.pasteIn(FindReplacePanelBody.pasted(active), asSample: true) && graphics.result == "Copy an object first")
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 100, y: 0, width: 20, height: 20),
                                                      Rect(x: 300, y: 0, width: 40, height: 10)])
        let group = try #require(await world.document.perform(GroupObjects([ids[2].opID])).value?.createdObjects.first)
        held.bytes = ClipboardPayload(copying: [group], from: world.state).encoded()
        #expect(!graphics.pasteIn(FindReplacePanelBody.pasted(active), asSample: true) && graphics.result == "The sample must be a path or a shape")
        #expect(GraphicReplaceFields.pathShapeNote(graphics) == "Copy the sample and Paste In beside From")
        held.bytes = ClipboardPayload(copying: [ids[2].opID], from: world.state).encoded()
        #expect(graphics.pasteIn(FindReplacePanelBody.pasted(active), asSample: false) && graphics.result == nil)
        #expect(GraphicReplaceFields.pathShapeNote(graphics) == "Replacement pasted; copy the sample and Paste In beside From")
        held.bytes = ClipboardPayload(copying: [ids[0].opID], from: world.state).encoded()
        #expect(graphics.pasteIn(FindReplacePanelBody.pasted(active), asSample: true))
        #expect(GraphicReplaceFields.pathShapeNote(graphics) == "Sample and replacement pasted")
        graphics.pastedTo = nil
        #expect(GraphicReplaceFields.pathShapeNote(graphics) == "Sample pasted; copy the replacement and Paste In beside To")
        graphics.pastedTo = ClipboardPayload(copying: [ids[2].opID], from: world.state)
        graphics.fit = true
        // btn:[Change]: both squares become fitted copies of the bar in one step.
        state.scope = .document
        _ = state.change(active)
        await graphics.running?.value
        await world.document.settle()
        #expect(state.result == "2 objects changed")
        #expect(!world.state.isLive(ids[0].opID) && !world.state.isLive(ids[1].opID))
        #expect(world.document.undoTitle == "Undo Replace path shape in 2 objects")
        // The fields render with every remove target and the path shape rows.
        for target in GraphicEdit.RemoveTarget.allCases {
            graphics.remove = target
            PanelRendering.host(Form { GraphicReplaceFields(state: graphics, attribute: .remove, swatches: list.swatches, resolver: list.resolver) })
        }
        PanelRendering.host(Form {
            GraphicReplaceFields(state: graphics, attribute: .pathShape, swatches: list.swatches, resolver: list.resolver, paste: { FindReplacePanelBody.pasted(active) })
        })
        Render.view(FindReplacePanelBody(selection: active, state: state))
    }

    @Test func theSelectTabFindsByColorStyleFillAndStrokeTypeAndAPastedShape() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let held = Held()
        world.window.objectEditing.pasteboard = held
        let active = Self.active(world)
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 100, y: 0, width: 20, height: 20)])
        let plain = try #require(await world.document.addPath([Point(x: 200, y: 0), Point(x: 260, y: 0), Point(x: 230, y: 40)], closed: true))
        let state = FindReplaceState()
        state.select(.select)
        let available = FindReplaceState.Attribute.available(in: .select)
        #expect([.selectColor, .style, .fillType, .strokeType].allSatisfy(available.contains) && !available.contains(.replacePathShape))
        #expect(FindReplaceState.Attribute.selectColor.objectAttribute == .color && FindReplaceState.Attribute.selectColor.title == "Color")
        // Color: nothing to find until a colour is chosen.
        state.attribute = .selectColor
        #expect(state.find(active).isEmpty && state.result == "Nothing to find")
        let entry = try #require(AppearanceEditing.entries(ids[0].opID, in: world.state).first { $0.kind == .fill(.basic) })
        state.objects.color = AttributeFields.color(entry)
        #expect(Set(state.find(active)) == Set(ids.map(\.opID)))
        // Fill and stroke type.
        state.attribute = .fillType
        state.objects.fillType = .basic
        #expect(Set(state.find(active)) == Set(ids.map(\.opID)))
        state.objects.fillType = .gradient
        #expect(state.find(active).isEmpty)
        state.attribute = .strokeType
        state.objects.strokeType = .basic
        #expect(state.find(active).contains(plain.opID))
        // Style: the graphic styles and then the text styles are offered.
        state.attribute = .style
        #expect(state.find(active).isEmpty && state.result == "Nothing to find")
        _ = await world.document.perform(CreateNormalTextStyle()).value
        let styles = ObjectAttributeSearch.styles(in: world.state)
        let normal = try #require(world.state.textStyles.normalText)
        #expect(styles.contains { $0.id == normal })
        let block = try await world.block("styled")
        state.objects.style = normal
        _ = state.find(active)
        #expect(state.result != "Nothing to find")
        _ = block
        // Path shape: a pasted sample, which is not in the document, finds the copies too.
        state.attribute = .pathShape
        #expect(!state.objects.pasteSample(nil))
        held.bytes = ClipboardPayload(copying: [ids[0].opID], from: world.state).encoded()
        #expect(state.objects.pasteSample(FindReplacePanelBody.pasted(active)))
        world.window.selection.model.set(Selection([ids[0]]))
        #expect(Set(state.find(active)) == Set(ids.map(\.opID)), "the selected object is found: the sample is the pasted one")
        // Every Select-tab field renders.
        let list = SwatchList(world.state)
        for attribute in ObjectAttributeSearch.Attribute.allCases {
            Render.view(ObjectAttributeFields(search: state.objects, attribute: attribute, swatches: list.swatches, resolver: list.resolver, styles: styles,
                                              paste: { FindReplacePanelBody.pasted(active) }))
            #expect(!attribute.title.isEmpty)
        }
        #expect(ObjectAttributeSearch.fillTitles.count == 7 && ObjectAttributeSearch.strokeTitles.count == 5)
        for attribute in FindReplaceState.Attribute.available(in: .select) {
            state.attribute = attribute
            Render.view(FindReplacePanelBody(selection: active, state: state))
        }
    }

    @Test func aTextStyleDroppedOnTheCanvasStylesTheTextUnderIt() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("One\nTwo")
        _ = await world.document.perform(CreateTextStyle(.paragraph, attrs: .init())).value
        let style = try #require(world.state.textStyles.styles(.paragraph).first { !$0.isNormalText })
        let drop = try #require(world.window.canvas.styleDrop)
        #expect(drop.textDrop != nil, "the window routes text styles")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uip.style.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(StyleDrag(document: world.document.id, style: style.id).data, forType: StyleDrag.type)
        let bounds = try #require(world.document.object(for: SelectionID(node))?.bounds)
        let viewPoint = world.window.viewport.toView(Point(x: bounds.minX + 3, y: bounds.minY + 3))
        _ = await drop.drop(pasteboard, at: viewPoint, viewport: world.window.viewport)?.value
        let paragraphs = try #require(world.state.textNode(node)).paragraphs
        #expect(world.state.textStyles.paragraphStyle(paragraphs[0].props).style == style.id)
        // Off text nothing happens; without the window's hook a text style is not a graphic style.
        #expect(drop.drop(pasteboard, at: Point(x: -5000, y: -5000), viewport: world.window.viewport) == nil)
        let bare = StyleCanvasDrop(document: world.document, selection: world.window.selection)
        #expect(bare.drop(pasteboard, at: viewPoint, viewport: world.window.viewport) == nil)
    }

    @Test func textHandlesHideWithTheRulerWhenThePreferenceIsOff() async throws {
        let world = TypeWorld()
        defer { world.close() }
        #expect(TextBlockHandles.hiddenBlock(rulersShown: true, showHandles: false, editing: OpID(counter: 1, replica: 1)) == nil)
        #expect(TextBlockHandles.hiddenBlock(rulersShown: false, showHandles: true, editing: OpID(counter: 1, replica: 1)) == nil)
        #expect(TextBlockHandles.hiddenBlock(rulersShown: false, showHandles: false, editing: OpID(counter: 1, replica: 1)) == OpID(counter: 1, replica: 1))
        let preferences = world.setup.environment.preferences
        let rulers = TypeWindowParts.attach(world.window, preferences: preferences).rulers
        let parts = ExtrasWindowParts.attach(world.window)
        let node = try await world.block("handles")
        let context = world.window.toolManager.context
        #expect(parts.handles.frames(context).count == 1, "not editing: shown")
        await world.edit(node, select: 0..<0)
        #expect(parts.handles.frames(context).count == 1, "the preference is on by default")
        let shown = rulers.isShown
        defer { rulers.isShown = shown }
        rulers.isShown = false
        _ = preferences.set(false, for: PreferenceCatalog.Text.handlesWithoutRuler)
        defer { _ = preferences.set(true, for: PreferenceCatalog.Text.handlesWithoutRuler) }
        #expect(parts.handles.frames(context).isEmpty, "ruler off and the preference off: hidden while editing")
        rulers.isShown = true
        #expect(parts.handles.frames(context).count == 1)
    }
}
