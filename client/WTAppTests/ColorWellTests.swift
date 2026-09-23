import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A memory document (with its default swatches), a selection over it and a colour workspace
/// whose sheets are collected instead of shown.
@MainActor
final class ColorPanelFixture {
    let document: DocumentHandle
    let selectionModel = SelectionModel()
    let selection: ActiveSelection
    let suite = TestDefaults()
    let preferences: PreferenceStore
    let workspace: ColorWorkspace
    private(set) var sheets: [NSWindow] = []
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests.colors.\(UUID().uuidString)"))

    init(title: String = "Colors") {
        document = DocumentHandle.memory(title: title)
        preferences = PreferenceStore(defaults: suite.defaults)
        selection = ActiveSelection(model: selectionModel, document: document)
        workspace = ColorWorkspace(selection: selection, preferences: preferences)
        workspace.presentSheet = { [unowned self] window in self.sheets.append(window) }
    }

    var state: EngineState { document.state }
    var list: SwatchList { SwatchList(document.state) }

    /// The identifier of the last sheet presented.
    var lastSheet: String? { sheets.last?.identifier?.rawValue }

    @discardableResult
    func add(_ color: RenderColor, name: String = "", spot: Bool = false, group: String = "") async -> OpID {
        let change = await document.perform(AddSwatch(color, name: name, spot: spot, group: group)).value
        return ColorWellActions.created(by: change!)
    }

    @discardableResult
    func tint(of base: OpID, _ percent: Double) async -> OpID {
        ColorWellActions.created(by: (await document.perform(AddTintSwatch(of: base, percent: percent)).value)!)
    }

    /// A tint whose base `base` is not live (a concurrent removal): written directly.
    @discardableResult
    func orphanTint(of base: OpID, cached: RenderColor = RenderColor(red: 0.5, green: 0, blue: 0.5)) async -> OpID {
        let props = SwatchFields.values { swatch in
            swatch.parent.id = base.proto
            swatch.parent.cached = ColorValues.cached(cached)
            swatch.tintPercent = 50
        }
        let change = await document.perform(OpsCommand("Tint", ops: [Ops.create(parent: SwatchFields.collection, position: [0xF0], props: props)])).value
        return ColorWellActions.created(by: change!)
    }

    /// A filled rectangle (white fill, black stroke), its fill set to `fill` when given.
    @discardableResult
    func rect(fill: Wiretuner_Doc_V1_ColorRef? = nil) async -> OpID {
        let id = (await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)]))[0].opID
        if let fill { _ = await document.perform(ApplyColor([id], target: .fill, color: fill)).value }
        return id
    }

    func select(_ ids: [OpID]) {
        selectionModel.set(Selection(ids.map(SelectionID.init)))
    }

    /// The fill colour reference of `node`'s topmost Basic fill.
    func fill(_ node: OpID) -> Wiretuner_Doc_V1_ColorRef? {
        AppearanceEditing.entries(node, in: state).last { $0.kind == .fill(.basic) }.flatMap(AttributeFields.color)
    }

    /// A change from another replica, applied as the sync client would deliver it.
    func receive(_ command: any WTModel.Command) async throws {
        var other = DocumentCore(state: document.state, replica: 0xBEEF)
        let outcome = try other.perform(command, recording: DocumentCore.Recording(limit: 10, now: Date()))
        _ = await document.receive(try #require(outcome?.change)).value
    }

    func settle() async {
        await document.settle()
    }

    /// Writes `payload` to the fixture's pasteboard.
    func put(_ payload: ColorRefPasteboard) {
        ColorDrag.write(payload, to: pasteboard)
    }

    /// Writes a plain `NSColor` to the fixture's pasteboard.
    func put(_ color: NSColor) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.color], owner: nil)
        color.write(to: pasteboard)
    }

    static func render<V: View>(_ view: V, width: Double = 420, height: Double = 700) {
        AttributeFixture.render(view, width: width, height: height)
    }
}

/// COLOR-011's colour control, COLOR-008's pasteboard type and drops, the workspace, and the new
/// document template.
@Suite @MainActor struct ColorWellTests {
    static let red = RenderColor(red: 1, green: 0, blue: 0)

