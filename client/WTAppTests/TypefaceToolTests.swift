import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// Find Problems (FONT-014), the preview strip (FONT-017), the Kerning Classes editor and Auto Kern
/// (FONT-021) and font units on a glyph canvas (FONT-004).
@Suite(.serialized) @MainActor struct TypefaceToolTests {
    /// A filled polygon on `handle`'s canvas (glyph space).
    @discardableResult
    static func shape(_ points: [(Double, Double)], on handle: DocumentHandle) async -> OpID? {
        var fill = Wiretuner_Doc_V1_AppearanceProps()
        fill.fills = [Appearances.basicFill(red: 0, green: 0, blue: 0)]
        let contour = NewContour(closed: true, points: points.map { VectorPoint(anchor: Point(x: $0.0, y: $0.1)) })
        return await handle.perform(CreatePath(contours: [contour], appearance: fill)).value?.createdRoots.first
    }

    /// A Basic Latin typeface with A, V, T, o, L and n drawn for kerning.
    static func kernable() async throws -> TypefaceWindowFixture {
        let fixture = await TypefaceWindowFixture.typeface()
        let shapes: [String: [(Double, Double)]] = [
            "A": [(20, 0), (480, 0), (250, -700)], "V": [(20, -700), (480, -700), (250, 0)],
            "T": [(0, -700), (500, -700), (500, -640), (280, -640), (280, 0), (220, 0), (220, -640), (0, -640)],
            "o": [(50, 0), (450, 0), (450, -450), (50, -450)], "L": [(50, 0), (450, 0), (450, -60), (110, -60), (110, -700), (50, -700)],
            "n": [(50, 0), (450, 0), (450, -500), (50, -500)],
        ]
        for (name, points) in shapes {
            let handle = try #require(GlyphCanvas.handle(for: fixture.glyph(name), of: fixture.document))
            await shape(points, on: handle)
            _ = await fixture.document.perform(SetGlyphWidth([fixture.glyph(name)], to: 500)).value
        }
        return fixture
    }

    // MARK: Kerning Classes and Auto Kern (FONT-021)

