import AppKit
import Foundation
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A document window with the Edit menu features installed over a pasteboard of its own.
@MainActor
struct EditWorld {
    let setup: SetupWindow
    let features: EditFeatures
    let inspector = InspectorRegistry()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("uc2-\(UUID().uuidString)"))
    let sheets = TestBox<[NSWindow]>([])

    init(previousSplit: WireTuner.Command? = nil) {
        setup = SetupWindow(tools: [PointerTool.descriptor])
        features = EditFeatures(preferences: setup.environment.preferences)
        if let previousSplit { setup.environment.commands.replace(previousSplit) }
        let window = setup.window
        window.objectEditing.pasteboard = SystemObjectPasteboard(pasteboard)
        let sheets = sheets
        features.presentSheet = { sheet, _ in sheets.value.append(sheet) }
        features.install(commands: setup.environment.commands, inspector: inspector) { window }
        features.attach(window)
        for kind in [SnapSettings.Kind.point, .object, .guides] where window.snap[kind] { window.toggleSnap(kind) }
    }

    var window: DocumentWindowController { setup.window }
    var document: DocumentHandle { setup.document }
    var commands: CommandRegistry { setup.environment.commands }
    var state: EngineState { document.state }

    func select(_ ids: [SelectionID]) { window.selection.model.set(Selection(ids)) }

    func close() {
        pasteboard.releaseGlobally()
        setup.close()
    }
}

@Suite(.serialized) @MainActor struct EditFeaturesTests {
    typealias ID = EditFeatures.ID

    // MARK: Clipboard formats

