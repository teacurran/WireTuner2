import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// LIB-020's Styles panel over LIB-019's commands: the list with previews, counts, highlights and
/// plus signs, clicks, drops, renaming, the options menu and its sheets, and styles dropped on the
/// canvas.
@Suite(.serialized) @MainActor struct StylesPanelTests {
    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Styles")
        let controller: SelectionController
        let editing: ObjectEditing
        let selection: ActiveSelection
        let model: StylesPanelModel
        var sheets: [NSWindow] = []
        var autoApply = true

        init() {
            controller = SelectionController(document: document)
            editing = ObjectEditing(document: document, selection: controller)
            selection = ActiveSelection(model: controller.model, document: document, editing: editing)
            model = StylesPanelModel(selection: selection)
            model.presenter.present = { [unowned self] window in self.sheets.append(window) }
            model.autoApply = { [unowned self] in self.autoApply }
        }

        var state: EngineState { document.state }

        func select(_ ids: [OpID]) {
            controller.model.set(Selection(ids.map(SelectionID.init)))
        }

        func settle(_ task: Task<Wiretuner_Doc_V1_Change?, Never>?) async {
            _ = await task?.value
            await document.settle()
        }

        func rect(_ x: Double = 0) async -> OpID {
            await document.addRectangles([Rect(x: x, y: 0, width: 20, height: 20)])[0].opID
        }

        func row(_ name: String) -> StylesPanelModel.Row? { model.rows.first { $0.name == name } }

        func style(_ name: String) throws -> OpID { try #require(row(name)).id }

        /// Gives `object` its own fill (an override of a style that governs fills).
        func recolor(_ object: OpID, red: Double = 1) async {
            _ = await document.perform(AddAppearance.fill([object], Appearances.basicFill(red: red, green: 0, blue: 0))).value
            await document.settle()
        }
    }

    @Test func theListShowsNormalNewStylesPreviewsCountsAndHighlights() async throws {
        let f = Fixture()
        await f.document.settle()
        let normal = try #require(f.row("Normal"))
        #expect(f.model.rows.count == 1 && normal.isNormal && normal.isHighlighted && !normal.isModified && normal.count == 0)
        #expect(f.model.textRows.map(\.name) == ["Normal Text"])
        #expect(f.model.targetStyle == normal.id, "the defaults mirror Normal")
        let rect = await f.rect()
        f.select([rect])
        await f.settle(f.model.newStyle())
        #expect(f.document.undoTitle == "Undo New style")
        let style = try #require(f.row("Style 1"))
        #expect(style.count == 1 && style.isHighlighted && !style.isModified, "auto-applied to the selected object")
        #expect(!(try #require(f.row("Normal"))).isHighlighted)
        #expect(f.model.targetStyle == style.id, "the selected object's style")
        // Previews are cached until the look or the view changes.
        let compact = try #require(f.model.preview(style.id))
        #expect(f.model.preview(style.id) === compact && compact.width == Int(StylePreview.compact.width * 2))
        f.model.setView(.large)
        #expect(f.model.preview(style.id)?.width == Int(StylePreview.large.width * 2))
        #expect(StylesPanelModel.ViewMode.allCases.map(\.title) == ["Compact List View", "Large List View", "Previews Only"])
        // Without auto-apply the object keeps its style.
        f.autoApply = false
        await f.settle(f.model.newStyle())
        #expect(f.row("Style 2")?.count == 0 && f.row("Style 1")?.count == 1)
        // An empty panel without a document.
        let empty = StylesPanelModel(selection: ActiveSelection())
        #expect(empty.rows.isEmpty && empty.textRows.isEmpty && empty.targetStyle == nil && empty.preview(style.id) == nil)
        #expect(empty.newStyle() == nil && empty.newFromNormal() == nil && empty.click(style.id) == nil && empty.drop(.objects, on: nil) == nil)
        #expect(!empty.drop(from: NSPasteboard(name: NSPasteboard.Name("wiretuner.test.styles.\(UUID().uuidString)")), on: nil))
        empty.beginRedefine()
        empty.beginRemoveUnused()
        #expect(empty.redefinition == nil && f.sheets.isEmpty)
        // A preview of something that is no style shows the defaults.
        #expect(StylePreview.appearance(of: rect, resolver: GraphicStyleResolver(f.state), state: f.state) == DocumentDefaults.appearance(in: f.state))
        // A panel without the window's object commands performs on the document.
        let plain = StylesPanelModel(selection: ActiveSelection(model: f.controller.model, document: f.document))
        await f.settle(plain.click(style.id))
        #expect(f.document.undoTitle == "Undo Apply style Style 1")
    }

