import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The app half of this build's model features: the install, menu:View[Show Links] (WEB-004),
/// Simplify, Correct Direction and Fractalize (DRAW-030, FX-031), the Combine form's btn:[Expand]
/// (FX-049), a lens's *Snapshot* (ATTR-020), the Inspect panel's snippets (COLLAB-036), the PDF
/// export's *Comments as annotations* (COLLAB-033) and the data-merge review rows (DATA-023).
@Suite(.serialized) @MainActor struct ModelGlueFeaturesTests {
    // MARK: The app

    @Test func theFeaturesAreWiredIntoTheApp() async throws {
        let suite = TestDefaults()
        defer { suite.remove() }
        let delegate = AppDelegate(layoutStore: nil, defaults: suite.defaults)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(delegate.activeDocumentWindow)
        defer { window.close() }
        #expect(delegate.tools.makeTool(PerspectiveTool.id) is PerspectiveTool)
        let glue = delegate.modelGlue
        #expect(glue.envelopes != nil && glue.perspective != nil && glue.links != nil && glue.pathAlter != nil)
        for id in [EnvelopeFeatures.ID.create, ContextMenuCatalog.ID.attachToPath, StandardCommands.ID.perspectiveShow, LinkOverlayFeatures.id,
                   PathAlterFeatures.ID.correctDirection, ContextMenuCatalog.ID.simplify, ContextMenuCatalog.ID.removeOverlap] {
            #expect(delegate.commands.command(id)?.validation().reason != WireTuner.Command.placeholderReason, "\(id)")
        }
        #expect(delegate.toolbars.extensions.descriptor(for: "fractalize")?.isStub == false)
        #expect(delegate.toolbars.extensions.descriptor(for: "correctDirection")?.isStub == false)
        #expect(delegate.toolbars.extensions.descriptor(for: "removeOverlap")?.isStub == false)
        #expect(delegate.toolbars.extensions.descriptor(for: "trap")?.isStub == false)
        #expect(delegate.panels.descriptor(for: InspectPanel.id)?.title == "Inspect")
        #expect(glue.inspect.window() === window && glue.inspect.blob(Data()) == nil)
        #expect(glue.links?.index(window).carriers.isEmpty == true)
        #expect(delegate.exports.commentAuthor(window, "acct-1") == "acct-1")
        // The window's selection and document changes reach the Inspect panel.
        let revision = glue.inspect.revision
        window.onSelectionChange?(window)
        await window.documentHandle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(glue.inspect.revision > revision)
        #expect(CanvasHandleLayers.standard().contains { $0 is EnvelopeOutlineHandles })
    }

    // MARK: Show Links

