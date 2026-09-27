import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The Object panel style row (LIB-021), chart elements (DRAW-034), Share and Services (IO-037)
/// and reading order (OBJ-041).
@Suite(.serialized) @MainActor struct StyleChartShareOrderTests {
    static func context(_ world: TypeWorld) -> ToolContext {
        world.window.toolManager.context
    }

    static func event(_ world: TypeWorld, _ point: Point, _ modifiers: KeyModifiers = []) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: point, viewPoint: world.window.viewport.toView(point), modifiers: modifiers)
    }

    static func styles(_ world: TypeWorld) -> StylesPanelModel {
        let selection = ActiveSelection(model: world.window.selection.model, document: world.document, editing: world.window.objectEditing)
        selection.preferences = world.setup.environment.preferences
        return StylesPanelModel(selection: selection)
    }

    // MARK: Style row and overrides (LIB-021)

    @Test func theStyleRowShowsTheStyleThePlusSignAndRedefines() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let rect = await world.document.addRectangles([Rect(x: 50, y: 50, width: 40, height: 40)])[0].opID
        _ = await world.document.perform(CreateGraphicStyle(.selection(rect), name: "Callout", applyTo: [rect])).value
        await world.settle()
        world.window.selection.model.set(Selection([SelectionID(rect)]))
        let model = Self.styles(world)
        let row = try #require(ObjectStyleRowState(model))
        #expect(row.name == "Callout" && !row.isModified && row.styles.contains { $0.name == "Callout" })
        #expect(ObjectStyleRowActions.redefine(model) == nil, "nothing to redefine")
        let list = AttributesListModel(document: world.document, selection: Selection([SelectionID(rect)]))
        #expect(StyleOverrideMarks.lists(list).isEmpty)
        // Editing a governed attribute: the dot and the plus sign at once.
        _ = await world.document.perform(AddAppearance.fill([rect])).value
        await world.settle()
        let edited = try #require(ObjectStyleRowState(model))
        #expect(edited.isModified)
        let marked = AttributesListModel(document: world.document, selection: Selection([SelectionID(rect)]))
        #expect(StyleOverrideMarks.lists(marked).contains(.fills))
        #expect(PropertiesTree(list: marked).overridden.contains(.fills))
        // Redefine: one change, the plus sign gone.
        let before = world.document.changeCount
        _ = await ObjectStyleRowActions.redefine(model)?.value
        await world.settle()
        #expect(world.document.changeCount == before + 1 && world.document.undoTitle == "Undo Redefine style Callout")
        #expect(try #require(ObjectStyleRowState(model)).isModified == false)
        // The pop-up applies another style; the preview drags as the style.
        _ = await world.document.perform(CreateGraphicStyle(.normal, name: "Plain")).value
        await world.settle()
        let now = try #require(ObjectStyleRowState(model))
        let plain = try #require(now.styles.first { $0.name == "Plain" })
        ObjectStyleRowActions.choice(now, model).wrappedValue = plain.id.description
        await world.settle()
        #expect(try #require(ObjectStyleRowState(model)).name == "Plain")
        ObjectStyleRowActions.choice(now, model).wrappedValue = "nothing"
        #expect(ObjectStyleRowActions.choice(now, model).wrappedValue == now.style?.description)
        let provider = ObjectStyleRowActions.drag(now, model)
        #expect(provider.registeredTypeIdentifiers.contains(StyleDrag.typeIdentifier))
        // Rendered, alone and at the top of the properties list.
        PanelRendering.host(ObjectStyleRow(model: model))
        ObjectStyleRow.shared = model
        defer { ObjectStyleRow.shared = nil }
        PanelRendering.host(AttributesListView(model: marked, state: AttributesState()))
        // Nothing selected: the defaults and their style.
        world.window.selection.model.clear()
        #expect(ObjectStyleRowState(model) != nil)
        #expect(ObjectStyleRowState(model) == ObjectStyleRowState(model))
        #expect(ObjectStyleRowActions.drag(ObjectStyleRowState(model)!, model).registeredTypeIdentifiers.count <= 1)
        #expect(ObjectStyleRowState(Self.stylesWithoutDocument()) == nil)
        PanelRendering.host(ObjectStyleRow(model: Self.stylesWithoutDocument()))
    }

    static func stylesWithoutDocument() -> StylesPanelModel { StylesPanelModel(selection: ActiveSelection()) }

    @Test func clearOverrideFromTheRowsContextMenu() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let rect = await world.document.addRectangles([Rect(x: 50, y: 50, width: 40, height: 40)])[0].opID
        _ = await world.document.perform(CreateGraphicStyle(.selection(rect), name: "Callout", applyTo: [rect])).value
        _ = await world.document.perform(AddAppearance.fill([rect])).value
        await world.settle()
        let list = AttributesListModel(document: world.document, selection: Selection([SelectionID(rect)]))
        let item = try #require(list.displayRows.first { $0.list == .fills })
        let command = try #require(StyleOverrideMarks.clear(item, list: list))
        _ = await world.document.perform(command).value
        await world.settle()
        #expect(GraphicStyleDefaults.overrides(of: rect, in: world.state).isEmpty && world.document.undoTitle == "Undo Clear Override")
        #expect(StyleOverrideMarks.clear(item, list: AttributesListModel(document: world.document, selection: Selection([SelectionID(rect)]))) == nil)
        // The outline's menu on an overridden row.
        _ = await world.document.perform(AddAppearance.fill([rect])).value
        await world.settle()
        let marked = AttributesListModel(document: world.document, selection: Selection([SelectionID(rect)]))
        let controller = PropertiesOutlineController()
        var cleared: AttributeRowItem?
        controller.actions.clearOverride = { cleared = $0 }
        let (scroll, outline) = controller.makeOutline()
        _ = scroll
        controller.update(PropertiesTree(list: marked), selected: .root, in: outline)
        let index = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? PropertiesItem).flatMap { controller.row($0.key)?.item?.list } == .fills }
        let row = try #require(index)
        let menu = try #require(controller.overrideMenu(at: row, in: outline))
        #expect(menu.items.first?.title == "Clear Override")
        controller.clearOverride(nil)
        #expect(cleared?.list == .fills)
        #expect(controller.overrideMenu(at: 0, in: outline) == nil, "the root row has none")
        let rowItem = try #require(outline.item(atRow: row))
        let cell = try #require(controller.outlineView(outline, viewFor: nil, item: rowItem) as? PropertiesRowCell)
        #expect(!cell.overrideDot.isHidden)
        // Focus: a remote redefinition does not take the first responder from a field.
        let field = NSTextField(string: "typing")
        let window = TestWindow.make(NSRect(x: 0, y: 0, width: 400, height: 600))
        let host = NSHostingView(rootView: AttributesListView(model: marked, state: AttributesState()))
        host.frame = NSRect(x: 0, y: 100, width: 400, height: 500)
        window.contentView?.addSubview(host)
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let responder = window.firstResponder
        let style = try #require(GraphicStyleResolver(world.state).style(of: rect, in: world.state))
        _ = await world.document.receiveRemote(RedefineGraphicStyle(style, from: .object(rect), in: world.state))
        host.rootView = AttributesListView(model: AttributesListModel(document: world.document, selection: Selection([SelectionID(rect)])), state: AttributesState())
        host.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === responder)
        window.close()
    }

    // MARK: Chart elements (DRAW-034)

    static func chart(_ world: TypeWorld) async throws -> OpID {
        let chart = try #require(await world.document.perform(CreateChart(size: Size(width: 200, height: 100), transform: .translation(x: 100, y: 100))).value?.createdObjects.first)
        _ = await world.document.perform(ImportChartData(chart, table: [["", "North", "South"], ["\"Q1\"", "3", "5"], ["\"Q2\"", "4", "2"]])).value
        await world.settle()
        return chart
    }

    /// The pasteboard centre of the first bar of series `series` in category `category`.
    static func bar(_ world: TypeWorld, _ chart: OpID, series: Int = 0, category: Int = 0) throws -> (point: Point, key: ChartElementKeyRef) {
        let (elements, transform) = try #require(ChartElementHits.layout(chart, in: world.state))
        let table = Chart(world.state.props(chart).chart).table
        let column = try #require(elements.first { $0.id.role == .column && $0.id.series == table.series[series].id && $0.id.index == table.categories[category].id })
        let bounds = try #require(column.item.bounds)
        return (transform.apply(Point(x: bounds.midX, y: bounds.midY)), ChartElementKeyRef(series: OpID(table.series[series].id), index: OpID(table.categories[category].id)))
    }

    @Test func recoloringABarWritesOneOverrideAndSuperselectOneForTheSeries() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let chart = try await Self.chart(world)
        let context = Self.context(world)
        let subselect = Box(false)
        let handles = ChartElementHandles { subselect.value }
        let (point, key) = try Self.bar(world, chart)
        #expect(!handles.press(Self.event(world, point), context: context), "the Pointer leaves it to the tool")
        subselect.value = true
        #expect(handles.press(Self.event(world, point), context: context))
        let picks = ChartElementPicks.of(world.document)
        #expect(picks.chart == chart && picks.keys == [key] && world.window.selection.selection.ids == [SelectionID(chart)])
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
        // Swatches: one override for the bar.
        let selection = ActiveSelection(model: world.window.selection.model, document: world.document)
        let workspace = ColorWorkspace(selection: selection, preferences: world.setup.environment.preferences)
        let red = Appearances.inline(red: 1, green: 0, blue: 0)
        _ = await workspace.apply(red, name: "Red")?.value
        await world.settle()
        var model = Chart(world.state.props(chart).chart)
        #expect(model.props.overrides.count == 1 && model.liveOverrides(for: model.table)[key]?.appearance.fills.first?.settings.basic.color == red)
        // Superselect (~): the series, one more override; the Superselect command learns it.
        let registry = CommandRegistry()
        try registry.register(Command(id: ContextMenuCatalog.ID.superselect, title: "Superselect", action: .responder("superselect:")))
        try registry.register(Command(id: ContextMenuCatalog.ID.ungroup, title: "Ungroup", action: .perform {}))
        let commands = ChartPictographs.commands(registry) { [weak window = world.window] in window }
        #expect(commands.count == 2)
        if case .perform(let run) = commands[1].action { run() }
        #expect(picks.keys == [ChartElementKeyRef(series: key.series)])
        #expect(!picks.superselect(), "already the series")
        if case .perform(let run) = commands[1].action { run() }
        workspace.target = .stroke
        _ = await workspace.apply(red)?.value
        await world.settle()
        model = Chart(world.state.props(chart).chart)
        #expect(model.props.overrides.count == 2)
        // Changing the data keeps the style.
        _ = await world.document.perform(SetChartCell(chart, row: OpID(model.table.categories[0].id), column: OpID(model.table.series[0].id), text: "9")).value
        await world.settle()
        model = Chart(world.state.props(chart).chart)
        #expect(model.liveOverrides(for: model.table)[key]?.appearance.fills.isEmpty == false)
        // The Object panel section.
        let panel = ObjectPanelModel(document: world.document, selection: world.window.selection.selection)
        let section = try #require(panel.chartElement)
        #expect(section.title == "Series" && section.scale == 100)
        ChartElementSectionView.strokeWidth(section, panel)(3)
        ChartElementSectionView.scale(section, panel)(150)
        await world.settle()
        let rotated = try #require(ObjectPanelModel(document: world.document, selection: world.window.selection.selection).chartElement)
        ChartElementSectionView.rotation(rotated, panel)(30)
        await world.settle()
        let final = try #require(ObjectPanelModel(document: world.document, selection: world.window.selection.selection).chartElement)
        #expect(final.strokeWidth == 3 && final.scale == 150 && final.rotation == 30)
        ExtraSections.register(into: .standard)
        PanelRendering.host(ChartElementSectionView(section: final, model: panel))
        #expect(ChartElementStyling.strokeWidth(-1, chart: chart, keys: [key], state: world.state) == nil)
        #expect(ChartElementStyling.transform(scale: 0, rotation: 0, chart: chart, keys: [key]) == nil)
        // Shift adds and removes; a click off the chart clears.
        let (other, otherKey) = try Self.bar(world, chart, series: 1, category: 1)
        #expect(handles.press(Self.event(world, other, .shift), context: context))
        #expect(picks.keys.contains(otherKey) && picks.keys.count == 2)
        #expect(handles.press(Self.event(world, other, .shift), context: context))
        #expect(picks.keys.count == 1)
        #expect(!handles.press(Self.event(world, Point(x: 5, y: 5)), context: context))
        #expect(picks.isEmpty)
        #expect(ChartElementStyling.colorCommand(world.document, selection: [chart], target: .fill, color: red) == nil)
        subselect.value = false
        #expect(!handles.press(Self.event(world, point), context: context))
        // Superselect without picks falls through to the window's.
        if case .perform(let run) = commands[1].action { run() }
    }

    @Test func pictographsRepeatOrStretchAndCanBeRemoved() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let chart = try await Self.chart(world)
        let (point, _) = try Self.bar(world, chart)
        let handles = ChartElementHandles { true }
        #expect(handles.press(Self.event(world, point), context: Self.context(world)))
        // Copy some artwork, then the sheet.
        let star = await world.document.addRectangles([Rect(x: 400, y: 400, width: 10, height: 10)])
        world.window.selection.model.set(Selection(star))
        world.window.objectEditing.copy()
        world.window.selection.model.set(Selection([SelectionID(chart)]))
        ChartPictographs.showsSheet = false
        defer { ChartPictographs.showsSheet = true }
        let registry = ExtensionRegistry()
        let descriptors = ChartPictographs.extensions(existing: registry) { [weak window = world.window] in window }
        #expect(descriptors.count == 2 && descriptors.allSatisfy { $0.validate?().isEnabled == true })
        _ = descriptors[0].run?(nil)
        let sheet = try #require(ChartPictographs.presented)
        sheet.contentView?.layoutSubtreeIfNeeded()
        let model = PictographModel(artwork: nil, repeating: false)
        #expect(model.summary.hasPrefix("No artwork"))
        model.pasteIn = { ChartPictographs.pasted(world.window) }
        model.paste()
        #expect(model.summary == "1 object")
        var copiedOut: ClipboardPayload?
        model.copyOut = { copiedOut = $0 }
        model.copy()
        #expect(copiedOut != nil)
        PanelRendering.host(PictographSheet(model: model, commit: {}, cancel: {}))
        let (target, key) = try #require(ChartPictographs.target(world.window))
        _ = await world.window.objectEditing.perform(try #require(ChartPictographs.command(chart: target, key: key, artwork: model.artwork, repeating: true))).value
        await world.settle()
        #expect(RemoveChartPictograph.source(chart, key: key, in: world.state) != nil)
        #expect(ChartPictographs.current(chart, key: key, state: world.state)?.nodes.count == 1)
        #expect(ChartPictographs.command(chart: chart, key: key, artwork: nil, repeating: false) == nil)
        // Repeating stacks copies with a clipped partial; off stretches one copy.
        let artwork: [DisplayItem] = [.path(PathItem(path: DisplayPath(rect: Rect(x: 0, y: 0, width: 10, height: 10)), appearance: .fillAndStroke(fill: .white, stroke: .black)))]
        let repeated = try #require(ChartLayout.pictograph(artwork, in: Rect(x: 0, y: 0, width: 10, height: 35), repeating: true))
        let stretched = try #require(ChartLayout.pictograph(artwork, in: Rect(x: 0, y: 0, width: 10, height: 35), repeating: false))
        #expect(Self.leafCount(repeated) > Self.leafCount(stretched))
        // Remove Pictograph.
        _ = descriptors[1].run?(nil)
        await world.settle()
        #expect(RemoveChartPictograph.source(chart, key: key, in: world.state) == nil)
        #expect(ChartPictographs.remove(on: world.window) == nil)
        world.window.selection.model.clear()
        #expect(ChartPictographs.present(on: world.window) == nil && descriptors[0].validate?().isEnabled == false)
        _ = descriptors[0].run?(nil)
        #expect(ChartPictographs.extensions(existing: ExtensionRegistry(descriptors: [])) { nil }.isEmpty)
    }

    static func leafCount(_ item: DisplayItem) -> Int {
        if case .group(let group) = item { return group.children.map(leafCount).reduce(0, +) }
        return 1
    }

    @Test func ungroupMakesPathsAndAgainstACellEditOffersRestore() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let chart = try await Self.chart(world)
        world.window.selection.model.set(Selection([SelectionID(chart)]))
        let base = world.state
        let table = Chart(base.props(chart).chart).table
        var core = DocumentCore(state: base, replica: 1)
        let edit = try #require(try core.perform(SetChartCell(chart, row: OpID(table.categories[0].id), column: OpID(table.series[0].id), text: "7"),
                                                 recording: DocumentCore.Recording(limit: 1, now: Date()))?.change)
        let registry = CommandRegistry()
        var fellThrough = false
        try registry.register(Command(id: ContextMenuCatalog.ID.ungroup, title: "Ungroup", validation: { .disabled("x") }, action: .perform { fellThrough = true }))
        let command = try #require(ChartPictographs.commands(registry) { world.window }.first)
        #expect(command.validation().isEnabled)
        let local = await ChartPictographs.ungroup(world.window)?.value
        await world.settle()
        #expect(!world.state.isLive(chart) && world.window.selection.selection.count == 1)
        #expect(world.state.nodeKind(world.window.selection.selection.ids[0].opID) == .group)
        _ = await world.document.receive(edit).value
        await world.settle()
        let divergence = Divergence.measure(local: [try #require(local)], remote: [edit], state: world.state, gap: .seconds(3600))
        let entry = try #require(divergence.entries.first { $0.node == chart })
        #expect(entry.kind == .editVsDelete && entry.actions.contains(.restore))
        _ = await world.document.perform(ReviewModel.restore(entry)).value
        await world.settle()
        #expect(world.state.isLive(chart), "Restore brings the chart back beside the group")
        // Not charts: the command's own action.
        world.window.selection.model.clear()
        #expect(!command.validation().isEnabled)
        if case .perform(let run) = command.action { run() }
        #expect(fellThrough && ChartPictographs.ungroup(world.window) == nil)
        ChartPictographs.perform(.responder("noSuchSelector:"))
    }

    // MARK: Share and Services (IO-037)

    static func share(_ world: TypeWorld) throws -> (ShareExport, URL) {
        let folder = TestEnvironment.temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exports = ExportController(defaults: TestDefaults().defaults)
        exports.progressDelay = .zero
        let quick = QuickExport(exports: exports, preferences: world.setup.environment.preferences)
        quick.optionHeld = { false }
        let share = ShareExport(quickExport: quick)
        share.folder = { folder.appendingPathComponent(UUID().uuidString) }
        return (share, folder)
    }

    @Test func shareSendsThePresetsFilesForTheSelectionElseThePage() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let square = await world.document.addRectangles([Rect(x: 50, y: 50, width: 40, height: 40)])
        world.window.selection.model.set(Selection(square))
        let (share, folder) = try Self.share(world)
        defer { try? FileManager.default.removeItem(at: folder) }
        var mail: [URL] = []
        share.present = { files, _ in mail = files }
        let files = await share.share(world.window)?.value ?? []
        #expect(files.count == 3 && mail == files, "the PNG 1× 2× 3× set, to Mail")
        #expect(files.allSatisfy { $0.pathExtension == "png" && FileManager.default.fileExists(atPath: $0.path) })
        #expect(share.quickExport.settings(share.quickExport.preset, for: world.window).what == .selection)
        world.window.selection.model.clear()
        #expect(share.quickExport.settings(share.quickExport.preset, for: world.window).what == .currentPage)
        // Option: the preset chosen; cancelled: nothing.
        share.quickExport.optionHeld = { true }
        share.quickExport.choosePreset = { $0.first { $0.name == "SVG for web" } }
        world.window.selection.model.set(Selection(square))
        let svg = await share.share(world.window)?.value ?? []
        #expect(svg.first?.pathExtension == "svg")
        share.quickExport.choosePreset = { _ in nil }
        #expect(share.share(world.window) == nil)
        // The command.
        let command = share.command { [weak window = world.window] in window }
        #expect(command.validation().title == "Share As…")
        share.quickExport.optionHeld = { false }
        #expect(share.command(window: { world.window }).validation().title == "Share" && !share.command(window: { nil }).validation().isEnabled)
        if case .perform(let run) = command.action { run() }
        _ = await share.running?.value
        // A failed export offers nothing.
        share.folder = { URL(fileURLWithPath: "/nonexistent/share") }
        mail = []
        _ = await share.share(world.window)?.value
        #expect(mail.isEmpty)
    }

    @Test func servicesOutOfferTextForATextSelectionAndArtworkForObjects() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let requestor = ServicesRequestor(window: world.window)
        #expect(requestor.offeredTypes.isEmpty && requestor.requestor(sendType: .string, returnType: nil) == nil, "nothing selected")
        let square = await world.document.addRectangles([Rect(x: 50, y: 50, width: 40, height: 40)])
        world.window.selection.model.set(Selection(square))
        #expect(requestor.requestor(sendType: .png, returnType: nil) as AnyObject? === requestor)
        #expect(requestor.requestor(sendType: .string, returnType: nil) == nil && requestor.requestor(sendType: .png, returnType: .string) == nil)
        let pasteboard = NSPasteboard.withUniqueName()
        #expect(requestor.writeSelection(to: pasteboard, types: [.png]))
        #expect(pasteboard.data(forType: .png) != nil)
        #expect(!requestor.writeSelection(to: pasteboard, types: [.string]))
        let node = try await world.block("Send this")
        await world.edit(node, select: 0..<4)
        #expect(requestor.requestor(sendType: .string, returnType: nil) as AnyObject? === requestor && requestor.requestor(sendType: .png, returnType: nil) == nil)
        #expect(requestor.writeSelection(to: pasteboard, types: [.string, .png]))
        #expect(pasteboard.string(forType: .string) == "Send")
        ServicesRequestor.register()
        ExtrasWindowParts.attach(world.window)
        #expect(world.window.canvas.validRequestor(forSendType: .string, returnType: nil) != nil)
        requestor.window = nil
        #expect(requestor.offeredTypes.isEmpty && !requestor.writeSelection(to: pasteboard, types: [.string]))
    }

    @Test func servicesInPlaceInTheFrontDocumentOrAskWhichOne() async throws {
        let world = TypeWorld()
        defer { world.close() }
        var placed: [(NSPasteboard, DocumentWindowController)] = []
        var asked = 0
        let front = Box<DocumentWindowController?>(world.window)
        let provider = ServicesProvider(window: { front.value }, place: { pasteboard, window in
            placed.append((pasteboard, window))
            return true
        }, choose: { done in
            asked += 1
            done(world.window)
        })
        provider.optionHeld = { false }
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Hello", forType: .string)
        var error: NSString?
        provider.addToDocument(pasteboard, userData: nil, error: &error)
        _ = await provider.running?.value
        #expect(placed.count == 1 && placed[0].1 === world.window && asked == 0)
        #expect(placed[0].0.string(forType: .string) == "Hello", "a copy of what was sent")
        front.value = nil
        provider.receive(pasteboard)
        _ = await provider.running?.value
        #expect(asked == 1 && placed.count == 2)
        front.value = world.window
        provider.optionHeld = { true }
        provider.receive(pasteboard)
        _ = await provider.running?.value
        #expect(asked == 2)
        let cancelling = ServicesProvider(window: { nil }, place: { _, _ in true }, choose: { done in done(nil) })
        cancelling.receive(pasteboard)
        #expect(cancelling.running == nil)
        // The paste path: a PNG through the import path, text through the richest paste.
        let imports = ImportController(preferences: world.setup.environment.preferences)
        let edit = EditFeatures(preferences: world.setup.environment.preferences)
        edit.window = { [weak window = world.window] in window }
        let image = NSPasteboard.withUniqueName()
        image.clearContents()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.setData(bitmap.representation(using: .png, properties: [:]), forType: .png)
        let before = world.document.changeCount
        #expect(await ServicesProvider.place(image, on: world.window, imports: imports, edit: edit))
        await world.settle()
        #expect(world.document.changeCount == before + 1, "one change")
        #expect(await ServicesProvider.place(pasteboard, on: world.window, imports: imports, edit: edit))
        let nothing = NSPasteboard.withUniqueName()
        nothing.clearContents()
        nothing.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.nothing"))
        #expect(!(await ServicesProvider.place(nothing, on: world.window, imports: imports, edit: edit)))
    }

    @Test func theChooserOpensTheChosenOrANewDocument() {
        ServiceChooser.showsWindow = false
        defer { ServiceChooser.showsWindow = true }
        var opened: [String?] = []
        var done = 0
        let panel = ServiceChooser.present(documents: [("a", "Alpha"), ("b", "Beta")], open: { id in
            opened.append(id)
            return nil
        }, done: { _ in done += 1 })
        #expect(panel.identifier?.rawValue == "services-chooser")
        panel.contentView?.layoutSubtreeIfNeeded()
        var chosen: [String?] = []
        ServiceDocumentChooser.choosing("a") { chosen.append($0) }()
        ServiceDocumentChooser.choosing(ServiceDocumentChooser.newDocument) { chosen.append($0) }()
        #expect(chosen == ["a", "new"])
        PanelRendering.host(ServiceDocumentChooser(documents: [("a", "Alpha")], choose: { _ in }, cancel: {}))
        // The closures the panel's view runs.
        let hosting = panel.contentViewController as? NSHostingController<ServiceDocumentChooser>
        hosting?.rootView.choose("b")
        hosting?.rootView.choose(ServiceDocumentChooser.newDocument)
        hosting?.rootView.cancel()
        #expect(opened == ["b", nil] && done == 3)
    }

    // MARK: Reading order (OBJ-041)

    @Test func dragsAndCanvasClicksEachWriteOneChangeAndUndoOneAtATime() async throws {
        let world = TypeWorld()
        defer { world.close() }
        ReadingOrderFeatures.showsPanel = false
        defer { ReadingOrderFeatures.showsPanel = true }
        let origin = world.document.activePage.origin
        let squares = await world.document.addRectangles((0..<3).map { Rect(x: origin.x + 100 + Double($0) * 60, y: origin.y + 100, width: 40, height: 40) }).map(\.opID)
        let command = ReadingOrderFeatures.command { [weak window = world.window] in window }
        #expect(command.validation().isEnabled && !ReadingOrderFeatures.command(window: { nil }).validation().isEnabled)
        if case .perform(let run) = command.action { run() }
        let model = try #require(ReadingOrderFeatures.model(of: world.window))
        #expect(ReadingOrderFeatures.show(on: world.window) === model)
        #expect(model.order == squares, "stacking order without an override")
        #expect(model.rows.count == 3 && model.badges.map(\.number) == [1, 2, 3])
        // A drag: one change.
        _ = await model.move(from: IndexSet(integer: 2), to: 0).value
        #expect(model.order == [squares[2], squares[0], squares[1]] && world.document.undoTitle == "Undo Reading Order")
        // Canvas clicks: each a change; Shift-click to the end.
        let handles = try #require(world.window.toolManager.handleLayers.first as? ReadingOrderHandles)
        let context = Self.context(world)
        let center = { (node: OpID) -> Point in
            let bounds = Objects.bounds(of: node, in: world.state)!
            return Point(x: bounds.midX, y: bounds.midY)
        }
        #expect(handles.press(Self.event(world, center(squares[1])), context: context))
        await world.settle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.order.first == squares[1])
        #expect(handles.press(Self.event(world, center(squares[0])), context: context))
        await world.settle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.order == [squares[1], squares[0], squares[2]])
        #expect(handles.press(Self.event(world, center(squares[1]), .shift), context: context))
        await world.settle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.order.last == squares[1])
        #expect(handles.press(Self.event(world, Point(x: 2000, y: 2000)), context: context), "the panel takes every click")
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
        handles.drag(Self.event(world, .zero), context: context)
        handles.release(Self.event(world, .zero), context: context)
        handles.cancel(context: context)
        // Undo one at a time.
        _ = await world.document.undo().value
        await world.settle()
        model.refresh()
        #expect(model.order == [squares[1], squares[0], squares[2]])
        // Later objects append; Use Stacking Order discards the arrangement.
        let later = await world.document.addRectangles([Rect(x: origin.x + 100, y: origin.y + 200, width: 40, height: 40)])[0].opID
        model.refresh()
        #expect(model.order.last == later)
        _ = await model.useStackingOrder().value
        #expect(model.order == squares + [later])
        #expect(model.click(OpID(counter: 9999, replica: 9), toEnd: false) == nil)
        PanelRendering.host(ReadingOrderView(model: model, done: {}))
        ReadingOrderView.moving(model)(IndexSet(integer: 0), 2)
        ReadingOrderFeatures.close(world.window)
        #expect(ReadingOrderFeatures.model(of: world.window) == nil && handles.model != nil)
        ReadingOrderFeatures.close(world.window)
        let empty = ReadingOrderHandles()
        #expect(!empty.press(Self.event(world, .zero), context: context))
        empty.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
    }
}