    @Test func aClickAppliesTheStyleOrMakesItTheDefaultsAndPlusSignsFollow() async throws {
        let f = Fixture()
        let first = await f.rect()
        let second = await f.rect(40)
        f.select([first])
        await f.settle(f.model.newStyle())
        let style = try f.style("Style 1")
        let normal = try f.style("Normal")
        // An override on the selected object shows the plus sign; clicking the style removes it.
        await f.recolor(first)
        #expect(f.row("Style 1")?.isModified == true && f.row("Style 1")?.isHighlighted == true)
        await f.settle(f.model.click(style))
        #expect(f.document.undoTitle == "Undo Apply style Style 1" && f.row("Style 1")?.isModified == false)
        // Nothing selected: the click makes the style the default attributes.
        f.select([])
        await f.settle(f.model.click(style))
        #expect(f.document.undoTitle == "Undo Default attributes" && f.row("Style 1")?.isHighlighted == true && f.row("Normal")?.isHighlighted == false)
        #expect(f.model.targetStyle == style)
        // The style changes under the defaults: the plus sign appears beside it.
        await f.recolor(second, red: 0.5)
        await f.settle(f.document.perform(RedefineGraphicStyle(style, from: .object(second), in: f.state)))
        #expect(f.row("Style 1")?.isModified == true)
        await f.settle(f.model.click(normal))
        #expect(f.row("Normal")?.isHighlighted == true && f.row("Style 1")?.isModified == false)
        // A remote redefinition redraws the previews.
        let before = try #require(f.model.preview(style))
        await f.recolor(second, red: 0.1)
        _ = await f.document.receiveRemote(RedefineGraphicStyle(style, from: .object(second), in: f.state))
        #expect(f.model.preview(style) !== before)
    }

    @Test func dropsMakeStylesOrAskToRedefine() async throws {
        let f = Fixture()
        let rect = await f.rect()
        f.select([rect])
        #expect(f.model.drop(.objects, on: nil) != nil)
        await f.document.settle()
        let style = try f.style("Style 1")
        #expect(f.row("Style 1")?.count == 1)
        f.select([])
        #expect(f.model.drop(.objects, on: nil) == nil && f.model.drop(.objects, on: style) == nil, "no object selected")
        // Without auto-apply the dropped object keeps its style.
        let other = await f.rect(60)
        f.select([other])
        f.autoApply = false
        await f.settle(f.model.drop(.objects, on: nil))
        #expect(GraphicStyleResolver(f.state).style(of: other, in: f.state) == nil && f.model.rows.count == 3)
        f.select([])
        // A style dropped on the empty area makes a child of it.
        await f.settle(f.model.drop(.style(style), on: nil))
        let child = try f.style("Style 3")
        #expect(GraphicStyleResolver(f.state).parent(of: child) == style)
        #expect(f.model.drop(.style(style), on: style) == nil && f.sheets.isEmpty, "onto itself")
        // Onto another style: the Redefine sheet asks.
        #expect(f.model.drop(.style(style), on: child) == nil)
        #expect(f.sheets.last?.identifier?.rawValue == StylesPanelModel.Sheet.redefine && f.model.redefinition == .init(style: child, source: .style(style)))
        #expect(f.model.sourceDescription(.style(style)) == "the style \u{201C}Style 1\u{201D}")
        #expect(f.model.sourceDescription(.object(rect)) == "the selected object" && f.model.sourceDescription(.defaults) == "the default attributes")
        f.model.cancelRedefine()
        #expect(f.model.redefinition == nil && f.model.confirmRedefine() == nil)
        // An object dropped on a style redefines it from the object.
        await f.recolor(rect)
        f.select([rect])
        f.model.drop(.objects, on: style)
        await f.settle(f.model.confirmRedefine())
        #expect(f.document.undoTitle == "Undo Redefine style Style 1")
        // *Redefine…* from the defaults with nothing selected.
        f.select([])
        f.model.beginRedefine()
        #expect(f.model.redefinition?.source == .defaults)
        f.model.cancelRedefine()
    }

