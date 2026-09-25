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

/// The remaining edges of the effect, colour, library and arrowhead glue: keylines of objects
/// without paths, the Eyedropper's chip cursor, gradient drops on text, the Replace sheet's menu
/// item, the Library panel's options menu and defaults, and the Arrowhead Editor's hooks.
@Suite(.serialized) @MainActor struct UIGlueEdgeTests {
    @Test func keylinesOfTextAndOfAnEmptyGroup() async throws {
        let document = DocumentHandle.memory(title: "Keylines")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        let other = await document.addRectangles([Rect(x: 40, y: 0, width: 10, height: 10)])[0]
        let instance = try #require(await document.perform(ConvertToSymbol([other.opID])).value?.createdObjects.first { document.state.nodeKind($0) == .instance })
        await document.settle()
        let outline = Keylines.contours(of: instance, document: document)
        #expect(outline.count == 1 && outline[0].points.count == 4 && outline[0].closed, "no path: the bounds")
        var props = Wiretuner_Doc_V1_NodeProps()
        props.group.kind = .group
        let empty = await CopyToolTests.node(props, in: document, near: rect.opID)
        #expect(Keylines.contours(of: empty, document: document).isEmpty)
    }

    @Test func theChipCursorDrawsAndAGradientDropsOnText() async throws {
        let image = EyedropperTool.cursor(for: RenderColor(red: 1, green: 0, blue: 0)).image
        #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        #expect(EyedropperTool.cursor(for: nil).image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        let colors = ColorPanelFixture()
        let grape = await colors.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let text = try #require(await colors.document.addText("Grad"))
        let ref = colors.list.resolver.reference(to: grape)
        let bounds = try #require(colors.document.object(for: SelectionID(text))?.bounds)
        let command = try #require(GradientDrop.command(ref, on: text, at: bounds.center, modifiers: [.option], document: colors.document) as? ApplyGradient)
        #expect(command.gradient.type == .radial && command.gradient.stops.last?.color == ColorResolver.inline(.white))
    }

    @Test func theReplaceMenuItemOpensTheSheet() async throws {
        let fixture = ColorPanelFixture()
        let features = ColorFeatures(selection: fixture.selection, preferences: fixture.preferences)
        features.workspace.presentSheet = { _ in }
        features.showReplace()
        #expect(features.workspace.sheets.isEmpty, "nothing selected: no sheet")
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        features.swatchesPanel.select(grape)
        features.replaceMenuItem().action()
        #expect(features.workspace.sheets[ReplaceSwatchModel.sheet] != nil)
        let loose = ReplaceSwatchModel(workspace: ColorWorkspace(selection: ActiveSelection()), swatch: grape, libraries: [])
        #expect(loose.isOwn(try #require(fixture.list[grape])), "no list: everything is its own")
        let library = ReplaceSwatchModel(workspace: fixture.workspace, swatch: grape, libraries: BundledColorLibraries.all)
        library.source = .library
        ColorPanelFixture.render(ReplaceSwatchSheet(model: library))
    }

    @Test func theLibraryOptionsMenuRunsAndItsDefaults() async throws {
        let f = SymbolLibraryPanelTests.Fixture()
        let bare = SymbolLibraryModel(selection: f.selection)
        bare.present(bare)
        bare.dismiss()
        let rect = await f.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)])[0]
        f.select([rect.opID])
        await f.settle(f.model.newSymbol())
        let symbol = try #require(f.model.rows.first?.id)
        // Unnamed: "Symbol"; a folder renames through the same command.
        _ = await f.document.perform(RenameLibraryEntry(node: symbol, name: "")).value
        #expect(f.model.rows.first?.name == "Symbol")
        await f.settle(f.model.newFolder())
        let folder = try #require(f.model.rows.first { $0.kind == .folder }).id
        _ = await f.document.perform(RenameLibraryEntry(node: folder, name: "Icons")).value
        #expect(f.model.rows.contains { $0.name == "Icons" })
        f.model.beginRename(OpID(counter: 5, replica: 5))
        #expect(f.model.renameText.isEmpty)
        // Every options menu item runs.
        let instance = try #require(f.instances.first)
        f.select([instance])
        f.model.click(symbol)
        for item in f.model.optionsMenu() where !item.title.hasPrefix("Hide") { item.action() }
        await f.document.settle()
        // A folder holding a used symbol asks before removing.
        await f.settle(f.model.newFolder())
        let holder = try #require(f.model.rows.first { $0.kind == .folder && $0.id != folder }).id
        let used = try #require(f.model.rows.first { $0.kind == .symbol && $0.count > 0 }).id
        f.model.click(used)
        await f.settle(f.model.move(to: holder))
        f.model.click(holder)
        let presented = f.presented
        #expect(f.model.remove() == nil && f.presented == presented + 1)
        f.model.cancelRemove()
        // Place with no window's editing: at the origin.
        let windowless = SymbolLibraryModel(selection: ActiveSelection(model: f.controller.selection.model, document: f.document))
        windowless.click(used)
        await f.settle(windowless.place())
        PanelRendering.host(SymbolLibraryPanelBody(model: windowless))
        SymbolLibraryPanelBody.clicking(used, windowless)()
    }

    @Test func theArrowheadEditorsHooks() async throws {
        ArrowheadEditing.tools = ArrowheadEditorTests.registry()
        ArrowheadEditing.present = { _ in }
        var finished: [Wiretuner_Doc_V1_Arrowhead?] = []
        let editor = try #require(ArrowheadEditing.open(loading: nil) { finished.append($0) })
        editor.canvas.presenceDrawer?(DrawingToolTests.bitmap())
        _ = await editor.model.document.addText("Not a path")
        #expect(editor.model.contours.isEmpty, "text is not part of the head")
        editor.cancel()
        #expect(finished.count == 1 && finished[0] == nil)
    }
}