    @Test func aCopyOffersTheEnabledFormatsAndWritesThemOnDemand() async throws {
        let world = EditWorld()
        defer { world.close() }
        let formats = try #require(world.window.objectEditing.pasteboard as? FormatsPasteboard)
        world.features.attach(world.window)
        #expect(world.window.objectEditing.pasteboard === formats)
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 20)])
        world.select(ids)
        world.window.objectEditing.copy()
        let types = formats.types
        #expect(types.contains(ClipboardFormat.nativeType) && types.contains(ClipboardFormat.pdfType) && types.contains(ClipboardFormat.svgType))
        #expect(types.contains(ClipboardFormat.pngType) && !types.contains(ClipboardFormat.rtfType))
        #expect(world.window.objectEditing.canPaste && formats.read() != nil && formats.provider != nil)
        let pdf = try #require(world.pasteboard.data(forType: NSPasteboard.PasteboardType(ClipboardFormat.pdfType)))
        #expect(pdf.starts(with: Array("%PDF".utf8)))
        // The provider writes what it is asked for, and nothing for a type it does not offer.
        let item = NSPasteboardItem()
        formats.provider?.pasteboard(nil, item: item, provideDataForType: NSPasteboard.PasteboardType(ClipboardFormat.svgType))
        formats.provider?.pasteboard(nil, item: item, provideDataForType: NSPasteboard.PasteboardType("com.example.none"))
        #expect(item.data(forType: NSPasteboard.PasteboardType(ClipboardFormat.svgType)) != nil)
        // The preference switches formats off; a writer-less copy writes the native type alone.
        world.setup.environment.preferences.set(["WireTuner", "SVG"], for: PreferenceCatalog.Export.copyFormats)
        world.window.objectEditing.copy()
        #expect(!formats.types.contains(ClipboardFormat.pdfType) && formats.types.contains(ClipboardFormat.svgType))
        formats.makeWriter = { _ in nil }
        formats.write([1, 2, 3])
        #expect(formats.types == [SystemObjectPasteboard.type.rawValue] && formats.read() == [1, 2, 3])
        // A window whose pasteboard is not the system one keeps it.
        let other = SetupWindow()
        defer { other.close() }
        final class Memory: ObjectPasteboard {
            func write(_ payload: [UInt8]) {}
            func read() -> [UInt8]? { nil }
        }
        other.window.objectEditing.pasteboard = Memory()
        world.features.attach(other.window)
        #expect(other.window.objectEditing.pasteboard is Memory && EditFeatures.pasteboard(of: other.window) == .general)
    }

    @Test func thePreferencesMapToClipboardSettings() {
        let preferences = PreferenceStore(defaults: TestDefaults().defaults)
        let settings = ClipboardPreferences.settings(preferences)
        #expect(settings.formats == Set(ClipboardFormat.allCases) && settings.colors == .cmykAndRGB && settings.imageResolution == 144)
        preferences.set(["PDF", "text"], for: PreferenceCatalog.Export.copyFormats)
        preferences.set("rgb", for: PreferenceCatalog.Export.convertColors)
        preferences.set(300, for: PreferenceCatalog.Export.clipboardResolution)
        let changed = ClipboardPreferences.settings(preferences)
        #expect(changed.formats == [.native, .pdf, .plainText] && changed.colors == .rgb && changed.imageResolution == 300)
        #expect(ClipboardPreferences.format(named: "Image (TIFF and PNG)") == .image && ClipboardPreferences.format(named: "png") == .image)
        #expect(ClipboardPreferences.format(named: "RTF") == .rtf && ClipboardPreferences.format(named: "nonsense") == nil)
        #expect(ClipboardFormat.allCases.map(ClipboardPreferences.name(of:)) == ["WireTuner", "PDF", "SVG", "Image", "Rich text", "Plain text"])
    }

    @Test func copySpecialAndPasteSpecialUseOneFormat() async throws {
        let world = EditWorld()
        defer { world.close() }
        #expect(world.commands.command(ID.copySpecial)?.validation() == .disabled(ObjectMenuCommands.noSelection))
        #expect(world.features.presentCopySpecial() == nil && world.features.copy(as: .pdf) == false)
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 20)])
        world.select(ids)
        world.commands.perform(ID.copySpecial)
        #expect(world.sheets.value.last?.identifier?.rawValue == EditFeatures.copySpecialSheet)
        let copy = try #require(world.features.presentCopySpecial())
        Render.view(FormatChoiceSheet(model: copy))
        copy.choice = .svg
        copy.confirm()
        #expect(world.features.pasteFormats(world.window) == [.svg])
        world.features.presentCopySpecial()?.cancel()
        // Paste Special lists what is there and pastes the chosen format as artwork.
        #expect(world.commands.command(ID.pasteSpecial)?.validation() == .enabled)
        let paste = try #require(world.features.presentPasteSpecial())
        #expect(paste.formats == [.svg])
        world.window.objectEditing.visibleCenter = { nil }
        world.features.presentPasteSpecial()?.confirm()
        try await Task.sleep(for: .milliseconds(100))
        await world.document.settle()
        let before = world.state.liveChildren(try #require(LayerOrder(world.state).drawingLayer)).count
        #expect(await world.features.paste(as: .svg))
        await world.document.settle()
        #expect(world.state.liveChildren(LayerOrder(world.state).drawingLayer!).count == before + 1)
        paste.cancel()
        // Copy Special over a window whose pasteboard is the plain one.
        world.window.objectEditing.pasteboard = SystemObjectPasteboard(world.pasteboard)
        world.select(ids)
        #expect(world.features.copy(as: .pdf) && world.features.pasteFormats(world.window) == [.pdf])
        world.features.attach(world.window)
        // A format that is not there is refused with a message; native pastes objects.
        #expect(await world.features.paste(as: .rtf) == false)
        world.select(ids)
        world.window.objectEditing.copy()
        #expect(await world.features.paste(as: .native))
        world.pasteboard.clearContents()
        #expect(await world.features.paste(as: .native) == false)
        #expect(world.features.presentPasteSpecial() == nil)
        #expect(world.commands.command(ID.pasteSpecial)?.validation() == .disabled("The clipboard is empty"))
        // A failing blob store refuses the paste.
        world.features.storeBlobs = { _, _ in throw CocoaError(.fileWriteUnknown) }
        world.pasteboard.clearContents()
        world.pasteboard.setString("Hello", forType: .string)
        #expect(await world.features.paste(as: .plainText) == false)
        world.features.dismiss("none")
        world.features.window = { nil }
        #expect(await world.features.paste(as: .plainText) == false && world.features.presentPasteSpecial() == nil)
    }

    @Test func sheetsPresentOnTheirWindowAndTheDefaultsHold() throws {
        let features = EditFeatures(preferences: PreferenceStore(defaults: TestDefaults().defaults))
        let parent = TestWindow.make()
        let sheet = TestWindow.make()
        features.presentSheet(sheet, parent)
        features.presentSheet(TestWindow.make(), nil)
        #expect(FormatChoiceModel(title: "x", formats: []) { _ in }.choice == .native)
        let fresh = NSPasteboard(name: NSPasteboard.Name("uc2-fresh-\(UUID().uuidString)"))
        #expect(EditFeatures.types(of: fresh).isEmpty)
        let formats = FormatsPasteboard(fresh)
        formats.write([7])
        #expect(formats.read() == [7])
        fresh.releaseGlobally()
        parent.endSheet(sheet)
    }

    @Test func pasteTakesTheRichestForeignFormat() async throws {
        let world = EditWorld()
        defer { world.close() }
        world.pasteboard.clearContents()
        #expect(!world.features.takesPaste(from: world.pasteboard))
        #expect(await world.features.pasteRichest(on: world.window) == false)
        world.pasteboard.setString("Pasted words", forType: .string)
        #expect(world.features.takesPaste(from: world.pasteboard))
        #expect(await world.features.pasteRichest(on: world.window))
        await world.document.settle()
        #expect(world.window.objectEditing.hasSelection)
        world.pasteboard.clearContents()
        world.pasteboard.setData(Data("%PDF".utf8), forType: NSPasteboard.PasteboardType(ClipboardFormat.pdfType))
        #expect(!world.features.takesPaste(from: world.pasteboard))
    }

    // MARK: Attributes

    @Test func copyAttributesAndPasteAttributesUseTheirOwnType() async throws {
        let world = EditWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
            + world.document.addRectangles([Rect(x: 20, y: 0, width: 10, height: 10)], filled: false)
        #expect(world.commands.command(ID.copyAttributes)?.validation() == .disabled(ObjectMenuCommands.noSelection))
        #expect(!world.features.copyAttributes())
        world.select([ids[0]])
        world.commands.perform(ID.copyAttributes)
        #expect(world.features.copiedAttributes(world.window) != nil)
        #expect(!world.window.objectEditing.canPaste, "an attribute copy never pastes as objects")
        world.select([ids[1]])
        #expect(world.commands.command(ID.pasteAttributes)?.validation() == .enabled)
        world.commands.perform(ID.pasteAttributes)
        await world.document.settle()
        #expect(world.document.model?.undoTitle.lowercased() == "undo paste attributes")
        world.select([])
        #expect(world.features.pasteAttributes() == nil)
        #expect(world.commands.command(ID.pasteAttributes)?.validation() == .disabled("Copy attributes and select objects first"))
        world.features.window = { nil }
        #expect(world.commands.command(ID.copyAttributes)?.validation() == .disabled(EditFeatures.noDocument))
    }

    // MARK: Clip groups

    @Test func pasteContentsAndCutContentsMakeAndUndoAClippingPath() async throws {
        let world = EditWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 100, height: 100), Rect(x: 20, y: 20, width: 200, height: 20)])
        #expect(world.commands.command(ID.pasteContents)?.validation() == .disabled("Copy objects and select one closed path or clipping path"))
        world.select([ids[1]])
        world.window.objectEditing.cut()
        await world.document.settle()
        world.select([ids[0]])
        #expect(world.features.canPasteContents(world.window))
        world.commands.perform(ID.pasteContents)
        await world.document.settle()
        let group = try #require(Objects.parent(of: ids[0].opID, in: world.state))
        #expect(ClipGroups.isClipGroup(group, in: world.state) && ClipGroups.clipPath(of: group, in: world.state) == ids[0].opID)
        #expect(EditFeatures.clipGroup(of: ids[0].opID, in: world.state) == group && EditFeatures.clipGroup(of: group, in: world.state) == group)
        // The Object panel's group section shows the clip path and subselects the contents.
        let panel = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(group)]))
        var subselected: [OpID] = []
        let section = GroupSectionModel(panel: panel) { subselected = $0 }
        #expect(section.clipGroup == group && section.clipPathTitle == world.state.displayName(of: ids[0].opID))
        #expect(section.contents.count == 1 && section.contentsTitle == "1 object" && section.clipCandidates.map(\.id).contains(ids[0].opID))
        section.selectContents()
        #expect(subselected == section.contents)
        Render.view(GroupSectionView(model: section))
        section.chooseClipPath(ids[0].opID)
        #expect(world.inspector.views(for: panel).map(\.id).contains("group"))
        // Cut Contents puts the contents on the clipboard and the path back.
        world.select([SelectionID(group)])
        #expect(world.commands.command(ID.cutContents)?.validation() == .enabled)
        world.commands.perform(ID.cutContents)
        await world.document.settle()
        #expect(!world.state.isLive(group) && world.window.objectEditing.canPaste)
        #expect(world.features.cutContents() == nil)
        world.select([])
        #expect(world.commands.command(ID.cutContents)?.validation() == .disabled("Select a clipping path"))
        #expect(world.features.pasteContents() == nil)
        #expect(EditFeatures.single(world.window) == nil)
    }

    // MARK: Join and Split

    @Test func joinMakesACompositeAndSplitTakesItApart() async throws {
        let world = EditWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        #expect(world.commands.command(ContextMenuCatalog.ID.join)?.validation() == .disabled("Select two or more paths"))
        #expect(world.features.join() == nil)
        let split = try #require(world.commands.command(ContextMenuCatalog.ID.split))
        #expect(split.defaultKey == KeyEquivalent("j", [.command, .shift]) && split.validation() == .disabled(PathEditingFeatures.noPoints))
        world.select(ids)
        world.commands.perform(ContextMenuCatalog.ID.join)
        await world.document.settle()
        let joined = try #require(world.state.liveChildren(LayerOrder(world.state).drawingLayer!).last)
        #expect(SplitObjects.splits(joined, in: world.state))
        world.select([SelectionID(joined)])
        #expect(world.commands.command(ContextMenuCatalog.ID.split)?.validation() == .enabled)
        world.commands.perform(ContextMenuCatalog.ID.split)
        await world.document.settle()
        let pieces = world.state.liveChildren(LayerOrder(world.state).drawingLayer!)
        #expect(pieces.count == 2)
        // With *Join non-touching paths* the ends within the snap distance join too.
        world.setup.environment.preferences.set(true, for: PreferenceCatalog.Object.joinNonTouching)
        world.select(pieces.map { SelectionID($0) })
        #expect(world.features.join() != nil)
        await world.document.settle()
        world.features.window = { nil }
        #expect(world.features.join() == nil)
        world.commands.perform(ContextMenuCatalog.ID.split)
    }

    @Test func splitDefersToTheSplitItWraps() async throws {
        var ran = 0
        let previous = WireTuner.Command(id: ContextMenuCatalog.ID.split, title: "Split", validation: { .enabled }, action: .perform { ran += 1 })
        let world = EditWorld(previousSplit: previous)
        defer { world.close() }
        #expect(world.commands.command(ContextMenuCatalog.ID.split)?.validation() == .enabled)
        world.commands.perform(ContextMenuCatalog.ID.split)
        #expect(ran == 1)
    }

    // MARK: Groups

    @Test func groupTransformsAsUnitTogglesEverySelectedGroup() async throws {
        let world = EditWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 10, height: 10)])
        let item = ContextMenuCatalog.ID.groupTransformsAsUnit
        #expect(world.commands.command(item)?.validation() == .disabled("Select a group"))
        #expect(world.features.toggleTransformAsUnit() == nil)
        let group = try #require(await world.document.perform(GroupObjects(ids.map(\.opID))).value?.createdObjects.first)
        await world.document.settle()
        world.select([SelectionID(group)])
        #expect(world.commands.command(item)?.validation() == .checked(false))
        world.commands.perform(item)
        await world.document.settle()
        #expect(GroupInspector.transformsAsUnit(group, in: world.state) && world.commands.command(item)?.validation() == .checked(true))
        // The section's checkbox and contents row.
        let panel = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(group)]))
        let section = GroupSectionModel(panel: panel) { _ in }
        #expect(section.transformAsUnit == .on && section.contentsTitle == "2 objects" && section.clipGroup == nil && section.clipPathTitle == nil)
        #expect(section.clipCandidates.isEmpty)
        GroupSectionView.asUnit(section).wrappedValue = false
        await world.document.settle()
        #expect(!GroupSectionView.asUnit(section).wrappedValue)
        section.chooseClipPath(group)
        Render.view(GroupSectionView(model: section))
        world.features.subselect(ids.map(\.opID))
        #expect(world.window.selection.model.ids == ids)
        let empty = GroupSectionModel(panel: ObjectPanelModel(document: world.document, selection: Selection([])), select: { _ in Issue.record("nothing to select") })
        empty.selectContents()
        #expect(GroupSection.section { _ in }.make(ObjectPanelModel(document: world.document, selection: Selection(ids))) == nil)
        world.features.window = { nil }
        #expect(world.commands.command(item)?.validation() == .disabled(EditFeatures.noDocument))
        #expect(world.features.toggleTransformAsUnit() == nil)
    }

    // MARK: Smart guides

    @Test func aPointerMoveSnapsToAndDrawsSmartGuides() async throws {
        let world = EditWorld()
        defer { world.close() }
        let center = world.setup.page.rect.center
        let ids = await world.document.addRectangles([Rect(x: center.x - 100, y: center.y, width: 50, height: 50),
                                                      Rect(x: center.x + 50, y: center.y + 3, width: 50, height: 50)])
        world.select([ids[1]])
        let manager = world.window.toolManager!
        manager.select(.pointer)
        let start = Point(x: center.x + 75, y: center.y + 28)
        manager.mouseDown(world.setup.event(start))
        manager.mouseDragged(world.setup.event(Point(x: start.x - 20, y: start.y)))
        manager.drawOverlay(in: PrintWorld.context(), viewport: world.window.viewport)
        let session = try #require(SmartGuideLink.shared.sessions[world.document.id])
        #expect(!session.match.guides.isEmpty && !world.window.smartGuideSnaps.isEmpty)
        manager.drawOverlay(in: PrintWorld.context(), viewport: world.window.viewport)
        manager.mouseUp(world.setup.event(Point(x: start.x - 20, y: start.y)))
        await world.document.settle()
        #expect(SmartGuideLink.shared.sessions[world.document.id] == nil)
        // The move snapped onto the first rectangle's top edge.
        let moved = try #require(Objects.bounds(of: ids[1].opID, in: world.state))
        #expect(abs(moved.minY - center.y) < 3, "the move snapped toward the alignment")
        // With the preference off (or Control held) nothing is tracked.
        world.setup.environment.preferences.set(false, for: PreferenceCatalog.General.smartGuides)
        manager.mouseDown(world.setup.event(moved.center))
        manager.mouseDragged(world.setup.event(Point(x: moved.center.x + 10, y: moved.center.y)))
        #expect(SmartGuideLink.shared.sessions[world.document.id] == nil)
        manager.cancel()
    }

    @Test func theGuideLinkDrawsEveryKindAndForgetsWithoutAnEngine() {
        let link = SmartGuideLink()
        #expect(link.moving("none", bounds: .zero, delta: .zero, from: .zero, tolerance: 1) == nil)
        link.register("doc") { _ in
            SmartGuideEngine(candidates: [.init(node: nil, bounds: Rect(x: 0, y: 0, width: 10, height: 10)),
                                          .init(node: nil, bounds: Rect(x: 20, y: 0, width: 10, height: 10))])
        }
        let match = link.moving("doc", bounds: Rect(x: 40, y: 1, width: 10, height: 10), delta: Vector(dx: 0.5, dy: 0), from: Point(x: 45, y: 6), tolerance: 2)
        #expect(match != nil && !link.snapGuides("doc").isEmpty)
        link.draw("doc", in: PrintWorld.context(), viewport: Viewport(scrollOrigin: .zero, zoom: 1, size: Size(width: 100, height: 100)))
        link.draw("other", in: PrintWorld.context(), viewport: Viewport(scrollOrigin: .zero, zoom: 1, size: Size(width: 100, height: 100)))
        let edge = SmartGuide(axis: .horizontal, position: 5, span: 0...10, kind: .edge)
        let spacing = SmartGuide(axis: .vertical, position: 5, span: 0...10, kind: .spacing, gaps: [10...20, 30...40])
        let horizontalSpacing = SmartGuide(axis: .horizontal, position: 5, span: 0...10, kind: .spacing, gaps: [10...20])
        let size = SmartGuide(axis: .vertical, position: 5, span: 5...5, kind: .size)
        #expect(SmartGuideLink.segments(edge).count == 1 && SmartGuideLink.segments(spacing).count == 2)
        #expect(SmartGuideLink.segments(horizontalSpacing)[0].0 == Point(x: 5, y: 10) && SmartGuideLink.segments(size).isEmpty)
        link.unregister("doc")
        #expect(link.snapGuides("doc").isEmpty)
    }

    // MARK: Select tab

    @Test func theSelectTabFindsObjectsByAttributeWithCachedCandidates() async throws {
        let world = EditWorld()
        defer { world.close() }
        let ids = await world.document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10), Rect(x: 20, y: 0, width: 30, height: 30)])
        _ = await world.document.perform(SetNameOrNote([ids[1].opID], .name, "Logo")).value
        let active = ActiveSelection(model: world.window.selection.model, document: world.document, editing: world.window.objectEditing)
        let state = FindReplaceState()
        state.select(.select)
        #expect(FindReplaceState.Attribute.available(in: .select).count == 11 && FindReplaceState.Attribute.name.title == "Name")
        state.attribute = .name
        state.objects.name = "logo"
        #expect(state.find(active) == [ids[1].opID] && state.result == "1 object found")
        #expect(world.window.selection.model.ids == [ids[1]])
        state.attribute = .objectType
        state.objects.objectType = .rectangle
        #expect(state.find(active).count == 2 && state.result == "2 objects found")
        #expect(state.objects.walks == 1, "the candidates are kept while the document is unchanged")
        state.attribute = .size
        state.objects.minimum = 20
        #expect(state.find(active) == [ids[1].opID])
        state.attribute = .strokeWidth
        state.objects.minimum = nil
        #expect(state.find(active).count == 2)
        state.attribute = .sameAs
        world.select([ids[0]])
        #expect(state.find(active) == [ids[1].opID])
        state.attribute = .pathShape
        world.select([ids[0]])
        #expect(!state.find(active).contains(ids[0].opID))
        state.attribute = .halftone
        #expect(state.find(active).isEmpty)
        state.attribute = .overprint
        #expect(state.find(active).isEmpty)
        state.attribute = .name
        state.objects.name = " "
        #expect(state.find(active).isEmpty && state.result == "Nothing to find")
        state.attribute = .sameAs
        world.select([])
        #expect(state.find(active).isEmpty)
        // Page and selection scopes.
        let search = ObjectAttributeSearch()
        search.attribute = .objectType
        search.objectType = .rectangle
        #expect(search.find(document: world.document, selection: Selection(ids), scope: .selection)?.count == 2)
        #expect(search.find(document: world.document, selection: Selection([]), scope: .page) != nil)
        _ = await world.document.perform(SetNameOrNote([ids[0].opID], .name, "Mark")).value
        _ = search.find(document: world.document, selection: Selection([]), scope: .document)
        #expect(search.walks == 3)
        // The fields render for every attribute.
        let panel = FindReplacePanelBody(selection: active, state: state)
        for attribute in FindReplaceState.Attribute.allCases {
            state.attribute = attribute
            Render.view(panel)
            if let object = attribute.objectAttribute { Render.view(ObjectAttributeFields(search: search, attribute: object)) }
        }
        let text = ObjectAttributeFields.optional(Binding(get: { search.minimum }, set: { search.minimum = $0 }))
        text.wrappedValue = "12"
        #expect(search.minimum == 12 && text.wrappedValue == "12")
        text.wrappedValue = "x"
        #expect(search.minimum == 12)
        text.wrappedValue = ""
        #expect(search.minimum == nil)
        #expect(ObjectAttributeSearch.typeTitles.count == AttributeQuery.ObjectType.allCases.count)
    }
}