    @Test func pasteboardDropsTakeThisDocumentsStylesAndObjects() async throws {
        let f = Fixture()
        let rect = await f.rect()
        await f.document.settle()
        let normal = try f.style("Normal")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.styles.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(!f.model.drop(from: pasteboard, on: nil), "nothing on it")
        StyleDrag(document: "elsewhere", style: normal).write(to: pasteboard)
        #expect(!f.model.drop(from: pasteboard, on: nil), "another document's style")
        let payload = try #require(f.model.dragPayload(normal))
        payload.write(to: pasteboard)
        #expect(StyleDrag.read(from: pasteboard) == payload && StyleDrag(data: Data("x".utf8)) == nil)
        #expect(f.model.drop(from: pasteboard, on: nil))
        await f.document.settle()
        #expect(f.row("Style 1") != nil)
        // Objects dragged out of this document's window.
        f.select([rect])
        let objects = ClipboardPayload(copying: [rect], from: f.state, document: f.document.id)
        SystemObjectPasteboard(pasteboard).write(objects.encoded())
        #expect(f.model.drop(from: pasteboard, on: nil))
        await f.document.settle()
        #expect(f.row("Style 2")?.count == 1)
        SystemObjectPasteboard(pasteboard).write(ClipboardPayload(copying: [rect], from: f.state, document: "elsewhere").encoded())
        #expect(!f.model.drop(from: pasteboard, on: nil))
        #expect(payload.itemProvider.hasItemConformingToTypeIdentifier(StyleDrag.typeIdentifier))
    }

    @Test func renamingSurvivesRemoteRedefinitions() async throws {
        let f = Fixture()
        let rect = await f.rect()
        f.select([rect])
        await f.settle(f.model.newStyle())
        let style = try f.style("Style 1")
        f.model.beginRename(style)
        #expect(f.model.renaming == style && f.model.renameText == "Style 1")
        await f.recolor(rect)
        _ = await f.document.receiveRemote(RedefineGraphicStyle(style, from: .object(rect), in: f.state))
        #expect(f.model.renaming == style, "the field stays open")
        f.model.renameText = "Callout"
        await f.settle(f.model.commitRename())
        #expect(f.document.undoTitle == "Undo Rename style" && f.row("Callout") != nil && f.model.renaming == nil)
        f.model.beginRename(style)
        #expect(f.model.commitRename() == nil, "unchanged")
        f.model.beginRename(style)
        f.model.cancelRename()
        #expect(f.model.renaming == nil)
        f.model.setView(.previewsOnly)
        f.model.beginRename(style)
        #expect(f.model.renaming == nil, "no names to edit")
        f.model.setView(.compact)
        f.model.beginRename(OpID(counter: 999, replica: 999))
        #expect(f.model.renaming == nil)
    }