    // MARK: Workspace

    @Test func theWorkspaceKeepsOneColourListPerDocumentAndReadsThePreferences() async throws {
        let fixture = ColorPanelFixture()
        let workspace = fixture.workspace
        await fixture.settle()
        let swatches = try #require(workspace.swatches)
        #expect(workspace.swatches === swatches, "one model per document")
        #expect(swatches.list.swatches.map(\.name) == ["White", "Black", "Registration"], "a new document has the defaults")
        #expect(workspace.swatches(for: nil) == nil)
        #expect(workspace.defaultSpace == .displayP3 && workspace.autoRename && workspace.splitColorBox)
        _ = fixture.preferences.set("srgb", for: PreferenceCatalog.Colors.defaultColorSpace)
        _ = fixture.preferences.set(false, for: PreferenceCatalog.Colors.autoRename)
        _ = fixture.preferences.set(false, for: PreferenceCatalog.Colors.splitColorBox)
        #expect(workspace.defaultSpace == .sRGB && !workspace.autoRename && !workspace.splitColorBox)
        let bare = ColorWorkspace(selection: ActiveSelection())
        #expect(bare.defaultSpace == .displayP3 && bare.autoRename && bare.splitColorBox && bare.swatches == nil && bare.perform(SortSwatches()) == nil)
        #expect(workspace.apply(ColorResolver.none) == nil, "nothing selected")
        let rect = await fixture.rect()
        fixture.select([rect])
        #expect(workspace.selectedNodes == [rect])
        _ = await workspace.apply(ColorResolver.inline(Self.red), target: .fill)?.value
        #expect(fixture.fill(rect) == ColorResolver.inline(Self.red))
        // A reopened model gets a fresh list.
        let other = DocumentHandle.memory(id: fixture.document.id, title: "Again")
        fixture.selection.document = other
        #expect(workspace.swatches !== swatches)
    }

    @Test func sheetsArePresentedAndDismissedByIdentifier() {
        let fixture = ColorPanelFixture()
        fixture.workspace.present(Text("Hi"), title: "Sheet", identifier: "test.sheet")
        #expect(fixture.lastSheet == "test.sheet" && fixture.workspace.sheets["test.sheet"] != nil)
        fixture.workspace.dismiss("test.sheet")
        fixture.workspace.dismiss("test.sheet")
        #expect(fixture.workspace.sheets.isEmpty)
        // A sheet on a real window ends through its parent.
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        fixture.workspace.presentSheet = { parent.beginSheet($0) }
        fixture.workspace.present(Text("Hi"), title: "Sheet", identifier: "attached")
        fixture.workspace.dismiss("attached")
        let loose = NSWindow(contentViewController: NSHostingController(rootView: Text("Loose")))
        ColorWorkspace.beginSheet(loose)
        loose.orderOut(nil)
        parent.close()
        _ = ColorAction.run { 1 }()
    }

    // MARK: Pasteboard

