import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// What the control reachability audit wired (rch): menu:Text[Align] and menu:Text[Leading] with the
/// Text toolbar's items and the Object panel's Leading row, the Modify, Object, File, Edit and View
/// placeholders, the guide context menu, the Tools panel's Swap, None and Default with objects
/// selected, the Select panel and the object kinds of the canvas context menus.
@Suite(.serialized) @MainActor struct ReachabilityFeaturesTests {
    static func run(_ command: WireTuner.Command?) {
        if case .perform(let action)? = command?.action { action() }
    }

    static func endSheet(_ window: DocumentWindowController) {
        if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
    }

    // MARK: Align and leading

    static func alignLeading(_ world: TypeWorld) -> [CommandID: WireTuner.Command] {
        Dictionary(uniqueKeysWithValues: AlignLeadingCommands.commands(window: { [weak window = world.window] in window }).map { ($0.id, $0) })
    }

    static func alignment(_ world: TypeWorld, _ node: OpID) -> Wiretuner_Doc_V1_Alignment? {
        ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)])).text?.alignment
    }

    static func leadings(_ world: TypeWorld, _ node: OpID) -> Set<Wiretuner_Doc_V1_Leading> {
        ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)])).leadings
    }

    @Test func alignmentAndLeadingApplyToTheSelectedTextAndCheckWhatItShares() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let commands = Self.alignLeading(world)
        let center = try #require(commands[AlignLeadingCommands.ID.align("center")])
        #expect(center.defaultKey == KeyEquivalent("c", [.command, .shift]) && commands[AlignLeadingCommands.ID.align("left")]?.defaultKey == nil)
        #expect(center.menuPath?.components == ["Text", "Align"] && center.contexts == [.text, .textEditing])
        #expect(center.validation() == .disabled(TextFeatures.noText))
        let node = try await world.block("Align me")
        #expect(center.validation() == .checked(false))
        Self.run(center)
        await world.settle()
        #expect(Self.alignment(world, node) == .center && center.validation() == .checked(true))
        #expect(world.document.undoTitle == "Undo Alignment")
        Self.run(commands[AlignLeadingCommands.ID.align("justified")])
        await world.settle()
        #expect(Self.alignment(world, node) == .justified)
        // Leading: Auto until marked, Solid then Auto, each one change.
        let solid = try #require(commands[AlignLeadingCommands.ID.leading("solid")])
        let auto = try #require(commands[AlignLeadingCommands.ID.leading("auto")])
        #expect(auto.validation() == .checked(true) && solid.validation() == .checked(false))
        Self.run(solid)
        await world.settle()
        #expect(Self.leadings(world, node) == [ObjectPanelModel.solidLeading] && solid.validation().isChecked)
        #expect(world.document.undoTitle == "Undo Leading")
        Self.run(auto)
        await world.settle()
        #expect(Self.leadings(world, node) == [ObjectPanelModel.autoLeading])
        // Other… and the toolbar's Leading present the sheet.
        for id in [AlignLeadingCommands.ID.leading("other"), AlignLeadingCommands.ID.toolbarLeading] {
            #expect(commands[id]?.validation() == .enabled)
            Self.run(commands[id])
            let sheet = try #require(world.window.window?.attachedSheet)
            #expect(sheet.identifier?.rawValue == LeadingSheetModel.sheet)
            Self.endSheet(world.window)
        }
        // Nothing selected: disabled, and running writes nothing.
        world.window.selection.model.clear()
        #expect(!solid.validation().isEnabled && !commands[AlignLeadingCommands.ID.leading("other")]!.validation().isEnabled)
        let count = world.document.changeCount
        Self.run(solid)
        Self.run(center)
        await world.settle()
        #expect(world.document.changeCount == count)
        #expect(AlignLeadingCommands.showLeading(on: world.window) != nil)
        Self.endSheet(world.window)
    }

    @Test func theLeadingSheetParsesEachModeAndCommitsOnlyValidValues() async throws {
        #expect(LeadingSheetModel(leading: nil).text.isEmpty && LeadingSheetModel(leading: nil).mode == .percent)
        let model = LeadingSheetModel(leading: .with { $0.mode = .fixed; $0.value = 14.5 })
        #expect(model.text == "14.5" && model.leading?.value == 14.5)
        model.text = "24 pt"
        #expect(model.leading?.mode == .fixed && model.leading?.value == 24)
        model.text = "0"
        #expect(model.leading == nil, "fixed leading is at least 0.1 pt")
        model.mode = .extra
        #expect(model.leading?.value == 0)
        model.text = "-2"
        #expect(model.leading?.value == -2)
        model.mode = .percent
        model.text = "150%"
        #expect(model.leading?.value == 150)
        model.text = "abc"
        #expect(model.leading == nil)
        #expect(!AlignLeadingCommands.isValid(.with { $0.mode = .percent; $0.value = .infinity }))
        #expect(!AlignLeadingCommands.isValid(.with { $0.mode = .UNRECOGNIZED(9); $0.value = 1 }))
        #expect(AlignLeadingCommands.isValid(.with { $0.value = 3 }), "unspecified reads as Extra")
        var committed: [Wiretuner_Doc_V1_Leading] = []
        model.text = "130"
        PanelRendering.host(LeadingSheet(model: model, commit: { committed.append($0) }, cancel: {}))
        LeadingSheet.committing(model) { committed.append($0) }()
        #expect(committed.map(\.value) == [130])
        model.text = ""
        LeadingSheet.committing(model) { _ in Issue.record("an empty value is not committed") }()
        PanelRendering.host(LeadingSheet(model: LeadingSheetModel(leading: nil), commit: { _ in }, cancel: {}))
        // An unset mode reads as Extra.
        #expect(ObjectPanelModel.leading([.with { $0.leading = .with { $0.value = 2 } }]).mode == .extra)
        #expect(ObjectPanelModel.leading([]) == ObjectPanelModel.autoLeading)
    }

    @Test func theObjectPanelsLeadingRowShowsAndWritesTheMode() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Leading row")
        let registry = InspectorRegistry()
        AlignLeadingCommands.register(into: registry)
        let model = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)]))
        #expect(registry.views(for: model).map(\.id) == ["textLeading"])
        PanelRendering.host(LeadingSectionView(model: model))
        let mode = LeadingSectionView.mode(model)
        #expect(mode.wrappedValue == .percent)
        mode.wrappedValue = .fixed
        await world.settle()
        #expect(Self.leadings(world, node).first?.mode == .fixed && Self.leadings(world, node).first?.value == 12 * 1.2)
        LeadingSectionView.value(ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)])))(20)
        await world.settle()
        #expect(Self.leadings(world, node).first?.value == 20)
        LeadingSectionView.mode(ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node)]))).wrappedValue = .extra
        await world.settle()
        #expect(Self.leadings(world, node) == [ObjectPanelModel.solidLeading])
        // Mixed: the tag reads mixed and choosing it writes nothing.
        let other = try await world.block("Other", at: Point(x: 50, y: 150))
        let both = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node), SelectionID(other)]))
        #expect(LeadingSectionView.shared(both) == nil && LeadingSectionView.mode(both).wrappedValue == LeadingSectionView.mixedTag)
        let count = world.document.changeCount
        LeadingSectionView.mode(both).wrappedValue = LeadingSectionView.mixedTag
        await world.settle()
        #expect(world.document.changeCount == count)
        PanelRendering.host(LeadingSectionView(model: both))
        LeadingSectionView.mode(both).wrappedValue = .percent
        await world.settle()
        #expect(LeadingSectionView.shared(ObjectPanelModel(document: world.document, selection: Selection([SelectionID(node), SelectionID(other)])))?.value == 120)
        #expect(model.setLeading(.with { $0.mode = .fixed; $0.value = -1 }) == nil, "an invalid value is refused")
    }

    // MARK: Modify, Object, File, Edit, View

    static func features(_ world: GlueWorld) -> (ReachabilityFeatures, [CommandID: WireTuner.Command]) {
        let features = ReachabilityFeatures(window: { [weak window = world.window] in window })
        return (features, Dictionary(uniqueKeysWithValues: features.commands().map { ($0.id, $0) }))
    }

    @Test func enterGroupEditContentsAndReverseDirectionActOnTheSelection() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (_, commands) = Self.features(world)
        let ids = ContextMenuCatalog.ID.self
        for id in [ids.enterGroup, ids.reverseDirection, ids.editContents, ids.releaseContents, ids.reroute, ids.detachEnds] {
            #expect(commands[id]?.validation().isEnabled == false, "\(id) with nothing selected")
        }
        // Enter Group subselects the members.
        let rects = await world.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20), Rect(x: 40, y: 0, width: 20, height: 20)])
        let group = try #require(await world.document.perform(GroupObjects(rects.map(\.opID))).value?.createdObjects.first)
        await world.document.settle()
        world.select([group])
        #expect(commands[ids.enterGroup]?.validation() == .enabled)
        Self.run(commands[ids.enterGroup])
        #expect(Set(world.window.selection.selection.ids) == Set(rects))
        #expect(commands[ids.enterGroup]?.validation() == .disabled(ReachabilityFeatures.noGroup))
        // Reverse Direction: a path.
        let path = try #require(await world.document.addPath([Point(x: 0, y: 100), Point(x: 50, y: 100), Point(x: 50, y: 150)]))
        world.select([path.opID])
        #expect(commands[ids.reverseDirection]?.validation() == .enabled)
        Self.run(commands[ids.reverseDirection])
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Reverse Direction")
        // Edit Contents: a clip group's contents are subselected.
        let square = try #require(await world.document.addPath([Point(x: 200, y: 0), Point(x: 300, y: 0), Point(x: 300, y: 100), Point(x: 200, y: 100)], closed: true))
        let inside = await world.document.addRectangles([Rect(x: 220, y: 20, width: 20, height: 20)])
        let payload = ClipboardPayload(copying: inside.map(\.opID), from: world.state)
        let clip = try #require(await world.document.perform(PasteContents(payload, into: square.opID)).value)
        await world.document.settle()
        let clipGroup = try #require(EditFeatures.clipGroup(of: square.opID, in: world.state) ?? clip.createdObjects.first { ClipGroups.isClipGroup($0, in: world.state) })
        world.select([clipGroup])
        #expect(commands[ids.editContents]?.validation() == .enabled)
        Self.run(commands[ids.editContents])
        #expect(!world.window.selection.selection.ids.isEmpty && !world.window.selection.selection.ids.contains(SelectionID(clipGroup)))
        // Release Contents (OBJ-060): the contents back on the page, the group gone.
        world.select([clipGroup])
        let released = ClipGroups.contents(of: clipGroup, in: world.state)
        #expect(commands[ids.releaseContents]?.validation() == .enabled)
        Self.run(commands[ids.releaseContents])
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Release Contents")
        #expect(!world.state.isLive(clipGroup) && !released.isEmpty && released.allSatisfy { world.state.isLive($0) })
        world.select([square.opID])
        #expect(commands[ids.releaseContents]?.validation() == .disabled(ReachabilityFeatures.noClipGroup))
    }

    @Test func rerouteAndDetachEndsWriteOneChangeEach() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (_, commands) = Self.features(world)
        let ids = ContextMenuCatalog.ID.self
        let boxes = await world.document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 200, y: 0, width: 40, height: 40)])
        let start = ConnectorEnd(node: NodeID(boxes[0].opID), side: .right, point: Point(x: 40, y: 20))
        let end = ConnectorEnd(node: NodeID(boxes[1].opID), side: .left, point: Point(x: 200, y: 20))
        let connector = try #require(await world.document.perform(CreateConnector(start: start, end: end)).value?.createdObjects.first)
        await world.document.settle()
        world.select([connector])
        #expect(commands[ids.reroute]?.validation() == .enabled && commands[ids.detachEnds]?.validation() == .enabled)
        Self.run(commands[ids.reroute])
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Reroute")
        Self.run(commands[ids.detachEnds])
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Detach Ends")
        #expect(!world.state.props(connector).connector.start.hasNode && !world.state.props(connector).connector.end.hasNode)
        // A connector and a path reverse together.
        let path = try #require(await world.document.addPath([Point(x: 0, y: 100), Point(x: 50, y: 100)]))
        world.select([connector, path.opID])
        #expect(ReachabilityFeatures.reverseCommand(world.window)?.label == "Reverse Direction")
        Self.run(commands[ids.reverseDirection])
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Reverse Direction")
    }

    @Test func objectCommandsNameNoteLinkLibraryAndTrace() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (features, commands) = Self.features(world)
        let ids = ContextMenuCatalog.ID.self
        var shown: [PanelID] = []
        var performed: [CommandID] = []
        features.showPanel = { shown.append($0) }
        features.perform = { performed.append($0); return true }
        features.validate = { _ in .enabled }
        for id in [ids.name, ids.note, ids.link, ids.addToLibrary] {
            #expect(commands[id]?.validation() == .disabled(ReachabilityFeatures.noObject), "\(id)")
        }
        let rect = try #require(await world.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)]).first)
        world.select([rect.opID])
        for id in [ids.name, ids.note, ids.link, ids.addToLibrary] { #expect(commands[id]?.validation() == .enabled, "\(id)") }
        // Name… and Note… present a sheet; its commit writes every selected object.
        for (id, sheet) in [(ids.name, "object-name-sheet"), (ids.note, "object-note-sheet")] {
            Self.run(commands[id])
            #expect(world.window.window?.attachedSheet?.identifier?.rawValue == sheet)
            Self.endSheet(world.window)
        }
        _ = await ReachabilityFeatures.write(.name, "Logo", on: world.window)?.value
        _ = await ReachabilityFeatures.write(.note, "Keep", on: world.window)?.value
        #expect(world.state.displayName(of: rect.opID) == "Logo")
        #expect(ObjectPanelModel(document: world.document, selection: Selection([rect])).common?.note == "Keep")
        Self.run(commands[ids.link])
        Self.run(commands[ids.addToLibrary])
        #expect(shown == ["navigation", "library"] && performed == [ReachabilityFeatures.ID.convertToSymbol])
        features.perform = { _ in false }
        Self.run(commands[ids.addToLibrary])
        #expect(shown.count == 2, "the panel shows only when the symbol was made")
        features.validate = { _ in .disabled("No") }
        #expect(commands[ids.addToLibrary]?.validation() == .disabled("No"))
        // Trace… chooses the Trace tool.
        world.setup.environment.tools.replace(try #require(ToolCatalog.all.first { $0.id == TraceTool.id }))
        #expect(commands[ids.trace]?.validation() == .enabled)
        Self.run(commands[ids.trace])
        #expect(world.window.toolManager.activeToolID == TraceTool.id)
        // The one-field sheet's rules.
        let entry = TextEntrySheetModel(title: "Rename Document", text: "  Poster  ", limit: 5, multiline: false, allowsEmpty: false)
        #expect(entry.text == "  Pos" && entry.value == "Pos")
        entry.text = "   "
        #expect(entry.value == nil)
        let note = TextEntrySheetModel(title: "Note", text: "", limit: 10, multiline: true, allowsEmpty: true)
        #expect(note.value == "")
        var committed: [String] = []
        PanelRendering.host(TextEntrySheet(model: note, commit: { committed.append($0) }, cancel: {}))
        PanelRendering.host(TextEntrySheet(model: entry, commit: { committed.append($0) }, cancel: {}))
        TextEntrySheet.committing(note) { committed.append($0) }()
        TextEntrySheet.committing(entry) { committed.append($0) }()
        #expect(committed == [""])
        world.select([])
        #expect(features.showNameSheet(.name, on: world.window) == nil)
    }

    @Test func pageFileEditAndCollaboratorCommands() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (features, commands) = Self.features(world)
        let ids = ContextMenuCatalog.ID.self
        #expect(commands[ids.removePage]?.validation() == .disabled(ReachabilityFeatures.onePage))
        Self.run(commands[ids.duplicatePage])
        await world.document.settle()
        #expect(world.document.pageList.pages.count == 2 && commands[ids.removePage]?.validation() == .enabled)
        Self.run(commands[ids.removePage])
        await world.document.settle()
        #expect(world.document.pageList.pages.count == 1)
        Self.run(commands[ids.removePage])
        Self.run(commands[ids.goToPage])
        #expect(commands[ids.goToPage]?.validation() == .enabled)
        // Rename Document… and Show in Library.
        #expect(commands[ids.renameDocument]?.validation() == .disabled(ReachabilityFeatures.notInLibrary))
        #expect(features.showRenameSheet(on: world.window) == nil)
        var renamed: [(String, String)] = []
        var library = 0
        features.libraryName = { _ in "Poster" }
        features.rename = { renamed.append(($0, $1)) }
        features.showLibrary = { library += 1 }
        #expect(commands[ids.renameDocument]?.validation() == .enabled)
        Self.run(commands[ids.renameDocument])
        #expect(world.window.window?.attachedSheet?.identifier?.rawValue == "rename-document-sheet")
        Self.endSheet(world.window)
        features.rename(world.document.id, "Flyer")
        #expect(renamed.map(\.1) == ["Flyer"])
        Self.run(commands[ids.showDocumentInLibrary])
        #expect(library == 1)
        // Edit in External Editor wants one image.
        #expect(commands[ids.editWith]?.title == "Edit in External Editor" && commands[ids.editWith]?.validation() == .disabled(ExternalEditing.noImage))
        Self.run(commands[ids.editWith])
        // Go to <name>'s Page wants a collaborator on a page.
        #expect(commands[ids.goToCollaboratorPage]?.validation() == .disabled(ReachabilityFeatures.noCollaboratorPage))
        Self.run(commands[ids.goToCollaboratorPage])
    }

    @Test func theGuideMenuActsOnTheGuideUnderThePointer() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (features, commands) = Self.features(world)
        let ids = ContextMenuCatalog.ID.self
        let page = world.document.pageList.pages[0]
        _ = await world.document.perform(AddGuides(on: [page.id], axis: .horizontal, at: [100, 200])).value
        await world.document.settle()
        features.attach(world.window)
        let resolve = world.window.contextResolver.guide
        let over = world.window.viewport.toView(Point(x: page.origin.x + 50, y: page.origin.y + 100))
        let away = world.window.viewport.toView(Point(x: page.origin.x + 50, y: page.origin.y + 150))
        #expect(resolve(away) == nil)
        #expect(commands[ids.releaseGuide]?.validation() == .disabled(ReachabilityFeatures.noGuide))
        let target = try #require(resolve(over))
        #expect(target == .guide(locked: false))
        _ = world.window.contextMenu(for: target)
        #expect(commands[ids.releaseGuide]?.validation() == .enabled && commands[ids.deleteGuide]?.validation() == .enabled)
        Self.run(commands[ids.deleteGuide])
        await world.document.settle()
        #expect(world.document.pageList.pages[0].guides.count == 1)
        let second = world.window.viewport.toView(Point(x: page.origin.x + 50, y: page.origin.y + 200))
        _ = world.window.contextMenu(for: try #require(resolve(second)))
        Self.run(commands[ids.releaseGuide])
        await world.document.settle()
        #expect(world.document.pageList.pages[0].guides.isEmpty && world.document.undoTitle == "Undo Release guide")
        // Lock Guide toggles the guides' lock.
        #expect(commands[ids.lockGuide]?.validation() == CommandValidation(isChecked: false))
        Self.run(commands[ids.lockGuide])
        await world.document.settle()
        #expect(world.document.settings.guidesLocked && commands[ids.lockGuide]?.validation().isChecked == true)
        _ = world.window.contextMenu(for: .pasteboard(overPage: true))
        #expect(features.contextGuide(world.window) == nil)
    }

    @Test func extensionEntriesAndTheSelectPanel() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let (features, _) = Self.features(world)
        var performed: [CommandID] = []
        features.perform = { performed.append($0); return true }
        features.validate = { _ in .enabled }
        let descriptors = features.extensionDescriptors(existing: ExtensionRegistry())
        let reverse = try #require(descriptors.first { $0.id == "reverseDirection" })
        let info = try #require(descriptors.first { $0.id == "fileInfo" })
        #expect(!reverse.isStub && !info.isStub)
        #expect(reverse.validate?() == .disabled(ReachabilityFeatures.noPathOrConnector))
        let path = try #require(await world.document.addPath([Point(x: 0, y: 0), Point(x: 50, y: 0)]))
        world.select([path.opID])
        #expect(reverse.validate?() == .enabled)
        _ = reverse.run?(nil)
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Reverse Direction")
        #expect(info.validate?() == .enabled)
        _ = info.run?(nil)
        #expect(performed == [DocumentInfoFeatures.id])
        #expect(features.extensionDescriptors(existing: ExtensionRegistry(descriptors: [])).isEmpty)
        // The Select panel is the Find & Replace body on its Select tab.
        let select = ReachabilityFeatures.selectPanel(selection: nil)
        #expect(select.id == "select" && select.title == "Select" && select.defaultGroup == PanelCatalog.Group.findSelect)
        let view = select.makeView()
        #expect(!String(describing: type(of: view)).contains("PlaceholderPanelBody"))
    }

    // MARK: The Tools panel's colour buttons

    @Test func swapNoneAndDefaultColourTheSelection() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let palette = ToolPaletteModel()
        let commands = Dictionary(uniqueKeysWithValues: ReachabilityFeatures.wellCommands(palette: palette).map { ($0.id, $0) })
        let ids = ToolPanelCommands.ID.self
        // Nothing selected: the current colours, as before.
        #expect(commands[ids.swap]?.validation() == .enabled && commands[ids.none]?.validation() == .enabled && commands[ids.restoreDefault]?.validation() == .enabled)
        let before = palette.wells
        Self.run(commands[ids.swap])
        #expect(palette.wells.fill == before.stroke && palette.wells.stroke == before.fill)
        Self.run(commands[ids.none])
        Self.run(commands[ids.restoreDefault])
        #expect(palette.wells == before)
        // Selection colours but no colour panels: disabled.
        palette.selectionWells = WellColors(stroke: .none, fill: .none)
        for id in [ids.swap, ids.none, ids.restoreDefault] { #expect(commands[id]?.validation().isEnabled == false) }
        // With the colour panels and objects selected: one change each on the objects.
        palette.coloring = ToolWellColoring(swatches: SwatchesPanelModel(workspace: fixture.workspace))
        let red = ColorResolver.inline(RenderColor(red: 1, green: 0, blue: 0))
        let first = await fixture.rect(fill: red)
        let second = await fixture.rect(fill: red)
        fixture.select([first, second])
        #expect(commands[ids.swap]?.validation() == .enabled && commands[ids.none]?.validation() == .enabled)
        #expect(commands[ids.restoreDefault]?.validation().isEnabled == false, "no document defaults known")
        Self.run(commands[ids.swap])
        await fixture.settle()
        #expect(fixture.document.undoTitle == "Undo Swap Stroke and Fill" && fixture.fill(first) != red)
        palette.activeWell = .fill
        Self.run(commands[ids.none])
        await fixture.settle()
        #expect(fixture.fill(first) == ColorResolver.none)
        palette.documentChoices = (fill: .color(red), stroke: .noColor)
        #expect(commands[ids.restoreDefault]?.validation() == .enabled)
        Self.run(commands[ids.restoreDefault])
        await fixture.settle()
        #expect(fixture.fill(second) == red && fixture.document.undoTitle == "Undo Default Colors")
        #expect(ToolWellColoring.reference(choice: .noColor) == ColorResolver.none && ToolWellColoring.reference(choice: .color(red)) == red)
        // Mixed fills: Swap is disabled.
        _ = await fixture.document.perform(ApplyColor([first], target: .fill, color: ColorResolver.inline(RenderColor(red: 0, green: 0, blue: 1)))).value
        await fixture.settle()
        #expect(commands[ids.swap]?.validation() == .disabled(ToolWellColoring.mixedColors))
        Self.run(commands[ids.swap])
        ColorPanelFixture.render(ToolWellsView(model: palette))
    }

    // MARK: The application menu

    @Test func theApplicationMenuHasServicesBeforeTheHideItems() throws {
        let registry = CommandRegistry()
        StandardCommands.register(into: registry)
        let target = CommandMenuTarget(registry: registry)
        let bar = MainMenuBuilder.menuBar(registry: registry, shortcuts: ShortcutSet.builtInDefault(commands: registry.commands), target: target)
        let app = try #require(bar.items.first?.submenu)
        let services = try #require(app.item(withTitle: MainMenuBuilder.servicesTitle))
        #expect(services.submenu?.title == MainMenuBuilder.servicesTitle && NSApp.servicesMenu != nil && services.identifier?.rawValue == "menu.app.services")
        let index = app.index(of: services)
        #expect(app.items[index - 1].isSeparatorItem && app.items[index + 1].isSeparatorItem && app.items[index + 2].title.hasPrefix("Hide"))
        // A menu without the Hide items gets it at the end.
        let bare = NSMenu(title: "Bare")
        bare.addItem(NSMenuItem(title: "Only", action: nil, keyEquivalent: ""))
        MainMenuBuilder.addServicesMenu(to: bare)
        #expect(bare.items.last?.title == MainMenuBuilder.servicesTitle && bare.items[1].isSeparatorItem)
    }

    // MARK: Context menus and the instance section

    @Test func canvasMenusReadTheNodesKind() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let rect = try #require(await world.document.addRectangles([Rect(x: 0, y: 0, width: 20, height: 20)]).first)
        let item = try #require(world.document.object(for: rect)?.item)
        let expected: [(NodeKind?, ContextObjectKind)] = [
            (.blend, .blend), (.chart, .chart), (.connector, .connector), (.instance, .symbolInstance), (.envelope, .envelope),
            (.image, .bitmap), (.placedFile, .importedGraphic), (.text, .text), (.rect, .path), (nil, .path),
        ]
        for (kind, menu) in expected { #expect(ContextObjectKind(kind: kind, item: item) == menu, "\(String(describing: kind))") }
        // A symbol instance on the canvas gets the instance menu (it drew as a group before).
        let filled = try #require(await world.document.addRectangles([Rect(x: 200, y: 200, width: 60, height: 60)]).first)
        let change = try #require(await world.document.perform(ConvertToSymbol([filled.opID])).value)
        await world.document.settle()
        let instance = try #require(change.createdObjects.first { world.state.nodeKind($0) == .instance })
        world.select([instance])
        let target = ContextMenuResolver().target(at: world.window.viewport.toView(Point(x: 230, y: 230)), viewport: world.window.viewport,
                                                 document: world.document, selection: world.window.selection)
        #expect(target == .objects([.symbolInstance]))
    }

    @Test func theInstanceSectionNamesTheSymbolAndReleasesTheInstance() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let label = try await world.block("Badge")
        let change = try #require(await world.document.perform(ConvertToSymbol([label])).value)
        await world.settle()
        let instance = try #require(change.createdObjects.first { world.state.nodeKind($0) == .instance })
        let registry = InspectorRegistry()
        InstanceSectionView.register(into: registry)
        let model = ObjectPanelModel(document: world.document, selection: Selection([SelectionID(instance)]))
        #expect(registry.views(for: model).map(\.id) == ["instance"])
        #expect(InstanceSectionView.symbolName([instance], in: world.state) != TextSectionView.mixed)
        #expect(InstanceSectionView.symbolName([], in: world.state) == TextSectionView.mixed)
        PanelRendering.host(InstanceSectionView(instances: [instance], model: model))
        InstanceSectionView.releasing([instance], model)()
        await world.settle()
        #expect(world.document.undoTitle == "Undo Release Instance")
        #expect(registry.views(for: ObjectPanelModel(document: world.document, selection: Selection([SelectionID(label)]))).isEmpty)
    }
}
