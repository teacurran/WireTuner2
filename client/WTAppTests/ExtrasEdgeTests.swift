import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The edges of this batch's features (TYPE-005 ... IO-037) and their wiring into the app.
@Suite(.serialized) @MainActor struct ExtrasEdgeTests {
    static func event(_ world: TypeWorld, _ point: Point, _ modifiers: KeyModifiers = [], clicks: Int = 1) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: point, viewPoint: world.window.viewport.toView(point), modifiers: modifiers, clickCount: clicks)
    }

    static func model(_ world: TypeWorld, _ nodes: [OpID]) -> ObjectPanelModel {
        ObjectPanelModel(document: world.document, selection: Selection(nodes.map { SelectionID($0) }), textSession: world.window.objectEditing.textSession)
    }

    // MARK: Wiring

    @Test func theBatchIsWiredIntoTheApp() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer {
            TypeWindowParts.detach(window)
            window.close()
        }
        for id in [SpecialCharacterFeatures.id(.thinSpace), TextBlockFeatures.removeTransformsID, ShareExport.id, ReadingOrderFeatures.id, ContextMenuCatalog.ID.style("bold")] {
            #expect(delegate.commands.command(id) != nil, "\(id)")
        }
        #expect(delegate.toolbars.extensions.descriptor(for: TextBlockFeatures.emptyBlocksID)?.run != nil)
        #expect(delegate.toolbars.extensions.descriptor(for: ChartPictographs.pictographID)?.run != nil)
        let parts = try #require(ExtrasWindowParts.parts(of: window))
        #expect(parts.requestor != nil && parts.deselection != nil)
        #expect(ObjectStyleRow.shared?.autoApply() == true)
        #expect(window.canvas.textKeys?(TestEvents.key("a", keyCode: 0)) == false)
        #expect(window.canvas.textContextMenu?(TestEvents.key("a", keyCode: 0), .zero) == nil)
        #expect(window.canvas.servicesRequestor?(.string, nil) == nil)
        for extra in window.canvas.overlayExtras { extra(DrawingToolTests.bitmap(), window.viewport) }
        ChartElementPicks.of(window.documentHandle).onChange()
        TypeWindowParts.parts(of: window)?.rulers.view.onDoubleClick?(10)
        // Services in: the front window, or the chooser that opens a document.
        let provider = try #require(ServicesProvider.shared)
        #expect(ServicesProvider.shared === (NSApp.servicesProvider as AnyObject?))
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("From another app", forType: .string)
        #expect(await provider.place(pasteboard, window))
        ServiceChooser.showsWindow = false
        defer { ServiceChooser.showsWindow = true }
        var chosen: [DocumentWindowController?] = []
        provider.choose { chosen.append($0) }
        let chooser = try #require(ServiceChooser.panel?.contentViewController as? NSHostingController<ServiceDocumentChooser>)
        chooser.rootView.choose(ServiceDocumentChooser.newDocument)
        #expect(chosen.count == 1)
        if let opened = chosen.first ?? nil {
            TypeWindowParts.detach(opened)
            opened.close()
        }
        if let first = delegate.library.cache.recentDocuments.first {
            provider.choose { opened in
                if let opened {
                    TypeWindowParts.detach(opened)
                    opened.close()
                }
            }
            (ServiceChooser.panel?.contentViewController as? NSHostingController<ServiceDocumentChooser>)?.rootView.choose(first.id)
        }
        delegate.attachExtras(window)
    }

    // MARK: Text blocks (TYPE-005)

    @Test func resizingAndFittingAutoAndEmptyBlocks() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let context = world.window.toolManager.context
        let handles = TextBlockHandles()
        handles.drag(Self.event(world, .zero), context: context)
        handles.release(Self.event(world, .zero), context: context)
        // An auto-width block: a corner drag fixes the width too.
        let auto = try await world.block("Auto")
        let frame = try #require(TextBlockFrame(auto, document: world.document))
        let result = try #require(TextBlockResize.result(frame, corner: .bottomRight, to: frame.point(.bottomRight).offset(dx: 20, dy: 20), shift: false, option: true))
        _ = await world.document.perform(TextBlockResize.command(frame, result, state: world.state)).value
        #expect(!world.state.props(auto).text.block.autoWidth && !world.state.props(auto).text.block.autoHeight)
        // Fit: an auto width takes the natural width; a wide block with short text narrows.
        let wide = try #require(await world.document.addText("Hi", frame: .area(Rect(x: 50, y: 200, width: 300, height: 100))))
        let wideFrame = try #require(TextBlockFrame(wide, document: world.document))
        let fitWide = try #require(TextBlockResize.fit(wideFrame, document: world.document))
        _ = await world.document.perform(fitWide).value
        #expect(world.state.props(wide).text.block.width < 100)
        let natural = try await world.block("Natural", at: Point(x: 50, y: 400))
        let naturalFrame = try #require(TextBlockFrame(natural, document: world.document))
        #expect(TextBlockResize.fit(naturalFrame, document: world.document) != nil)
        // An empty fixed block: no size marks, no fit, and deselecting keeps it.
        let empty = try #require(await world.document.addText("", frame: .area(Rect(x: 400, y: 50, width: 100, height: 50))))
        let emptyFrame = try #require(TextBlockFrame(empty, document: world.document))
        #expect(TextBlockResize.sizeMarks(emptyFrame.text, node: empty, scale: 2).isEmpty)
        _ = TextBlockResize.fit(emptyFrame, document: world.document)
        #expect(TextBlockFeatures.deleteIfEmpty([empty], in: world.window) == nil)
        #expect(emptyFrame.toLocal(emptyFrame.point(.bottomLeft)).y == emptyFrame.local.maxY)
    }

    // MARK: Special characters (TYPE-012)

    @Test func typingIsRememberedWhileItLands() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("ab")
        await world.edit(node, select: 2..<2)
        let session = try #require(world.session)
        SpecialCharacterFeatures.typed("", in: session)
        SpecialCharacterFeatures.typed("xy", in: session)
        #expect(SpecialCharacterFeatures.lastTyped?.character == "y")
        #expect(SpecialCharacterFeatures.previous(in: session) == "b", "landed: the document's")
    }

    // MARK: Tabs (TYPE-024)

    @Test func tabsAtTheEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Tabs")
        let editing = TabEditing(targets: Self.model(world, [node]).textTargets, in: world.state)
        var rows: [TabDraft] = []
        let binding = Binding(get: { rows }, set: { rows = $0 })
        TabsTableSheet.adding(binding)()
        #expect(rows.first?.position == TextRulerModel.defaultSpacing && rows.first?.id == 0)
        TabsTableSheet.removing(0, binding)()
        #expect(editing.commit(rows: rows) == nil, "a new row removed writes nothing")
        let pending = TextEditingSession(document: world.document, sink: world.document, target: .pending(.point(.zero)))
        #expect(TabSheets.targets(of: pending).isEmpty)
        world.window.objectEditing.textSession = pending
        #expect(TabSheets.editTab(at: 10, window: world.window) == nil)
        world.window.objectEditing.textSession = nil
        await world.edit(node, select: 0..<0)
        TabSheets.showsSheets = false
        defer { TabSheets.showsSheets = true }
        #expect(TabSheets.editTab(at: 10, window: world.window) != nil, "no ruler: the default tolerance")
    }

    // MARK: Spacing (TYPE-027)

    @Test func spacingWhileEditingAndOnAnEmptyBlock() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let node = try await world.block("Edited words")
        await world.edit(node, select: 0..<6)
        let model = Self.model(world, [node])
        let section = try #require(model.spacing)
        #expect(section.editing)
        _ = await model.setSpacingPart(.letter, .max, 8)?.value
        world.window.objectEditing.textSession = nil
        let plain = Self.model(world, [node])
        let current = try #require(plain.spacing)
        SpacingSectionView.scale(plain)(80)
        SpacingSectionView.keepLines(plain)(3)
        SpacingSectionView.keepWithNext(current, plain).wrappedValue = true
        SpacingSectionView.noBreak(current, plain).wrappedValue = true
        SpacingSectionView.noHyphen(current, plain).wrappedValue = true
        await world.settle()
        let after = try #require(Self.model(world, [node]).spacing)
        #expect(after.horizontalScale == 80 && after.keepLines == 3 && after.keepWithNext == .on && after.noBreak == .on && after.noHyphen == .on)
    }

    // MARK: Axes and features (TYPE-046)

    @Test func variationsAtTheEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        #expect(ObjectPanelModel.effective(.on, "smcp") && !ObjectPanelModel.effective(.off, "liga"))
        let opsz = ObjectPanelModel.AxisRow(offer: FontAxisOffer(tag: "opsz", name: "Optical size", minimum: 6, defaultValue: 12, maximum: 72), value: 12, isAuto: true)
        let synthetic = ObjectPanelModel.VariationSection(family: "X", style: "Y", axes: [opsz], instances: [], instance: nil, features: [])
        #expect(ObjectPanelModel.autoAxes(synthetic) == ["opsz"])
        PanelRendering.host(VariationSectionView(section: synthetic, model: Self.model(world, [])))
        #expect(!VariationSectionView.auto(opsz, Self.model(world, [])).wrappedValue == false)
        VariationSectionView.auto(opsz, Self.model(world, [])).wrappedValue = false
        // A family that is not installed offers nothing; two families are mixed.
        let missing = try await world.block("Missing")
        _ = await world.document.perform(ApplyMark(node: missing, from: .start, to: .end, value: TextFixtureMarks.mark { $0.fontFamily = "No Such Family Here" })).value
        #expect(Self.model(world, [missing]).variations == nil)
        let variable = try await world.block("Variable axes", at: Point(x: 50, y: 300))
        _ = await world.document.perform(ApplyMark(node: variable, from: .start, to: .end, value: TextFixtureMarks.mark { $0.fontFamily = "STIX Two Text" })).value
        #expect(Self.model(world, [missing, variable]).variations == nil)
        // Part of the text at another weight: mixed value and instance.
        let head = try #require(world.state.textNode(variable)).anchor(at: 3)
        _ = await world.document.perform(ApplyMark(node: variable, from: .start, to: head, value: TextFixtureMarks.mark { $0.axes = .with { $0.axes = [.with { $0.tag = "wght"; $0.value = 600 }] } })).value
        let mixed = try #require(Self.model(world, [variable]).variations)
        #expect(mixed.axes.first?.value == nil && mixed.instance == nil)
        PanelRendering.host(VariationSectionView(section: mixed, model: Self.model(world, [variable])))
        #expect(VariationSectionView.instance(mixed, Self.model(world, [variable])).wrappedValue == TextSectionView.mixed)
        // While editing: the session's runs.
        await world.edit(variable, select: 0..<2)
        #expect(Self.model(world, [variable]).variations?.axes.first?.value == 600)
        world.window.objectEditing.textSession = nil
        #expect(FontStyleCommands.model(nil) == nil)
        world.window.selection.model.set(Selection([SelectionID(missing)]))
        _ = await Self.model(world, [missing]).setFontStyleNamed("Bold")?.value
        #expect(TextFixtureReading.style(world, missing) == "Bold")
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).setFontStyleNamed("Bold") == nil)
        // The rows' actions; two faces of one family.
        let italic = try await world.block("Italic", at: Point(x: 50, y: 500))
        _ = await world.document.perform(ApplyMark(node: italic, from: .start, to: .end, value: TextFixtureMarks.mark { $0.fontFamily = "STIX Two Text" })).value
        _ = await world.document.perform(ApplyMark(node: italic, from: .start, to: .end, value: TextFixtureMarks.mark { $0.fontStyle = "Italic" })).value
        let row = try #require(Self.model(world, [italic]).variations?.axes.first)
        AxisRowView.commit(row, Self.model(world, [italic]))(650)
        await world.settle()
        AxisRowView.reset(row, Self.model(world, [italic]))()
        await world.settle()
        _ = await Self.model(world, [italic, variable]).setFontStyleNamed("Bold")?.value
        #expect(TextFixtureReading.style(world, italic) == "Bold")
        let mukta = try await world.block("Mukta", at: Point(x: 50, y: 600))
        _ = await world.document.perform(ApplyMark(node: mukta, from: .start, to: .end, value: TextFixtureMarks.mark { $0.fontFamily = "Mukta Mahee" })).value
        _ = await Self.model(world, [mukta]).setFeature("ss01", .on)?.value
        let feature = try #require(Self.model(world, [mukta]).variations?.features.first { $0.tag == "ss01" })
        VariationSectionView.resetFeature(feature, Self.model(world, [mukta]))()
        await world.settle()
        #expect(TextFixtureReading.feature(world, mukta, "ss01") == .default)
        // The Style Behavior sheet on a style with a face, and an axis tuple edited twice.
        let normal = try #require(world.state.textStyles.normalText.flatMap { world.state.textStyles.style($0) })
        let behavior = TextStyleBehaviorModel(style: normal, in: world.state)
        #expect(StyleVariationControls.offers(behavior).axes.isEmpty, "Helvetica when the style names none")
        behavior.attrs.character.fontFamily = "STIX Two Text"
        behavior.attrs.character.fontStyle = "Bold"
        let weight = try #require(StyleVariationControls.offers(behavior).axes.first)
        let axis = StyleVariationControls.axis(weight, behavior, order: [weight])
        axis.wrappedValue = "500"
        axis.wrappedValue = "550"
        #expect(axis.wrappedValue == 550.formatted(.number))
        #expect(StyleVariationControls.feature("liga", behavior).wrappedValue == TextStyleBehaviorModel.noSelection)
    }

    // MARK: Copy attributes (TYPE-031)

    @Test func pastingWhileEditingTakesOnlyTheRange() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let source = try await world.block("Source")
        _ = await world.document.perform(ApplyMark(node: source, from: .start, to: .end, value: TextFixtureMarks.mark { $0.size = 20 })).value
        world.window.selection.model.set(Selection([SelectionID(source)]))
        #expect(TextAttributeClipboard.copy(world.window))
        let target = try await world.block("Target text", at: Point(x: 50, y: 200))
        await world.edit(target, select: 0..<3)
        let edit = EditFeatures(preferences: world.setup.environment.preferences)
        edit.window = { [weak window = world.window] in window }
        #expect(TextAttributeClipboard.commands(edit: edit) { world.window }[1].validation().isEnabled)
        _ = await TextAttributeClipboard.paste(world.window)?.value
        let text = try #require(world.state.textNode(target))
        #expect(ObjectPanelModel.size(text.values(at: 0)) == 20 && ObjectPanelModel.size(text.values(at: 5)) == 12)
    }

    // MARK: Spelling (TYPE-014)

    @Test func duplicatesStaleIssuesAndWindowsWithoutTheChecker() async throws {
        let world = TypeWorld()
        defer { world.close() }
        world.window.toolManager.select(TextTool.id)
        let node = try await world.block("the the end")
        let tool = try #require(world.window.toolManager.activeTool as? TextTool)
        tool.edit(node, at: Point(x: 60, y: 60))
        await world.settle()
        #expect(SpellingContextMenu.issue(at: .zero, in: world.window) == nil, "no checker attached")
        let parts = TypeWindowParts.attach(world.window, preferences: world.setup.environment.preferences)
        defer { TypeWindowParts.detach(world.window) }
        let stub = TypeEditingTests.StubSpelling(["the", "end"])
        parts.spelling.checker = { SpellingChecker(service: stub, options: SpellingOptions()) }
        parts.spelling.isOn = { true }
        let layout = try #require(world.document.textLayout(for: node))
        let end = try #require(layout.caret(atOffset: 7))
        let view = world.window.viewport.toView(Objects.pasteboardTransform(of: node, in: world.state).apply(end.baseline.offset(dx: 0, dy: -2)))
        let issue = try #require(SpellingContextMenu.issue(at: view, in: world.window))
        #expect(issue.kind == .duplicate)
        let menu = try #require(SpellingContextMenu.menu(at: view, in: world.window, service: stub))
        #expect(menu.items.first?.title == "Delete Repeated Word")
        _ = await world.document.perform(ReplaceText([TextMatch(node: node, range: 0..<11, first: try #require(world.state.textNode(node)).chars[0],
                                                               last: try #require(world.state.textNode(node)).chars[10])], with: "x", label: "Shorten")).value
        #expect(SpellingContextMenu.correct(issue, with: "y", in: world.window) == nil, "the word is gone")
    }

    // MARK: Swatches (TYPE-030)

    @Test func swatchTargetsAtTheEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        #expect(TextSwatchTarget.appliesTo(nil) == .text)
        let preferences = world.setup.environment.preferences
        _ = preferences.set("sideways", for: PreferenceCatalog.Colors.swatchTarget)
        #expect(TextSwatchTarget.appliesTo(preferences) == .text)
        let node = try await world.block("Stroked")
        let red = Appearances.inline(red: 1, green: 0, blue: 0)
        var stroke = TextColor.defaultStroke
        stroke.width = 3
        _ = await world.document.perform(TextColor.stroke(node: node, from: .start, to: .end, stroke)).value
        let text = try #require(world.state.textNode(node))
        #expect(TextSwatchTarget.stroke(of: text, red).width == 3)
        let empty = try await world.block("", at: Point(x: 50, y: 300))
        #expect(TextSwatchTarget.stroke(of: try #require(world.state.textNode(empty)), red).width == 1)
        #expect(TextSwatchTarget.ref(node, list: .strokes, state: world.state, appliesTo: .text) == TextColor.defaultStroke.color)
        let rect = await world.document.addRectangles([Rect(x: 300, y: 300, width: 10, height: 10)])[0].opID
        #expect(TextSwatchTarget.command([rect, node], target: .fill, color: red, name: "Red", state: world.state, appliesTo: .text) != nil)
        // No stroke: none; two blocks of different colours: mixed.
        let plain = try await world.block("Plain", at: Point(x: 50, y: 400))
        #expect(TextSwatchTarget.ref(plain, list: .strokes, state: world.state, appliesTo: .text) == ColorResolver.none)
        _ = await world.document.perform(TextColor.fill(node: plain, from: .start, to: .end, red)).value
        #expect(TextSwatchTarget.well([plain, node], target: .fill, document: world.document, appliesTo: .text)?.ref == nil)
    }

    // MARK: Style row (LIB-021)

    @Test func theStyleRowForMixedUnstyledAndDefaults() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let rects = await world.document.addRectangles([Rect(x: 50, y: 50, width: 20, height: 20), Rect(x: 100, y: 50, width: 20, height: 20)]).map(\.opID)
        let selection = ActiveSelection(model: world.window.selection.model, document: world.document, editing: world.window.objectEditing)
        let model = StylesPanelModel(selection: selection)
        // Unstyled objects: no style.
        world.window.selection.model.set(Selection(rects.map { SelectionID($0) }))
        let unstyled = try #require(ObjectStyleRowState(model))
        #expect(unstyled.style == nil && [ObjectStyleRowState.none, ObjectStyleRowState.mixed, "Normal"].contains(unstyled.name))
        // Two styles: mixed.
        _ = await world.document.perform(CreateGraphicStyle(.selection(rects[0]), name: "One", applyTo: [rects[0]])).value
        _ = await world.document.perform(CreateGraphicStyle(.selection(rects[1]), name: "Two", applyTo: [rects[1]])).value
        await world.settle()
        let mixed = try #require(ObjectStyleRowState(model))
        #expect(mixed.name == ObjectStyleRowState.mixed && mixed.style == nil)
        #expect(ObjectStyleRowActions.choice(mixed, model).wrappedValue == ObjectStyleRowState.mixed)
        #expect(ObjectStyleRowActions.drag(mixed, model).registeredTypeIdentifiers.isEmpty)
        PanelRendering.host(ObjectStyleRow(model: model))
        // The defaults: modified, redefined from them.
        world.window.selection.model.clear()
        let normal = try #require(GraphicStyleDefaults.style(in: world.state))
        _ = await world.document.perform(SelectGraphicStyleAsDefaults(normal)).value
        _ = await world.document.perform(AddAppearance.fill([WellKnown.settings])).value
        await world.settle()
        let defaults = try #require(ObjectStyleRowState(model))
        #expect(defaults.isModified)
        _ = await ObjectStyleRowActions.redefine(model)?.value
        #expect(!GraphicStyleDefaults.isModified(in: world.state))
        #expect(StyleOverrideMarks.lists(AttributesListModel(document: world.document, selection: Selection())).isEmpty)
    }

    // MARK: Charts (DRAW-034)

    @Test func chartPicksAtTheEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        let chart = try await StyleChartShareOrderTests.chart(world)
        let context = world.window.toolManager.context
        let handles = ChartElementHandles { true }
        // A legend swatch picks the series.
        let (elements, transform) = try #require(ChartElementHits.layout(chart, in: world.state))
        let swatch = try #require(elements.first { $0.id.role == .legendSwatch }?.item.bounds)
        #expect(handles.press(Self.event(world, transform.apply(Point(x: swatch.midX, y: swatch.midY))), context: context))
        let picks = ChartElementPicks.of(world.document)
        #expect(picks.keys.first?.index == nil)
        // An element: "Element"; two picks: their count, widths mixed.
        let (bar, key) = try StyleChartShareOrderTests.bar(world, chart)
        #expect(handles.press(Self.event(world, bar), context: context))
        let element = try #require(ObjectPanelModel(document: world.document, selection: world.window.selection.selection).chartElement)
        #expect(element.title == "Element")
        _ = await world.document.perform(try #require(ChartElementStyling.strokeWidth(4, chart: chart, keys: [key], state: world.state))).value
        let (other, _) = try StyleChartShareOrderTests.bar(world, chart, series: 1, category: 1)
        #expect(handles.press(Self.event(world, other, .shift), context: context))
        let two = try #require(ObjectPanelModel(document: world.document, selection: world.window.selection.selection).chartElement)
        #expect(two.title == "2 picks" && two.strokeWidth == nil)
        // Nothing selected: nothing drawn, no section.
        world.window.selection.model.clear()
        handles.draw(in: DrawingToolTests.bitmap(), viewport: world.window.viewport, context: context)
        #expect(ObjectPanelModel(document: world.document, selection: Selection()).chartElement == nil)
        #expect(ChartElementStyling.picks(nil, selection: []) == nil)
        let rect = await world.document.addRectangles([Rect(x: 600, y: 600, width: 10, height: 10)])[0].opID
        #expect(ChartElementStyling.override(key, in: rect, state: world.state) == nil)
        #expect(ChartElementHits.layout(rect, in: world.state) == nil && ChartElementHits.key(at: .zero, in: rect, state: world.state) == nil)
        #expect(ChartElementHits.outlines(key, in: rect, state: world.state).isEmpty)
        // Two charts at one place: the top one.
        let second = try await StyleChartShareOrderTests.chart(world)
        #expect(ChartElementHits.chart(at: bar, document: world.document) == second)
        // Pictographs: the shown sheet's actions, two objects, no window.
        world.window.selection.model.set(Selection([SelectionID(second)]))
        #expect(handles.press(Self.event(world, bar), context: context))
        let squares = await world.document.addRectangles([Rect(x: 700, y: 700, width: 10, height: 10), Rect(x: 720, y: 700, width: 10, height: 10)])
        world.window.selection.model.set(Selection(squares))
        world.window.objectEditing.copy()
        world.window.selection.model.set(Selection([SelectionID(second)]))
        #expect(handles.press(Self.event(world, bar), context: context))
        ChartPictographs.showsSheet = false
        defer { ChartPictographs.showsSheet = true }
        _ = ChartPictographs.present(on: world.window)
        let sheet = try #require(ChartPictographs.presentedSheet)
        sheet.model.paste()
        #expect(sheet.model.summary == "2 objects")
        sheet.model.copy()
        sheet.commit()
        await world.settle()
        let (target, seriesKey) = try #require(ChartPictographs.target(world.window))
        #expect(target == second && RemoveChartPictograph.source(second, key: seriesKey, in: world.state) != nil)
        sheet.cancel()
        #expect(ChartPictographs.selectedCharts(nil) == nil)
        let registry = CommandRegistry()
        var ran = false
        try registry.register(Command(id: ContextMenuCatalog.ID.ungroup, title: "Ungroup", action: .perform { ran = true }))
        if case .perform(let run) = ChartPictographs.commands(registry, window: { nil })[0].action { run() }
        #expect(ran)
    }

    // MARK: Reading order (OBJ-041)

    @Test func readingOrderAtTheEdges() async throws {
        let world = TypeWorld()
        defer { world.close() }
        ReadingOrderFeatures.showsPanel = false
        defer { ReadingOrderFeatures.showsPanel = true }
        let origin = world.document.activePage.origin
        let squares = await world.document.addRectangles([Rect(x: origin.x + 50, y: origin.y + 50, width: 20, height: 20)]).map(\.opID)
        _ = await world.document.perform(SetAlt(squares, alt: "A square")).value
        let model = ReadingOrderFeatures.show(on: world.window)
        #expect(model.rows.first?.alt == "A square")
        PanelRendering.host(ReadingOrderView(model: model, done: {}))
        _ = await model.move(from: IndexSet(integer: 9), to: 0).value
        ReadingOrderView.stacking(model)()
        ReadingOrderFeatures.close(world.window)
    }
}