    @Test func thePayloadAndNSColorsRoundTripThroughThePasteboard() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(displayP3Red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let payload = ColorRefPasteboard(swatch: grape, list: fixture.list, document: fixture.document.id)
        fixture.put(payload)
        #expect(ColorDrag.read(from: fixture.pasteboard, defaultSpace: .displayP3) == payload)
        #expect(NSColor(from: fixture.pasteboard)?.colorSpace == .displayP3, "other applications get an NSColor in Display P3")
        fixture.put(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(ColorDrag.read(from: fixture.pasteboard, defaultSpace: .displayP3)?.color == Self.red)
        fixture.put(NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1))
        #expect(ColorDrag.read(from: fixture.pasteboard, defaultSpace: .sRGB)?.color?.space == .displayP3, "a P3 NSColor stays P3")
        let generic = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(ColorDrag.color(generic, defaultSpace: .displayP3).space == .displayP3)
        #expect(ColorDrag.color(generic, defaultSpace: .sRGB).space == .sRGB, "gamut-mapped into sRGB")
        fixture.pasteboard.clearContents()
        #expect(ColorDrag.read(from: fixture.pasteboard, defaultSpace: .sRGB) == nil)
        #expect(ColorDrag.nsColor(Self.red).colorSpace == .sRGB)
        // A drag item carries both types.
        let provider = ColorDrag.itemProvider(payload)
        #expect(provider.registeredTypeIdentifiers.contains(ColorRefPasteboard.typeIdentifier))
        #expect(provider.registeredTypeIdentifiers.contains(NSPasteboard.PasteboardType.color.rawValue))
        let data: Data? = await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.color.rawValue) { data, _ in done.resume(returning: data) }
        }
        #expect(data != nil)
        #expect(ColorDrag.itemProvider(ColorRefPasteboard(ref: ColorResolver.none, color: nil)).registeredTypeIdentifiers == [ColorRefPasteboard.typeIdentifier])
    }

    // MARK: The well

    @Test func theWellShowsEachKindOfColour() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        let state = fixture.state
        let mixed = ColorWellModel(ref: nil, state: state)
        #expect(mixed.chip == .mixed && mixed.caption == "Mixed" && mixed.valueText.isEmpty && !mixed.isValueEditable && mixed.dragPayload == nil)
        let none = ColorWellModel(ref: ColorResolver.none, state: state)
        #expect(none.chip == .none && none.caption == "None" && none.menu.map(\.title).first == "None" && none.reference(for: .detach) == nil)
        let unnamed = ColorWellModel(ref: ColorResolver.inline(Self.red), state: state, documentID: fixture.document.id)
        #expect(unnamed.chip == .color(Self.red) && unnamed.caption.isEmpty && unnamed.valueText == "#FF0000" && unnamed.isValueEditable)
        #expect(unnamed.menu.contains { $0.kind == .addToSwatches } && !unnamed.menu.contains { $0.kind == .detach })
        #expect(unnamed.dragPayload?.document == fixture.document.id)
        let named = ColorWellModel(ref: fixture.list.resolver.reference(to: grape), state: state)
        #expect(named.caption == "Grape" && named.valueText == "Grape" && !named.isValueEditable && named.swatch?.id == grape)
        #expect(named.menu.contains { $0.kind == .detach } && named.menu.contains { $0.title == "Grape" })
        #expect(named.reference(for: .detach) == ColorResolver.inline(RenderColor(red: 0.5, green: 0, blue: 0.5)))
        #expect(named.reference(for: .swatch(grape)) == fixture.list.resolver.reference(to: grape))
        #expect(named.reference(for: .none) == ColorResolver.none && named.reference(for: .addToSwatches) == nil)
        #expect(ColorWellModel.parse("oklch(62% 0.22 25)")?.inline.space == .oklab && ColorWellModel.parse("nonsense") == nil)
        // A removed swatch: the reference reads its cache and offers Restore.
        let ref = fixture.list.resolver.reference(to: grape)
        _ = await fixture.document.perform(RemoveSwatches([grape])).value
        let dangling = ColorWellModel(ref: ref, state: fixture.state)
        #expect(dangling.removedSwatch?.name == "Grape" && dangling.menu.last?.title == "Restore \"Grape\"")
        #expect(dangling.chip == .color(RenderColor(red: 0.5, green: 0, blue: 0.5)))
        var anonymous = ref
        anonymous.swatch.id = OpID(counter: 999, replica: 9).proto
        #expect(ColorWellModel(ref: anonymous, state: fixture.state).removedSwatch?.name == "Color")
    }

    @Test func theWellsActionsWriteRestoreAndAdd() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        var committed: [Wiretuner_Doc_V1_ColorRef] = []
        let actions = ColorWellActions(document: fixture.document) { committed.append($0) }
        let unnamed = ColorWellModel(ref: ColorResolver.inline(Self.red), state: fixture.state)
        #expect(actions.run(.none, model: unnamed) == nil && committed == [ColorResolver.none])
        // Add to Swatches…: a swatch under its default name, then the targets point at it.
        await actions.run(.addToSwatches, model: unnamed)?.value
        let added = try #require(fixture.list.named("255r 0g 0b"))
        #expect(committed.last == fixture.list.resolver.reference(to: added.id))
        #expect(ColorWellActions(document: fixture.document) { _ in }.run(.addToSwatches, model: ColorWellModel(ref: ColorResolver.none, state: fixture.state)) == nil)
        #expect(ColorWellActions { _ in }.run(.restore(grape), model: unnamed) == nil, "no document")
        // Restore "Grape".
        let ref = fixture.list.resolver.reference(to: grape)
        _ = await fixture.document.perform(RemoveSwatches([grape])).value
        await actions.run(.restore(grape), model: ColorWellModel(ref: ref, state: fixture.state))?.value
        #expect(fixture.list[grape] != nil)
        // Drops.
        #expect(!actions.drop(from: fixture.pasteboard), "nothing on the pasteboard")
        fixture.put(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        #expect(actions.drop(from: fixture.pasteboard) && committed.last == ColorResolver.inline(RenderColor(red: 0, green: 0, blue: 1)))
        fixture.put(ColorRefPasteboard(swatch: grape, list: fixture.list, document: fixture.document.id))
        #expect(actions.drop(from: fixture.pasteboard) && committed.last == ref, "a swatch of this document stays a reference")
        var loose: [Wiretuner_Doc_V1_ColorRef] = []
        #expect(ColorWellActions { loose.append($0) }.drop(from: fixture.pasteboard) && loose.first?.inline.rgb.r == 0.5)
    }

    @Test func aSwatchFromAnotherDocumentIsCreatedThenReferenced() async throws {
        let source = ColorPanelFixture(title: "Source")
        let target = ColorPanelFixture(title: "Target")
        await source.settle()
        await target.settle()
        let grape = await source.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        await source.tint(of: grape, 40)
        await source.tint(of: grape, 20)
        await target.add(RenderColor(red: 0, green: 1, blue: 0), name: "Grape")
        let payload = ColorRefPasteboard(swatch: grape, list: source.list, document: source.document.id)
        #expect(ColorDrop.needsImport(payload, into: target.document.id) && !ColorDrop.needsImport(payload, into: source.document.id))
        var committed: Wiretuner_Doc_V1_ColorRef?
        target.put(payload)
        #expect(ColorWellActions(document: target.document) { committed = $0 }.drop(from: target.pasteboard))
        try await Task.sleep(for: .milliseconds(200))
        await target.settle()
        let list = target.list
        let imported = try #require(list.swatches.first { $0.library == ColorDrop.origin(source.document.id) && !$0.isTint })
        #expect(imported.id != grape && imported.name == "128r 0g 128b", "fresh id; the clashing name becomes the mix values")
        #expect(list.tints(of: imported.id).count == 2, "the tints came along")
        #expect(committed == list.resolver.reference(to: imported.id))
        // A payload whose library names nothing it can find falls back to the colour.
        var broken = payload
        broken.library?.colors[0].key = String(repeating: "k", count: 200)
        let fallback = await ColorDrop.reference(for: broken, in: target.document)
        #expect(fallback.inline.rgb.r == 0.5)
    }

    @Test func theWellAndPaletteRender() async throws {
        let fixture = ColorPanelFixture()
        await fixture.settle()
        let grape = await fixture.add(RenderColor(red: 0.5, green: 0, blue: 0.5), name: "Grape")
        var committed: [Wiretuner_Doc_V1_ColorRef] = []
        let actions = ColorWellActions(document: fixture.document) { committed.append($0) }
        let model = ColorWellModel(ref: ColorResolver.inline(Self.red), state: fixture.state, documentID: fixture.document.id)
        for chip in [ColorWellModel.Chip.color(Self.red), .none, .mixed] { ColorPanelFixture.render(ColorChipView(chip: chip)) }
        ColorPanelFixture.render(ColorWellView(title: "Color", model: model, actions: actions, identifier: "well"))
        ColorPanelFixture.render(AttributeColorControl(title: "Fill", color: nil, identifier: "fill", document: fixture.document) { committed.append($0) })
        ColorPanelFixture.render(AttributeColorControl(title: "Fill", color: ColorResolver.none, identifier: "fill") { committed.append($0) })
        UserDefaults.standard.set(PaletteKind.cubes.rawValue, forKey: PaletteKind.defaultsKey)
        ColorPanelFixture.render(ColorPaletteView(model: model) { committed.append($0) })
        UserDefaults.standard.set(PaletteKind.swatches.rawValue, forKey: PaletteKind.defaultsKey)
        ColorPanelFixture.render(ColorPaletteView(model: model) { committed.append($0) })
        UserDefaults.standard.removeObject(forKey: PaletteKind.defaultsKey)
        #expect(PaletteKind.allCases.map(\.title) == ["Swatches", "Color Cubes"] && ColorCubes.colors.count == 216 && ColorCubes.colors[215] == .white)
        // The view's closures.
        ColorWellView.running(.swatch(grape), model, actions)()
        #expect(committed.last == fixture.list.resolver.reference(to: grape))
        let state = ColorWellState()
        state.togglePalette()
        ColorWellView.picking(actions, state)(ColorResolver.none)
        #expect(!state.showsPalette && committed.last == ColorResolver.none)
        ColorWellView.committing(actions)("#00ff00")
        #expect(committed.last == ColorResolver.inline(RenderColor(red: 0, green: 1, blue: 0)))
        let count = committed.count
        ColorWellView.committing(actions)("not a colour")
        #expect(committed.count == count)
        // The value field follows the colour, but not while the user types (APP-007).
        let field = FieldEditor(format: ColorWellView.valueFormat, value: model.valueText)
        field.connect { ColorWellView.committing(actions)($0) }
        field.beep = {}
        #expect(field.text == "#FF0000")
        field.edit("not a colour")
        #expect(!field.submit() && field.text == "not a colour", "refused input stays for the user to fix")
        field.bind(selection: "#0000FF")
        #expect(field.text == "not a colour" && field.remoteChanged)
        field.edit("#00ff00")
        #expect(field.submit() && committed.count == count + 1 && !field.remoteChanged)
        #expect(ColorWellView.dragging(model)().registeredTypeIdentifiers.contains(ColorRefPasteboard.typeIdentifier))
        #expect(ColorWellView.dragging(ColorWellModel(ref: nil, state: fixture.state))().registeredTypeIdentifiers.isEmpty)
        fixture.put(NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1))
        #expect(ColorWellView.dropping(actions, pasteboard: fixture.pasteboard)([]))
        _ = ColorWellView.dropping(actions)
        ColorPaletteView.choosing(ColorResolver.none) { committed.append($0) }()
        var hex = "0000ff"
        ColorPaletteView.submitting(Binding(get: { hex }, set: { hex = $0 })) { committed.append($0) }()
        #expect(committed.last == ColorResolver.inline(RenderColor(red: 0, green: 0, blue: 1)))
        hex = "#zz"
        ColorPaletteView.submitting(Binding(get: { hex }, set: { hex = $0 })) { committed.append($0) }()
        #expect(committed.last == ColorResolver.inline(RenderColor(red: 0, green: 0, blue: 1)))
    }

    // MARK: The new-document template

    @Test func newDocumentsGetTheDefaultSwatchesAsTheirFirstChange() async throws {
        let memory = DocumentOpener.memoryDocument()
        #expect(SwatchList(memory.state).swatches.count == 3 && !memory.canUndo)
        // A store opened for a new document: the template is written; not an undo step.
        let empty = WTModel.Document(memory: DocumentCore(state: EngineState(), replica: 0x77))
        await DocumentOpener.applyTemplate(to: empty)
        #expect(SwatchList(empty.state).swatches.map(\.name) == ["White", "Black", "Registration"] && !empty.canUndo)
        #expect(empty.lastChange?.label == "Default colors")
        let test = TestEnvironment()
        var environment = test.document
        environment.openModel = { _ in WTModel.Document(memory: DocumentCore(state: EngineState(), replica: 0x78)) }
        let created = environment.makeDocument(title: "New", isNew: true)
        await created.settle()
        #expect(SwatchList(created.state).swatches.count == 3)
        let opened = environment.makeDocument(title: "Existing")
        await opened.settle()
        #expect(SwatchList(opened.state).swatches.isEmpty, "an existing document is left alone")
        #expect(created.changeCount == 0, "the template's swatches are not drawn content")
    }
}