    @Test func showLinksTintsLinkedObjectsAndTheTooltipNamesTheURL() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = LinkOverlayFeatures(window: { [weak window = world.window] in window })
        features.install(commands: world.commands)
        let window = world.window
        #expect(world.commands.command(LinkOverlayFeatures.id)?.validation() == .checked(false))
        #expect(features.links(window) == nil && !features.isShown(window))
        let rect = try #require(await world.document.addRectangles([Rect(x: 40, y: 40, width: 60, height: 40)]).first)
        _ = await world.document.perform(SetLink([rect.opID], url: "https://example.com")).value
        #expect(world.commands.perform(LinkOverlayFeatures.id))
        #expect(features.isShown(window) && world.commands.command(LinkOverlayFeatures.id)?.validation() == .checked(true))
        let overlay = features.overlay(window)
        #expect(overlay.marks.count == 1 && overlay.marks[0].url == "https://example.com")
        features.draw(in: world.bitmap(), window: window)
        window.canvas.furnitureDrawer?(world.bitmap())
        // Hovering the object shows its URL; leaving it clears the tooltip.
        window.canvas.onPointer?(Point(x: 60, y: 60))
        #expect(window.canvas.toolTip == "https://example.com")
        features.hover(Point(x: 300, y: 300), window: window)
        #expect(window.canvas.toolTip == nil)
        features.hover(nil, window: window)
        // A change to the links re-reads the marks.
        _ = await world.document.perform(SetLink([rect.opID], url: "https://example.org")).value
        #expect(features.overlay(window).marks.first?.url == "https://example.org")
        features.refresh(window)
        features.refresh(window)
        // Off: nothing drawn, no tooltip, and changes are not read.
        features.toggle(window)
        #expect(!features.isShown(window) && window.canvas.toolTip == nil)
        features.draw(in: world.bitmap(), window: window)
        features.hover(Point(x: 60, y: 60), window: window)
        _ = await world.document.perform(SetLink([rect.opID], url: "")).value
        #expect(features.attach(window) === features.links(window))
        let other = LinkOverlayFeatures(window: { nil })
        #expect(!other.command().validation().isEnabled)
        if case .perform(let run) = other.command().action { run() }
        other.refresh(window)
    }

    /// WEB-004's done-when: toggling Show Links rebuilds no display list and repaints no tile; a
    /// link change repaints only the linked object's tiles and only its area of the overlay.
    @Test func showLinksRepaintsOnlyTheChangedObject() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = LinkOverlayFeatures(window: { [weak window = world.window] in window })
        features.install(commands: world.commands)
        let window = world.window
        let ids = await world.document.addRectangles([Rect(x: 40, y: 40, width: 60, height: 40), Rect(x: 300, y: 200, width: 50, height: 50)])
        let (near, far) = (try #require(ids.first).opID, try #require(ids.last).opID)
        _ = await world.document.perform(SetLink([near], url: "https://near.example")).value
        _ = await world.document.perform(SetLink([far], url: "https://far.example")).value
        world.document.invalidation.flush()
        let list = world.document.displayList
        let flushes = world.document.invalidation.flushCount
        features.toggle(window)
        #expect(features.isShown(window) && features.overlay(window).marks.count == 2)
        features.toggle(window)
        features.toggle(window)
        #expect(world.document.invalidation.flushCount == flushes && world.document.displayList == list, "no rebuild, no tile repainted")
        // A link change: the tiles under that object only, and its area of the overlay.
        let before = features.overlay(window)
        var regions: [DirtyRegion] = []
        world.document.invalidation.onFlush = { _, region in regions.append(region) }
        defer { world.document.invalidation.onFlush = nil }
        _ = await world.document.perform(SetLink([near], url: "https://other.example")).value
        world.document.invalidation.flush()
        let nearBounds = try #require(world.document.scene.object(near)?.bounds)
        let farBounds = try #require(world.document.scene.object(far)?.bounds)
        let dirty = regions.flatMap { region in region.canvases.flatMap { region.rects(for: $0) } }
        #expect(!dirty.isEmpty && dirty.allSatisfy { $0.intersects(nearBounds) && !$0.intersects(farBounds) })
        #expect(features.overlay(window).marks.contains { $0.url == "https://other.example" })
        features.links(window)?.overlay = before
        let repainted = try #require(features.refresh(window))
        let viewport = window.canvas.viewport
        #expect(repainted.count == 2 && repainted.allSatisfy { $0.contains(LinkOverlayFeatures.viewRect(nearBounds, viewport: viewport).insetBy(dx: 4, dy: 4)) })
        #expect(repainted.allSatisfy { !$0.intersects(LinkOverlayFeatures.viewRect(farBounds, viewport: viewport)) })
        #expect(features.refresh(window) == [], "nothing changed: nothing repaints")
        features.links(window)?.overlay = nil
        #expect(features.refresh(window) == nil, "nothing to compare with: the whole layer")
        #expect(LinkOverlayFeatures(window: { nil }).refresh(window) == [])
        window.canvas.setNeedsFurnitureDisplay(in: [.null, CGRect(x: 1, y: 1, width: 4, height: 4)])
    }

    // MARK: Path clean-ups

    @Test func simplifyPreviewsWithApplyAndWritesOnOK() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = PathAlterFeatures(target: world.target, store: world.preferences, sheets: world.sheets())
        let extensions = ExtensionRegistry()
        features.install(commands: world.commands, extensions: extensions)
        let simplify = ContextMenuCatalog.ID.simplify
        #expect(world.commands.command(simplify)?.validation().reason == DistortFeatures.noPath)
        // A wobbly line of many points.
        let points = (0...40).map { Point(x: Double($0) * 5, y: 100 + ($0.isMultiple(of: 2) ? 0.3 : -0.3)) }
        let path = try #require(await world.document.addPath(points))
        world.select([path.opID])
        #expect(world.commands.perform(simplify))
        let model = try #require(features.simplify)
        #expect(world.presented.value.last?.identifier?.rawValue == PathAlterFeatures.sheet && model.amount == 50)
        #expect(model.pointCounts.before == 41 && model.pointCounts.after < 41)
        model.apply()
        #expect(model.previewing && world.document.isPreviewing)
        _ = await model.confirm().value
        #expect(!world.document.isPreviewing && world.document.undoTitle == "Undo Simplify" && features.simplify == nil)
        #expect(world.preferences[PathAlterFeatures.amount] == 50)
        // Cancel after Apply puts the paths back.
        _ = features.showSimplify(world.editing)
        let again = try #require(features.simplify)
        again.amount = 80
        again.apply()
        again.cancel()
        #expect(!world.document.isPreviewing && features.simplify == nil)
        // The sheet renders and its field writes the amount.
        let fourth = try #require(features.showSimplify(world.editing))
        SimplifySheet.applying(fourth)()
        SimplifySheet.cancelling(fourth)()
        let fifth = try #require(features.showSimplify(world.editing))
        SimplifySheet.confirming(fifth)()
        await world.document.settle()
        let third = try #require(features.showSimplify(world.editing))
        Render.view(SimplifySheet(model: third))
        SimplifySheet.text(third).wrappedValue = "140"
        #expect(third.amount == 100)
        SimplifySheet.text(third).wrappedValue = "x"
        #expect(SimplifySheet.text(third).wrappedValue == "100")
        third.cancel()
        // Repeat and Cmd-click pass the amount the sheet captured; without it the sheet opens.
        let count = world.presented.value.count
        #expect(extensions.descriptor(for: "simplify")?.run?(nil) == nil && world.presented.value.count == count + 1)
        features.simplify?.cancel()
        #expect(extensions.descriptor(for: "simplify")?.run?(["amount": "100"]) == ["amount": "100"])
        await world.document.settle()
        // Nothing selected: no sheet.
        world.select([])
        #expect(features.showSimplify(world.editing) == nil)
        PathAlterFeatures.simplify(world.editing, amount: 50)
        let none = PathAlterFeatures(target: { nil }, store: world.preferences)
        #expect(none.commands().allSatisfy { !$0.validation().isEnabled })
        for command in none.commands() { if case .perform(let run) = command.action { run() } }
        #expect(none.extensionDescriptors(existing: ExtensionRegistry(descriptors: [])).isEmpty)
        for descriptor in none.extensionDescriptors(existing: ExtensionRegistry()) { _ = descriptor.run?(nil) }
    }

    @Test func correctDirectionAndFractalizeRunFromTheMenuAndTheToolbar() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = PathAlterFeatures(target: world.target, store: world.preferences, sheets: world.sheets())
        let extensions = ExtensionRegistry()
        features.install(commands: world.commands, extensions: extensions)
        let square = try #require(await world.document.addPath([Point(x: 0, y: 0), Point(x: 90, y: 0), Point(x: 90, y: 90), Point(x: 0, y: 90)], closed: true))
        world.select([square.opID])
        #expect(extensions.validation(ofExtension: "fractalize").isEnabled)
        #expect(extensions.perform("fractalize"))
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Fractalize" && world.document.path(square)?.contours[0].points.count == 16)
        #expect(world.commands.perform(PathAlterFeatures.ID.correctDirection))
        #expect(extensions.perform("correctDirection"))
        await world.document.settle()
        world.select([])
        #expect(!extensions.validation(ofExtension: "correctDirection").isEnabled)
    }

    @Test func removeOverlapRunsFromTheMenuAndTheToolbar() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = PathAlterFeatures(target: world.target, store: world.preferences, sheets: world.sheets())
        let extensions = ExtensionRegistry()
        features.install(commands: world.commands, extensions: extensions)
        let id = ContextMenuCatalog.ID.removeOverlap
        #expect(world.commands.command(id)?.validation().reason == PathAlterFeatures.noClosedPath)
        #expect(extensions.descriptor(for: "removeOverlap")?.isStub == false)
        // A bow tie: one self-crossing closed contour becomes two.
        let bowtie = try #require(await world.document.addPath([Point(x: 0, y: 0), Point(x: 90, y: 90), Point(x: 90, y: 0), Point(x: 0, y: 90)], closed: true))
        let line = try #require(await world.document.addPath([Point(x: 0, y: 200), Point(x: 90, y: 290), Point(x: 90, y: 200)]))
        world.select([line.opID])
        #expect(!extensions.validation(ofExtension: "removeOverlap").isEnabled, "an open path")
        world.select([bowtie.opID])
        #expect(world.commands.command(id)?.validation() == .enabled)
        #expect(world.commands.perform(id))
        await world.document.settle()
        #expect(world.document.undoTitle == "Undo Remove Overlap" && world.document.path(bowtie)?.contours.count == 2)
        _ = await world.document.undo().value
        #expect(world.document.path(bowtie)?.contours.count == 1)
        #expect(extensions.perform("removeOverlap"))
        await world.document.settle()
        #expect(world.document.path(bowtie)?.contours.count == 2)
    }

    @Test func trapOpensItsSheetWritesOnOKAndRepeats() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let features = PathAlterFeatures(target: world.target, store: world.preferences, sheets: world.sheets())
        let extensions = ExtensionRegistry()
        features.install(commands: world.commands, extensions: extensions)
        #expect(extensions.descriptor(for: "trap")?.isStub == false)
        #expect(extensions.validation(ofExtension: "trap").reason == PathAlterFeatures.noTrapPair)
        func filled(_ level: Double, x: Double) async throws -> OpID {
            var appearance = Wiretuner_Doc_V1_AppearanceProps()
            appearance.fills = [Appearances.basicFill(red: level, green: level, blue: level)]
            return try #require(await world.document.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 20, height: 20),
                                                                         transform: .translation(x: x, y: 0), appearance: appearance)).value?.createdObjects.first)
        }
        let back = try await filled(0.2, x: 0)
        let front = try await filled(0.8, x: 10)
        world.select([back, front])
        #expect(extensions.validation(ofExtension: "trap").isEnabled)
        // Without settings the sheet opens.
        #expect(extensions.descriptor(for: "trap")?.run?(nil) == nil)
        let model = try #require(features.trap)
        #expect(world.presented.value.last?.identifier?.rawValue == PathAlterFeatures.trapSheet)
        #expect(model.width == TrapCommand.defaultWidth && model.tint == TrapCommand.defaultTint && !model.maximum && !model.reverse)
        Render.view(TrapSheet(model: model))
        TrapSheet.number({ model.width }, { model.width = $0 }, range: TrapCommand.widths).wrappedValue = "40"
        #expect(model.width == TrapCommand.widths.upperBound)
        TrapSheet.number({ model.width }, { model.width = $0 }, range: TrapCommand.widths).wrappedValue = "x"
        model.width = 1
        TrapSheet.method(model).wrappedValue = 0
        #expect(model.maximum && TrapSheet.method(model).wrappedValue == 0)
        TrapSheet.method(model).wrappedValue = 1
        model.reverse = true
        _ = await model.confirm().value
        #expect(world.document.undoTitle == "Undo Trap" && features.trap == nil)
        #expect(world.preferences[PathAlterFeatures.trapWidth] == 1 && world.preferences[PathAlterFeatures.trapReverse])
        // Repeat passes the settings back; Cancel writes nothing.
        let parameters = PathAlterFeatures.parameters(TrapModel(document: world.document, nodes: [back, front], width: 0.5, maximum: true, tint: 50,
                                                                reverse: false) { _ in })
        #expect(extensions.descriptor(for: "trap")?.run?(parameters) == parameters)
        await world.document.settle()
        #expect(PathAlterFeatures.trapCommand([back], ["width": "x"]) == nil)
        let again = try #require(features.showTrap(world.editing))
        TrapSheet.cancelling(again)()
        #expect(features.trap == nil)
        let third = try #require(features.showTrap(world.editing))
        TrapSheet.confirming(third)()
        await world.document.settle()
        world.select([back])
        #expect(features.showTrap(world.editing) == nil)
    }

    // MARK: Expand and Snapshot
    // MARK: Expand and Snapshot
    // MARK: Expand and Snapshot

    @Test func theCombineFormsExpandAndTheLensSnapshot() async throws {
        let fixture = AttributeFixture()
        let rects = await fixture.document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 40), Rect(x: 20, y: 20, width: 40, height: 40)])
        let group = try #require(await fixture.document.perform(GroupObjects(rects.map(\.opID))).value?.createdObjects.first)
        fixture.ids = [SelectionID(group)]
        await EffectEditorTests.add(.combine, fixture)
        let model = EffectEditorTests.model(fixture)
        #expect(model.expandableGroups == [group])
        AttributeFixture.render(EffectEditorView(model: model))
        EffectEditorView.expanding(model)()
        await fixture.document.settle()
        #expect(fixture.document.undoTitle == "Undo Expand Combine" && !fixture.document.state.isLive(group))
        #expect(model.expandCombine() == nil, "the group is gone")
        // A lens: Snapshot on captures what it shows; off returns it to live.
        let lensed = await fixture.document.addRectangles([Rect(x: 0, y: 0, width: 80, height: 80)])[0]
        let row = AppearanceEditing.stack(lensed.opID, in: fixture.document.state)[0]
        _ = await fixture.document.perform(SetAttributeKind([(node: lensed.opID, row: row)], fill: .lens)).value
        let fill = FillEditorModel(context: fixture.context(0, ids: [lensed]), pasteboard: fixture.pasteboard)
        #expect(fill.setSnapshot(true) is SnapshotLens)
        _ = await fixture.document.perform(fill.setSnapshot(true)).value
        #expect(fixture.document.undoTitle == "Undo Snapshot" && FillEditorModel(context: fixture.context(0, ids: [lensed]), pasteboard: fixture.pasteboard).snapshot == true)
        _ = await fixture.document.perform(fill.setSnapshot(false)).value
        #expect(FillEditorModel(context: fixture.context(0, ids: [lensed]), pasteboard: fixture.pasteboard).snapshot == false)
    }

    // MARK: Inspect

    @Test func theInspectPanelShowsLayoutCodeAndCopiesPNGs() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let model = InspectPanelModel()
        model.pasteboard = world.pasteboard
        #expect(model.object == nil && model.copyPNG(scale: 1) == nil && !model.copyCode(.css))
        Render.view(InspectPanelBody(model: model))
        model.window = { [weak window = world.window] in window }
        #expect(model.object == nil)
        let rects = await world.document.addRectangles([Rect(x: 10, y: 20, width: 100, height: 50), Rect(x: 200, y: 20, width: 30, height: 30)])
        world.select([rects[0].opID])
        model.touch()
        let object = try #require(model.object)
        #expect(object.shape == .rectangle)
        let layout = model.layout(object)
        #expect(layout.map(\.label) == ["X", "Y", "Width", "Height"] && layout[2].value == "100px")
        for tab in InspectPanelModel.Tab.allCases {
            #expect(!model.code(tab, for: object).isEmpty)
            #expect(model.copyCode(tab) && world.pasteboard.string(forType: .string) == model.code(tab, for: object))
        }
        #expect(model.copied == "Copied Swift")
        model.notation = .oklch
        model.unit = .millimeters
        model.scale = 2
        #expect(model.code(.css, for: object).contains("oklch"))
        #expect(model.copy("100px", what: "Width") && model.copied == "Copied Width")
        let one = try #require(model.copyPNG(scale: 1))
        let two = try #require(model.copyPNG(scale: 2))
        let image1 = try #require(NSBitmapImageRep(data: one)), image2 = try #require(NSBitmapImageRep(data: two))
        #expect(image2.pixelsWide == image1.pixelsWide * 2 && world.pasteboard.data(forType: .png) == two)
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 900))
        InspectPanelBody.copying(model, "1", "X")()
        InspectPanelBody.copyingCode(model, .svg)()
        InspectPanelBody.copyingPNG(model, 3)()
        // An object on the page measures from the page's corner.
        let page = world.document.activePage.rect
        let onPage = await world.document.addRectangles([Rect(x: page.minX + 5, y: page.minY + 7, width: 10, height: 10)])
        world.select(onPage.map(\.opID))
        model.unit = .points
        model.touch()
        let measured = model.layout(try #require(model.object)).first?.value
        #expect(measured == "4.5pt" || measured == "5pt")
        // Several objects inspect as one group.
        world.select(rects.map(\.opID))
        model.touch()
        #expect(model.object?.shape == .other && model.copied == nil)
        #expect(InspectPanel.descriptor(model: model).id == InspectPanel.id)
    }

    /// COLLAB-037's rest: the value sections, the remembered unit and scale, kbd:[Option]-click to
    /// save a PNG.
    @Test func theInspectPanelReadsValueSectionsRemembersUnitAndScaleAndSavesPNGs() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let suite = TestDefaults()
        defer { suite.remove() }
        let model = InspectPanelModel(defaults: suite.defaults)
        model.pasteboard = world.pasteboard
        model.window = { world.window }
        #expect(model.unit == .pixels && model.scale == 1)
        model.unit = .millimeters
        model.scale = 3
        let reopened = InspectPanelModel(defaults: suite.defaults)
        #expect(reopened.unit == .millimeters && reopened.scale == 3, "remembered on this Mac")
        let rects = await world.document.addRectangles([Rect(x: 10, y: 20, width: 100, height: 50)])
        world.select([rects[0].opID])
        model.touch()
        let object = try #require(model.object)
        let readout = model.readout(object)
        #expect(!readout.colors.isEmpty && !readout.fills.isEmpty && readout.text == nil)
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 1200))
        // Text reads its typography and text.
        let text = try #require(await world.document.addText("Inspect me", at: Point(x: 300, y: 300)))
        world.select([text])
        model.touch()
        let words = model.readout(try #require(model.object))
        #expect(words.text == "Inspect me" && !words.typography.isEmpty)
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 1200))
        // Option-click on a PNG button saves it; a cancelled panel saves nothing.
        let url = FileManager.default.temporaryDirectory.appending(component: "inspect-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        model.optionDown = { true }
        model.chooseDestination = { _ in url }
        #expect(model.png(scale: 1) != nil && FileManager.default.fileExists(atPath: url.path) && model.copied == "Saved \(url.lastPathComponent)")
        model.chooseDestination = { _ in URL(filePath: "/no/such/place/x.png") }
        #expect(model.savePNG(scale: 1) == nil && model.copied == "The PNG could not be saved")
        model.chooseDestination = { _ in nil }
        #expect(model.savePNG(scale: 1) == nil)
        model.optionDown = { false }
        #expect(model.png(scale: 2) != nil && model.copied?.hasPrefix("Copied") == true)
        // A custom scale, kept between 0.1× and 16×.
        InspectPanelBody.customScale(model).wrappedValue = 1.5
        #expect(model.scale == 1.5 && InspectPanelModel.scaleTitle(1.5) == "1.5×" && InspectPanelModel.scaleTitle(2) == "2×")
        Render.view(InspectPanelBody(model: model), size: CGSize(width: 360, height: 1200))
        model.setCustomScale(99)
        #expect(model.scale == 16)
        model.setCustomScale(.nan)
        #expect(model.scale == 1 && InspectPanelBody.customScale(model).wrappedValue == 1)
    }

    // MARK: Export

    @Test func pdfExportCarriesCommentThreadsWhenAsked() async throws {
        let world = GlueWorld()
        defer { world.close() }
        let exports = ExportController(defaults: world.preferences.defaults)
        exports.commentAuthor = { _, account in account == "acct-1" ? "Priya" : account }
        let page = world.document.activePage
        _ = await world.document.perform(CreateThread(at: page.rect.center, page: nil, author: "acct-1", body: CommentBody("Check this"),
                                                      in: world.state)).value
        var settings = ExportSettings()
        settings.format = .pdf
        let sheet = ExportSheetModel(context: exports.context(for: world.window), settings: settings, presets: exports.presets, registry: exports.registry)
        #expect(exports.capture(settings, model: sheet, from: world.window).scene.comments.isEmpty, "off by default")
        settings.options.pdf.commentsAsAnnotations = true
        let comments = exports.capture(settings, model: sheet, from: world.window).scene.comments
        #expect(comments.count == 1 && comments[0].comments.first?.author == "Priya" && comments[0].comments.first?.text == "Check this")
        settings.options.pdf.standard = .pdfX4_2010
        #expect(exports.capture(settings, model: sheet, from: world.window).scene.comments.isEmpty, "PDF/X allows no annotations")
        sheet.settings.options.pdf.commentsAsAnnotations = true
        Render.view(Form { PDFOptionsForm(model: sheet) })
    }

    // MARK: Review

    @Test func theReviewListsDataMergeRowsWithTheirChoices() async throws {
        let document = DocumentHandle.memory(title: "Merge")
        document.pages = [Rect(x: 0, y: 0, width: 100, height: 100), Rect(x: 0, y: 200, width: 100, height: 100), Rect(x: 0, y: 400, width: 100, height: 100)]
        await document.settle()
        let pages = document.pageList.pages.map(\.id)
        var review = ReviewModel(recovered: SalvageReport(reason: .conflict))
        review.entries = []
        #expect(ReviewSheetModel.mergeRunsName(MergeRunConflict(page: pages[0], mine: MergeRun(label: "", replica: 1, pages: [pages[1], pages[2]], objects: []),
                                                                theirs: MergeRun(label: "", replica: 2, pages: [], objects: []))) == "Two merge runs: 2 pages and 0 pages")
        let conflict = MergeRunConflict(page: pages[0], mine: MergeRun(label: "Merge 1 record to pages", replica: 1, pages: [pages[1]], objects: []),
                                        theirs: MergeRun(label: "Merge 1 record to pages", replica: 2, pages: [pages[2]], objects: []))
        review.mergeRuns = [conflict]
        review.removedFields = [FieldRemovedEntry(field: OpID(counter: 99, replica: 2), name: "city", uses: 3, deletedLocally: true),
                                FieldRemovedEntry(field: OpID(counter: 98, replica: 2), name: "zip", uses: 1, deletedLocally: false)]
        let harness = ReviewHarness()
        let model = ReviewSheetModel(review: review, merged: document.state, context: harness.context(document))
        #expect(model.filter == .conflicts && model.filterTitle(.conflicts) == "Conflicts (3)")
        #expect(model.rows.map(\.name) == ["Two merge runs: 1 page and 1 page", "Field “city” removed with 3 bindings", "Field “zip” removed with 1 binding"])
        #expect(model.rows.map(\.kind) == ["Both merged", "Removed by you", "Removed by someone else"])
        #expect(model.dataChoices == MergeRunConflict.Choice.allCases.map(\.title) && model.actions.isEmpty)
        Render.view(ReviewSheetView(model: model), size: CGSize(width: 800, height: 560))
        // Keep both writes nothing when the runs are already in order; Remove theirs deletes their pages.
        #expect(model.performData(MergeRunConflict.Choice.keepBoth.title) == nil)
        #expect(model.performData("Nonsense") == nil)
        let removed = try #require(model.performData(MergeRunConflict.Choice.removeTheirs.title))
        _ = await removed.value
        #expect(!document.state.isLive(pages[2]) && model.isReviewed(conflict.id))
        // A removed field's Restore.
        model.select(review.removedFields[0].id)
        #expect(model.dataChoices == ["Restore"])
        _ = model.performData("Restore")
        ReviewSheetView.data(model, "Restore")()
        await document.settle()
        // An object row has no data choices.
        model.select(nil)
        model.setFilter(.mine)
        #expect(model.dataChoices.isEmpty && model.performData("Restore") == nil)
    }

    @Test func theReviewTellsWhenAllPagesWereRemoved() async throws {
        let document = DocumentHandle.memory(title: "Pages")
        var review = ReviewModel(recovered: SalvageReport(reason: .conflict))
        review.zeroPages = true
        let model = ReviewSheetModel(review: review, merged: document.state, context: ReviewHarness().context(document))
        #expect(model.filter == .conflicts && model.rows.map(\.name) == ["All pages were removed; a page was added."])
        #expect(model.rows.first?.data == .zeroPages && model.rows.first?.kind == "Removed by both")
        #expect(model.dataChoices.isEmpty && model.actions.isEmpty && model.performData("Restore") == nil)
        Render.view(ReviewSheetView(model: model), size: CGSize(width: 800, height: 560))
    }
}