    @Test func theOptionsMenuDuplicatesRemovesAndRemovesUnused() async throws {
        let f = Fixture()
        await f.document.settle()
        let normal = try f.style("Normal")
        func item(_ title: String) -> PanelMenuItem? { f.model.optionsMenu().first { $0.title == title } }
        #expect(f.model.optionsMenu().map(\.title) == ["New", "New from Normal", "Duplicate", "Remove", "Remove Unused", "Redefine…", "Style Behavior…",
                                                        "Import…", "Export…", "Compact List View", "Large List View", "Previews Only"])
        #expect(item("Remove")?.isEnabled == false && item("Import…")?.isEnabled == false && item("Compact List View")?.isEnabled == false)
        item("Style Behavior…")?.action()
        #expect(f.model.behavior?.isNormal == true)
        f.model.cancelBehavior()
        item("Import…")?.action()
        item("Export…")?.action()
        #expect(f.model.remove() == nil, "Normal stays")
        item("New from Normal")?.action()
        await f.document.settle()
        let child = try f.style("Style 1")
        #expect(GraphicStyleResolver(f.state).parent(of: child) == normal)
        f.select([])
        _ = f.model.click(child)
        await f.document.settle()
        item("New")?.action()
        await f.document.settle()
        #expect(GraphicStyleResolver(f.state).parent(of: try f.style("Style 2")) == child, "a child of the style the defaults mirror")
        item("Duplicate")?.action()
        await f.document.settle()
        #expect(f.row("Style 1 copy") != nil)
        _ = f.model.click(try f.style("Style 1 copy"))
        await f.document.settle()
        #expect(item("Remove")?.isEnabled == true)
        item("Remove")?.action()
        await f.document.settle()
        #expect(f.row("Style 1 copy") == nil && f.document.undoTitle == "Undo Remove style Style 1 copy")
        // Remove Unused lists what goes (Normal stays).
        item("Remove Unused")?.action()
        #expect(f.sheets.last?.identifier?.rawValue == StylesPanelModel.Sheet.removeUnused && f.model.unused.count == 2)
        await f.settle(f.model.confirmRemoveUnused())
        #expect(f.model.rows.map(\.name) == ["Normal"] && f.document.undoTitle == "Undo Remove unused styles")
        f.model.beginRemoveUnused()
        #expect(f.model.unused.isEmpty && f.model.confirmRemoveUnused() == nil)
        // The views.
        item("Large List View")?.action()
        #expect(f.model.viewMode == .large)
        item("Previews Only")?.action()
        #expect(f.model.viewMode == .previewsOnly)
        // Objects selected: New takes the object; Duplicate and Remove wait for a deselection.
        let rect = await f.rect()
        f.select([rect])
        #expect(item("Duplicate")?.isEnabled == false && f.model.duplicate() == nil && !f.model.canRemove)
        #expect(f.model.targetStyle == nil, "an object with no style")
        await f.settle(f.model.click(normal))
        item("Redefine…")?.action()
        #expect(f.model.redefinition?.source == .object(rect))
        f.model.cancelRedefine()
        // New from modified defaults.
        f.select([])
        await f.recolor(rect)
        await f.settle(f.document.perform(RedefineGraphicStyle(normal, from: .object(rect), in: f.state)))
        #expect(GraphicStyleDefaults.isModified(in: f.state))
        await f.settle(f.model.newStyle())
        #expect(GraphicStyleResolver(f.state).parent(of: try f.style("Style 1")) == nil, "from the defaults")
    }

    @Test func theStyleBehaviorSheetSetsCategoriesAndParent() async throws {
        let f = Fixture()
        await f.document.settle()
        let normal = try f.style("Normal")
        await f.settle(f.model.newFromNormal())
        let style = try f.style("Style 1")
        await f.settle(f.model.drop(.style(style), on: nil))
        let grandchild = try f.style("Style 2")
        f.select([])
        _ = f.model.click(style)
        await f.document.settle()
        f.model.beginBehavior()
        #expect(f.sheets.last?.identifier?.rawValue == StylesPanelModel.Sheet.behavior)
        #expect(f.model.behavior?.governs == Set(StyleCategory.allCases) && f.model.behavior?.parent == normal)
        #expect(f.model.parentCandidates == [normal], "not itself nor its descendants")
        for category in [StyleCategory.fills, .effects, .halftone] { f.model.toggle(category) }
        f.model.toggle(.strokes)
        #expect(f.model.behavior?.governs == [.strokes], "the last category stays checked")
        f.model.toggle(.fills)
        f.model.setParent(nil)
        await f.settle(f.model.confirmBehavior())
        #expect(f.document.undoTitle == "Undo Style behavior")
        let resolver = GraphicStyleResolver(f.state)
        #expect(resolver.governs(style) == [.fills, .strokes] && resolver.parent(of: style) == nil)
        // Nothing changed: nothing written.
        f.model.beginBehavior()
        #expect(f.model.confirmBehavior() == nil && f.model.confirmBehavior() == nil)
        // Normal takes no parent.
        _ = f.model.click(normal)
        await f.document.settle()
        f.model.beginBehavior()
        f.model.setParent(grandchild)
        #expect(f.model.behavior?.parent == nil && f.model.behavior?.isNormal == true)
        f.model.cancelBehavior()
        #expect(f.model.behavior == nil && f.model.parentCandidates.isEmpty)
        f.model.toggle(.fills)
        f.model.setParent(normal)
        // With an object selected the sheet does not open.
        let rect = await f.rect()
        f.select([rect])
        f.model.beginBehavior()
        #expect(f.model.behavior == nil)
    }

    @Test func textStylesApplyToSelectedTextBlocks() async throws {
        let f = Fixture()
        let text = try #require(await f.document.perform(CreateTextBlock(.point(Point(x: 10, y: 10)), text: "Hi")).value?.createdObjects.first)
        await f.settle(f.document.perform(CreateTextStyle(.character, attrs: Wiretuner_Doc_V1_TextStyleAttrs(), basedOn: nil)))
        let rows = f.model.textRows
        #expect(rows.count == 2 && rows[0].kind == .paragraph && rows[1].kind == .character)
        #expect(f.model.clickText(rows[0]) == nil, "no text selected")
        f.select([text])
        await f.settle(f.model.clickText(rows[0]))
        #expect(f.document.undoTitle == "Undo Apply style")
        await f.settle(f.model.clickText(rows[1]))
        #expect(f.document.undoTitle == "Undo Apply style")
    }

    @Test func aStyleDroppedOnTheCanvasAppliesToTheObjectUnderThePointer() async throws {
        let world = ImportWorld()
        defer { world.close() }
        let document = world.document
        await document.settle()
        let rect = await document.addRectangles([Rect(x: 100, y: 100, width: 40, height: 40)])[0].opID
        _ = await document.perform(CreateGraphicStyle(.normal)).value
        await document.settle()
        let resolver = GraphicStyleResolver(document.state)
        let style = try #require(GraphicStyleFields.styles(in: document.state, resolver).first { resolver.role(of: $0) != .normal })
        let canvas = world.window.canvas
        let drop = try #require(canvas.styleDrop)
        let viewport = canvas.viewport
        let inside = viewport.toView(Point(x: 120, y: 120))
        let outside = viewport.toView(Point(x: 5, y: 5))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.styles.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(!StyleCanvasDrop.carriesStyle(pasteboard) && drop.drop(pasteboard, at: inside, viewport: viewport) == nil)
        StyleDrag(document: document.id, style: style).write(to: pasteboard)
        #expect(drop.target(at: outside, viewport: viewport) == nil)
        #expect(drop.drop(pasteboard, at: outside, viewport: viewport) == nil, "empty pasteboard")
        #expect(drop.target(at: inside, viewport: viewport) == rect)
        // Through the canvas's drop handling.
        let dragging = PasteboardDragging(pasteboard, at: canvas.convert(NSPoint(x: inside.x, y: canvas.bounds.height - inside.y), to: nil))
        #expect(canvas.draggingUpdated(dragging) == .copy)
        #expect(canvas.performDragOperation(dragging))
        #expect(await eventually { GraphicStyleResolver(document.state).style(of: rect, in: document.state) == style })
        canvas.styleDrop = nil
        #expect(canvas.draggingUpdated(dragging) == [] && !canvas.performDragOperation(dragging))
        StyleDrag(document: "elsewhere", style: style).write(to: pasteboard)
        #expect(drop.drop(pasteboard, at: inside, viewport: viewport) == nil)
    }

    @Test func theTrackerFollowsReloadsAndStops() async throws {
        let f = Fixture()
        await f.document.settle()
        let tracker = try #require(f.model.tracker)
        #expect(f.model.tracker === tracker, "one per document")
        let revision = tracker.revision
        await f.document.reload().value
        await f.document.settle()
        #expect(tracker.revision > revision && tracker.index.objects.isEmpty)
        tracker.stop()
        tracker.stop()
        let stopped = tracker.revision
        _ = await f.rect()
        #expect(tracker.revision == stopped)
    }

    @Test func theViewsAndSheetsRender() async throws {
        let f = Fixture()
        let rect = await f.rect()
        f.select([rect])
        await f.settle(f.model.newStyle())
        await f.recolor(rect)
        let style = try f.style("Style 1")
        for mode in StylesPanelModel.ViewMode.allCases {
            f.model.setView(mode)
            PanelRendering.host(StylesPanelBody(model: f.model))
        }
        f.model.setView(.compact)
        f.model.beginRename(style)
        PanelRendering.host(StylesPanelBody(model: f.model))
        PanelRendering.host(StylesPanelBody(model: StylesPanelModel(selection: ActiveSelection())))
        PanelRendering.host(StylePreviewImage(image: nil, size: StylePreview.compact))
        // The closures the views hand to SwiftUI.
        f.model.cancelRename()
        StylesPanelBody.renaming(style, f.model)()
        #expect(f.model.renaming == style)
        f.model.cancelRename()
        StylesPanelBody.clicking(style, f.model)()
        await f.document.settle()
        #expect(f.row("Style 1")?.isModified == false)
        StylesPanelBody.clickingText(try #require(f.model.textRows.first), f.model)()
        let provider = StylesPanelBody.dragging(style, f.model)()
        #expect(provider.hasItemConformingToTypeIdentifier(StyleDrag.typeIdentifier))
        #expect(!StylesPanelBody.dragging(style, StylesPanelModel(selection: ActiveSelection()))().hasItemConformingToTypeIdentifier(StyleDrag.typeIdentifier))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("wiretuner.test.styles.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(!StylesPanelBody.dropping(on: nil, f.model, pasteboard: pasteboard)([]))
        // The sheets.
        f.select([])
        f.model.beginRedefine()
        PanelRendering.host(RedefineStyleSheet(model: f.model))
        let choosing = RedefineStyleSheet.choosing(f.model)
        choosing.wrappedValue = style
        #expect(choosing.wrappedValue == style)
        f.model.cancelRedefine()
        #expect(RedefineStyleSheet.choosing(f.model).wrappedValue == OpID(counter: 0, replica: 0))
        PanelRendering.host(RedefineStyleSheet(model: f.model))
        _ = f.model.click(style)
        await f.document.settle()
        f.model.beginBehavior()
        PanelRendering.host(StyleBehaviorSheet(model: f.model))
        let fills = StyleBehaviorSheet.checking(.fills, f.model)
        fills.wrappedValue = false
        #expect(!fills.wrappedValue)
        let parent = StyleBehaviorSheet.parent(f.model)
        parent.wrappedValue = nil
        #expect(parent.wrappedValue == nil)
        f.model.cancelBehavior()
        #expect(!StyleBehaviorSheet.checking(.fills, f.model).wrappedValue)
        PanelRendering.host(StyleBehaviorSheet(model: f.model))
        f.model.beginRemoveUnused()
        PanelRendering.host(RemoveUnusedStylesSheet(model: f.model))
        f.model.cancelRemoveUnused()
        PanelRendering.host(RemoveUnusedStylesSheet(model: f.model))
        // The panel's registration.
        let registry = PanelRegistry()
        StylesFeatures.install(panels: registry, model: f.model)
        let descriptor = try #require(registry.descriptor(for: "styles"))
        #expect(descriptor.title == "Styles" && descriptor.optionsMenu().count == 12)
        _ = descriptor.makeView()
    }
}

/// The Styles panel and the Graphic Hose tool are installed at launch.
@Suite(.serialized) @MainActor struct StylesAndHoseWiringTests {
    @Test func theLaunchInstallsThePanelTheToolAndTheCanvasDrop() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer { window.close() }
        #expect(delegate.panels.descriptor(for: "styles")?.optionsMenu().count == 12)
        #expect(delegate.tools.makeTool(GraphicHoseTool.id) is GraphicHoseTool)
        #expect(delegate.tools.descriptor(for: GraphicHoseTool.id)?.options != nil)
        #expect(window.canvas.styleDrop != nil)
    }
}