    @Test func classesMatrixExceptionsAndGuesses() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(name: "agrave", codepoints: [0xE0]), NewGlyph(name: "aacute", codepoints: [0xE1])])).value
        let document = fixture.document
        let model = KerningClassesModel(document: document) { document.perform($0) }
        defer { model.stop() }
        // Guess Classes groups a, agrave, aacute.
        model.guess()
        let guess = try #require(model.proposal.first { $0.name == "a" })
        #expect(Set(guess.members.map(model.name(of:))) == ["a", "agrave", "aacute"])
        model.proposal = [guess]
        _ = await model.applyProposal()?.value
        #expect(model.classes(.left).map(\.name) == ["a"] && model.classes(.right).map(\.name) == ["a"])
        #expect(model.applyProposal() == nil)
        // Create classes by name and by character, and move a member.
        model.newName = "O"
        model.membersText = "O Q"
        _ = await model.addClass(.right)?.value
        #expect(model.addClass(.left) == nil && model.message == "Type a class name")
        model.newName = "V"
        model.membersText = "V,W"
        _ = await model.addClass(.left)?.value
        let left = try #require(model.classes(.left).first { $0.name == "V" })
        let right = try #require(model.classes(.right).first { $0.name == "O" })
        model.selectedClass = right.id
        model.membersText = "C"
        _ = await model.addMembers()?.value
        #expect(model.kerning.kernClass(right.id)?.members.count == 3)
        model.membersText = "a"
        _ = await model.addMembers()?.value
        #expect(model.message?.hasPrefix("Moved a") == true)
        _ = await model.removeMember(fixture.glyph("a"))?.value
        #expect(model.kerning.kernClass(right.id)?.members.contains(fixture.glyph("a")) == false)
        model.membersText = "☃"
        #expect(model.addMembers() == nil)
        // A cell, its pair set, and an exception when a pair is set inside kerned classes.
        model.select(cell: left.id, right.id)
        #expect(model.cellText == "" && model.pairSet == "V O")
        model.cellText = "-40"
        _ = await model.commitCell()?.value
        #expect(model.value(left.id, right.id) == "-40")
        model.cellText = "x"
        #expect(model.commitCell() == nil)
        _ = await document.perform(SetKernPair(fixture.glyph("V"), fixture.glyph("O"), to: -60)).value
        let exception = try #require(model.exceptions.first)
        #expect(exception.left == "V" && exception.right == "O" && exception.value == -60 && exception.classValue == -40)
        _ = await model.removeException(exception)?.value
        #expect(model.exceptions.isEmpty)
        // The sheet renders; removing a class.
        PanelRendering.host(KerningClassesSheet(model: model, close: {}), size: NSSize(width: 600, height: 900))
        KerningClassesSheet.adding(.left, model)()
        KerningClassesSheet.selecting((left.id, right.id), model)()
        model.selectedClass = right.id
        KerningClassesSheet.removing(fixture.glyph("C"), model)()
        await document.settle()
        _ = await model.removeClass()?.value
        #expect(model.classes(.right).count == 1 && model.removeClass() == nil && model.removeMember(fixture.glyph("V")) == nil)
        model.cell = nil
        #expect(model.pairSet == nil && model.addMembers() == nil)
        let stale = KerningClassesModel.Exception(id: OpID(counter: 999, replica: 9), left: "x", right: "y", value: 1, classValue: 2)
        #expect(model.removeException(stale) == nil)
        KerningClassesSheet.removingException(stale, model)()
        model.proposal = []
        model.guess()
        _ = model.proposal
    }

    @Test func autoKernKernsAVToAndLTAndNotNN() async throws {
        let fixture = try await Self.kernable()
        defer { fixture.close() }
        let document = fixture.document
        let glyphs = ["A", "V", "T", "o", "L", "n"].map(fixture.glyph)
        let model = AutoKernModel(document: document, glyphs: glyphs) { document.perform($0) }
        #expect(abs(model.separation - 100) < 1)
        model.scope = .selectedGlyphs
        model.showPreview()
        let names = Set(model.preview.map { "\($0.left)\($0.right)" })
        #expect(names.isSuperset(of: ["AV", "To", "LT"]) && !names.contains("nn") && model.preview.allSatisfy { $0.value < 0 || !["AV", "To", "LT"].contains("\($0.left)\($0.right)") })
        _ = await model.apply()?.value
        let kerning = Kerning(document.state)
        #expect(kerning.value(fixture.glyph("A"), fixture.glyph("V")) < 0 && kerning.value(fixture.glyph("n"), fixture.glyph("n")) == 0)
        #expect(document.undoTitle.hasPrefix("Undo Auto kern"))
        // Existing values are kept unless Replace.
        #expect(model.values.isEmpty)
        model.replace = true
        #expect(!model.values.isEmpty)
        // Over classes: class cells.
        _ = await document.perform(CreateKernClass("A", side: .left, members: [fixture.glyph("A")])).value
        _ = await document.perform(CreateKernClass("V", side: .right, members: [fixture.glyph("V")])).value
        model.scope = .allClasses
        _ = await model.apply()?.value
        let classes = Kerning(document.state).classes
        #expect(Kerning(document.state).cell(classes[0].id, classes[1].id).map { $0.value < 0 } == true)
        model.scope = .selectedClasses
        model.classes = []
        #expect(model.pairs.isEmpty && model.apply() == nil)
        PanelRendering.host(AutoKernSheet(model: model, close: {}))
        var closed = false
        AutoKernSheet.applying(model) { closed = true }()
        #expect(closed)
    }

    // MARK: Find Problems (FONT-014)

    @Test func findProblemsListsFixesAndSelectsInTheGrid() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let b = fixture.glyph("B")
        let handle = try #require(GlyphCanvas.handle(for: b, of: fixture.document))
        await Self.shape([(0.4, 0), (299.6, 0.3), (300.2, -300.4)], on: handle)
        let selection = ActiveSelection(model: SelectionModel(), document: fixture.document)
        let model = FindProblemsModel(selection: selection)
        var opened: [OpID] = []
        var selected: [[OpID]] = []
        model.openGlyph = { opened.append($0) }
        model.selectInGrid = { selected.append($0) }
        let offGrid = try #require(model.problems.first { $0.kind == .offGrid })
        #expect(offGrid.glyph == b && FindProblemsModel.fix(for: offGrid) == .roundToUnits && model.glyphs.contains(b))
        FindProblemsView.opening(b, model)()
        FindProblemsView.opening(nil, model)()
        FindProblemsView.selecting(model)()
        #expect(opened == [b] && selected.first?.contains(b) == true)
        PanelRendering.host(FindProblemsView(model: model))
        let change = await model.run(.roundToUnits, for: offGrid)?.value
        let state = fixture.document.state
        let drawn = GlyphArtwork.objectIDs(on: b, in: state).map { node in
            (VectorPath(state.props(node).path, node: node, state: state).contours.first?.drawn.map(\.anchor), Objects.pasteboardTransform(of: node, in: state))
        }
        #expect(!model.problems.contains { $0.kind == .offGrid }, "\(String(describing: change?.label)) \(drawn)")
        // The current glyph's problems, from a glyph tab.
        model.scope = .glyph
        #expect(model.problems.isEmpty, "the pasteboard has no current glyph")
        let tab = ActiveSelection(model: SelectionModel(), document: handle)
        let tabModel = FindProblemsModel(selection: tab)
        tabModel.scope = .glyph
        #expect(tabModel.currentGlyph == b && tabModel.problems.allSatisfy { $0.glyph == b })
        // A broken component and its fix.
        let c = fixture.glyph("C")
        _ = await fixture.document.perform(AddComponent(c, to: b)).value
        _ = await fixture.document.perform(RemoveGlyphs([c])).value
        let dangling = try #require(model.problems.first { $0.kind == .danglingComponent } ?? FindProblemsModel(selection: selection).problems.first { $0.kind == .danglingComponent })
        #expect(FindProblemsModel.fix(for: dangling) == .removeComponent)
        FindProblemsView.fixing(.removeComponent, dangling, model)()
        try await Task.sleep(for: .milliseconds(100))
        await fixture.document.settle()
        #expect(GlyphIndex(fixture.document.state)[b]?.components.isEmpty == true)
        #expect(model.run(.removeComponent, for: dangling) == nil, "nothing left to remove")
        #expect(model.run(.roundToUnits, for: FontProblem(.warning, .missingSpace, "x")) == nil)
        #expect(FindProblemsModel.fix(for: FontProblem(.warning, .missingSpace, "x")) == nil)
        model.refresh()
        let none = FindProblemsModel(selection: nil)
        #expect(none.problems.isEmpty)
        PanelRendering.host(FindProblemsView(model: none))
        let plain = FindProblemsModel(selection: ActiveSelection(model: SelectionModel(), document: .memory(title: "Plain")))
        #expect(plain.problems.isEmpty)
    }

    // MARK: Preview strip (FONT-017)

    @Test func thePreviewStripSetsTheFontAndFollowsChanges() async throws {
        let fixture = try await Self.kernable()
        defer { fixture.close() }
        _ = await fixture.document.perform(SetKernPair(fixture.glyph("A"), fixture.glyph("V"), to: -80)).value
        let handle = try #require(GlyphCanvas.handle(for: fixture.glyph("A"), of: fixture.document))
        let model = PreviewStripModel(document: handle, glyph: fixture.glyph("A"), text: "AV☃")
        defer { model.stop() }
        #expect(model.setting.items.count == 3 && model.setting.items[0].kern == -80 && model.setting.items[2].glyph == nil)
        // Kerning equals the Metrics window's for the same string.
        #expect(model.setting == MetricsSetting.layout("AV☃", in: fixture.document.state, kerning: true))
        model.kerning = false
        #expect(model.setting.items[0].kern == 0)
        model.kerning = true
        let entries = model.paths(height: 90)
        #expect(entries[0].highlighted && !entries[1].highlighted && entries[2].box != nil)
        var opened: [OpID] = []
        model.open = { opened.append($0) }
        model.click(atX: 12 + 600 * model.scale)
        #expect(opened == [fixture.glyph("V")])
        model.click(atX: 0)
        #expect(model.item(atX: 5000) == nil)
        // A change redraws after the debounce.
        model.debounce = .milliseconds(10)
        _ = await fixture.document.perform(SetGlyphWidth([fixture.glyph("A")], to: 600)).value
        await model.settle()
        #expect(model.setting.items[1].x == 520)
        model.text = "n"
        #expect(model.setting.items.count == 1)
        model.resize(by: 50)
        #expect(model.height == 140 && !model.isHidden)
        model.resize(by: -200)
        #expect(model.isHidden)
        model.resize(by: 100)
        _ = PreviewStripView.resizing(model)
        let canvas = PreviewStripCanvas(model: model)
        canvas.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        _ = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds).map { canvas.cacheDisplay(in: canvas.bounds, to: $0) }
        PanelRendering.host(PreviewStripView(model: model))
        model.isHidden = true
        PanelRendering.host(PreviewStripView(model: model))
        #expect(PreviewStripModel.sizes.contains(model.size))
    }

    @Test func theStripAttachesToGlyphTabsAndTheCommandsRun() async throws {
        let fixture = try await Self.kernable()
        defer { fixture.close() }
        let tab = try #require(fixture.features.openGlyph(fixture.glyph("A"), from: fixture.window))
        let preferences = fixture.environment.preferences
        #expect(PreviewStripHost.attach(fixture.window, preferences: preferences) { _ in } == nil, "not a glyph tab")
        var opened: [OpID] = []
        let host = try #require(PreviewStripHost.attach(tab, preferences: preferences) { opened.append($0) })
        #expect(PreviewStripHost.attach(tab, preferences: preferences) { _ in } == nil && host.model.text == "Hamburgefonstiv")
        host.model.open(fixture.glyph("V"))
        #expect(opened == [fixture.glyph("V")])
        let strip = PreviewStripHost.command { tab }
        #expect(strip.validation().isChecked && !PreviewStripHost.command(window: { fixture.window }).validation().isEnabled)
        if case .perform(let run) = strip.action { run() }
        #expect(host.model.isHidden)
        if case .perform(let run) = PreviewStripHost.command(window: { fixture.window }).action { run() }
        PreviewStripHost.detach(tab)
        #expect(PreviewStripHost.host(of: tab) == nil)
        // The typeface commands.
        var shown = 0
        let commands = TypefaceTools.commands(features: fixture.features, window: { fixture.window }) { shown += 1 }
        #expect(commands.map(\.title).prefix(5) == ["Find Problems…", "Kerning Classes…", "Auto Kern…", "Add to Left Class", "Add to Right Class"])
        #expect(commands[0].validation().isEnabled && !commands[3].validation().isEnabled, "no glyph selected")
        fixture.mode.grid?.model.select([fixture.glyph("A"), fixture.glyph("V")])
        #expect(commands[3].validation().isEnabled)
        for command in commands.prefix(5) {
            if case .perform(let run) = command.action { run() }
            await fixture.document.settle()
            if let sheet = fixture.window.window?.attachedSheet { fixture.window.window?.endSheet(sheet) }
        }
        #expect(shown == 1 && Kerning(fixture.document.state).classes.count == 2)
        // Again: the glyphs are in their classes already, nothing to add.
        if case .perform(let run) = commands[3].action { run() }
        await fixture.document.settle()
        #expect(Kerning(fixture.document.state).classes.count == 2)
        // Adding to an existing class.
        let add = try #require(TypefaceTools.addToClass(.left, glyphs: [fixture.glyph("A"), fixture.glyph("T")], in: fixture.document))
        _ = await fixture.document.perform(add).value
        #expect(Kerning(fixture.document.state).kernClass(of: fixture.glyph("T"), side: .left) != nil)
        #expect(TypefaceTools.addToClass(.left, glyphs: [fixture.glyph("A")], in: fixture.document) == nil)
        #expect(TypefaceTools.addToClass(.left, glyphs: [], in: fixture.document) == nil)
        let plain = TypefaceTools.commands(features: fixture.features, window: { nil }) {}
        #expect(!plain[0].validation().isEnabled && !plain[3].validation().isEnabled)
        let panel = TypefaceTools.panel(selection: ActiveSelection(model: SelectionModel(), document: fixture.document), features: fixture.features) { fixture.window }
        _ = panel.makeView()
        tab.window?.close()
    }

    // MARK: Font units (FONT-004)

    @Test func glyphCanvasFieldsAndRulersUseFontUnits() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let handle = try #require(GlyphCanvas.handle(for: fixture.glyph("A"), of: fixture.document))
        let node = try #require(await fixture.box(0, -700, 100, 100, on: handle))
        let model = ObjectPanelModel(document: handle, selection: Selection([SelectionID(node)]))
        #expect(model.common?.y == 700)
        _ = await handle.perform(try #require(model.setPosition(y: 650))).value
        #expect(Objects.bounds(of: node, in: fixture.document.state)?.minY == -650)
        #expect(GlyphCanvasUnits.rulerReference(of: handle)?.zero == .zero && GlyphCanvasUnits.rulerReference(of: fixture.document) == nil)
        #expect(GlyphCanvasUnits.shown(y: 5, in: fixture.document) == 5 && GlyphCanvasUnits.stored(y: 5, in: handle) == -5)
        let tab = try #require(fixture.features.openGlyph(fixture.glyph("A"), from: fixture.window))
        tab.updateRulers()
        #expect(tab.rulerHost.horizontalRuler.frameOfReference.zero == .zero)
        tab.window?.close()
    }

    @Test func theTransformPanelTheGridAndPasteUseFontUnitsOnAGlyph() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let handle = try #require(GlyphCanvas.handle(for: fixture.glyph("A"), of: fixture.document))
        // The Transform panel's centre shows font y.
        let glyphSelection = ActiveSelection(model: SelectionModel(), document: handle)
        #expect(TransformPanelBody.shownY(-700, selection: glyphSelection) == 700 && TransformPanelBody.storedY(700, selection: glyphSelection) == -700)
        let pageSelection = ActiveSelection(model: SelectionModel(), document: fixture.document)
        #expect(TransformPanelBody.shownY(-700, selection: pageSelection) == -700 && TransformPanelBody.shownY(3, selection: nil) == 3)
        #expect(TransformPanelBody.storedY(3, selection: nil) == 3)
        // The grid: 10 units from the glyph's origin; the document's own elsewhere.
        #expect(GlyphCanvasUnits.grid(of: handle) == GridSpec(size: 10, origin: .zero))
        #expect(GlyphCanvasUnits.grid(of: fixture.document) == fixture.document.pageList.grid(on: fixture.document.activePage))
        // Paste into a glyph: text arrives as paths, one unit per point.
        let source = DocumentHandle.memory(title: "Art")
        let text = try #require(await source.perform(CreateTextBlock(.point(Point(x: 10, y: -20)), text: "Hi")).value?.createdObjects.first)
        let box = try #require(await source.addRectangles([Rect(x: 0, y: -100, width: 50, height: 50)]).first?.opID)
        await source.settle()
        let payload = ClipboardPayload(copying: [box, text], from: source.state)
        let pasted = GlyphCanvasUnits.pasted(payload, in: handle)
        #expect(pasted.nodes.count == 2 && !pasted.nodes.flatMap(\.flattened).contains { $0.props.kind?.isText == true })
        #expect(GlyphCanvasUnits.pasted(payload, in: fixture.document) == payload, "text stays text outside a glyph")
        let boxes = ClipboardPayload(copying: [box], from: source.state)
        #expect(GlyphCanvasUnits.pasted(boxes, in: handle) == boxes)
        let change = try #require(await handle.perform(Paste(pasted)).value)
        let roots = change.createdRoots
        let pastedBox = try #require(roots.first { fixture.document.state.nodeKind($0) == .rect })
        #expect(Objects.bounds(of: pastedBox, in: fixture.document.state) == Objects.bounds(of: box, in: source.state))
        #expect(roots.contains { fixture.document.state.nodeKind($0) == .group } && roots.count == 2)
    }
}
