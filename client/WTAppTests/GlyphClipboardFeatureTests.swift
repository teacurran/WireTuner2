import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// fnp's FONT leftovers in the app: the grid's Copy and Paste and Paste as Component (FONT-008, FONT-012), the
/// encoding placeholders and drag reordering (FONT-010), the Object panel's Glyph, Component and Anchor sections,
/// Add Component… / Add Anchor… / Add Anchor Here and their glyph-tab shortcuts (FONT-010, FONT-012, FONT-013),
/// and the Font Info colour wells, PANOSE and rescale progress (FONT-006).
@Suite @MainActor struct GlyphClipboardFeatureTests {
    /// Basic Latin with `A` drawn (a box, width 500) and a private pasteboard.
    static func drawn() async throws -> (TypefaceWindowFixture, a: OpID) {
        let fixture = await TypefaceWindowFixture.typeface()
        fixture.features.glyphPasteboard = NSPasteboard(name: NSPasteboard.Name("WireTunerTests-\(UUID().uuidString)"))
        let a = fixture.glyph("A")
        let handle = GlyphCanvas.handle(for: fixture.index[a]!, of: fixture.document)
        _ = await fixture.box(100, -700, 300, 700, on: handle)
        handle.close()
        _ = await fixture.document.perform(SetGlyphWidth([a], to: 520)).value
        return (fixture, a)
    }

    static func settle(_ fixture: TypefaceWindowFixture) async {
        await fixture.document.settle()
        for _ in 0..<20 { await Task.yield() }
        await fixture.document.settle()
    }

    @Test func copyAndPasteInTheGrid() async throws {
        let (fixture, a) = try await Self.drawn()
        defer { fixture.close() }
        let grid = try #require(fixture.mode.grid)
        let view = grid.gridView
        let copy = NSMenuItem(title: "Copy", action: #selector(GlyphGridView.copy(_:)), keyEquivalent: "")
        let paste = NSMenuItem(title: "Paste", action: #selector(GlyphGridView.paste(_:)), keyEquivalent: "")
        let selectAll = NSMenuItem(title: "Select All", action: #selector(GlyphGridView.selectAll(_:)), keyEquivalent: "")
        #expect(!view.validateMenuItem(copy) && !view.validateMenuItem(paste) && view.validateMenuItem(selectAll))
        #expect(view.validateMenuItem(NSMenuItem(title: "Other", action: #selector(NSView.layout), keyEquivalent: "")))
        #expect(fixture.features.copyGlyphs() == nil && fixture.features.pasteGlyphs() == nil)
        grid.model.select([a])
        #expect(view.validateMenuItem(copy))
        view.copy(nil)
        let payload = try #require(fixture.features.glyphClipboard())
        #expect(payload.glyphs.map(\.name) == ["A"] && payload.sourceDocument == fixture.document.id)
        // The artwork goes along as objects, for a paste on a canvas.
        #expect(fixture.features.glyphPasteboard.data(forType: SystemObjectPasteboard.type) != nil && view.validateMenuItem(paste))
        // Paste into one selected glyph replaces its artwork and metrics, after confirmation.
        let b = fixture.glyph("B")
        grid.model.select([b])
        fixture.window.confirm = { _, _ in false }
        #expect(fixture.features.pasteGlyphs() == nil)
        fixture.window.confirm = { _, _ in true }
        _ = await fixture.features.pasteGlyphs()?.value
        #expect(fixture.index[b]?.advanceWidth == 520 && GlyphArtwork.objectIDs(on: b, in: fixture.document.state).count == 1)
        #expect(fixture.document.undoTitle == "Undo Paste into glyph" && grid.model.selection == [b])
        // Nothing selected: a new glyph, `.1` because A exists, selected.
        grid.model.select([])
        view.paste(nil)
        await Self.settle(fixture)
        let pasted = try #require(fixture.index.glyph(named: "A.1"))
        #expect(pasted.codepoints.isEmpty && grid.model.selection == [pasted.id])
        view.selectAll(nil)
        #expect(grid.model.selection.count == fixture.index.count)
    }

    @Test func pasteAsComponentOnTheGridAndTheGlyphTab() async throws {
        let (fixture, a) = try await Self.drawn()
        defer { fixture.close() }
        let commands = fixture.environment.commands
        let id = TypefaceFeatures.ClipboardID.pasteAsComponent
        #expect(commands.validate(id)?.reason == TypefaceFeatures.noCopiedGlyphs)
        let grid = try #require(fixture.mode.grid)
        grid.model.select([a])
        fixture.features.copyGlyphs()
        grid.model.select([])
        #expect(commands.validate(id)?.reason == TypefaceFeatures.noGlyph && fixture.features.pasteAsComponents() == nil)
        let b = fixture.glyph("B"), c = fixture.glyph("C")
        grid.model.select([b, c])
        #expect(commands.perform(id))
        await Self.settle(fixture)
        #expect(fixture.index[b]?.components.map(\.source) == [a] && fixture.index[c]?.components.map(\.source) == [a])
        #expect(fixture.document.undoTitle == "Undo Paste 2 components")
        // From a glyph tab: its glyph.
        let d = fixture.glyph("D")
        let tab = try #require(fixture.features.openGlyph(d, from: fixture.window))
        fixture.front = tab
        defer { tab.close() }
        #expect(commands.validate(id)?.isEnabled == true)
        _ = await fixture.features.pasteAsComponents()?.value
        #expect(fixture.index[d]?.components.map(\.source) == [a])
        fixture.front = nil
        #expect(commands.validate(id)?.reason == TypefaceFeatures.noDocument)
        fixture.front = fixture.window
        _ = await fixture.document.perform(ConvertDocumentKind(to: .multiPage)).value
        #expect(commands.validate(id)?.reason == TypefaceFeatures.notTypeface)
    }

    @Test func encodingPlaceholdersShowAndMakeTheirGlyph() async throws {
        let (fixture, _) = try await Self.drawn()
        defer { fixture.close() }
        let commands = fixture.environment.commands
        let grid = try #require(fixture.mode.grid)
        #expect(commands.validate(TypefaceFeatures.ClipboardID.encodingNone)?.isChecked == true && grid.model.items.count == grid.model.cells.count)
        #expect(commands.perform(TypefaceFeatures.ClipboardID.encoding(.latin1)))
        #expect(fixture.features.encodings == [.latin1] && commands.validate(TypefaceFeatures.ClipboardID.encoding(.latin1))?.isChecked == true)
        let missing = grid.model.items.count - grid.model.cells.count
        #expect(missing == 95 && grid.countLabel.stringValue.contains("95 missing"))
        #expect(commands.perform(TypefaceFeatures.ClipboardID.encoding(.greek)))
        #expect(grid.model.items.count - grid.model.cells.count > missing)
        fixture.features.toggleEncoding(.greek)
        // Unicode order: é sits after the encoded glyphs below it; custom order puts placeholders last.
        grid.model.sort = .unicode
        let position = try #require(grid.model.items.firstIndex(of: .placeholder(0xE9)))
        #expect(grid.model.items[position - 1] == .placeholder(0xE8) && grid.model.items[..<position].contains { $0.glyph?.name == "A" })
        grid.model.sort = .custom
        #expect(grid.model.items.last.flatMap { if case .placeholder = $0 { true } else { false } } == true)
        // Search finds placeholders by character and codepoint.
        grid.model.search = "é"
        #expect(grid.model.items == [.placeholder(0xE9)])
        grid.model.search = "U+00E9"
        #expect(grid.model.items == [.placeholder(0xE9)])
        grid.model.search = "zzz"
        #expect(grid.model.items.isEmpty)
        grid.model.search = ""
        // Drawn and hit like cells; a double-click makes the glyph and opens it.
        grid.gridView.relayout(width: 800)
        grid.gridView.display()
        let item = try #require(grid.model.items.firstIndex(of: .placeholder(0xE9)))
        var created: UInt32?
        let make = grid.gridView.onCreate
        grid.gridView.onCreate = { created = $0 }
        grid.gridView.press(at: NSPoint(x: grid.gridView.rect(of: item).midX, y: grid.gridView.rect(of: item).midY), clickCount: 2)
        #expect(created == 0xE9)
        grid.gridView.onCreate = make
        make?(0xE8)
        await Self.settle(fixture)
        #expect(fixture.index.glyph(for: 0xE8) != nil)
        let made = try #require(await fixture.features.createPlaceholderGlyph(0xE9, in: fixture.mode).value)
        let tab = try #require(fixture.features.gridWindow(of: GlyphCanvas.tabID(document: fixture.document.id, glyph: made)))
        defer { tab.close() }
        #expect(fixture.index.glyph(for: 0xE9)?.name == "eacute" && tab.documentHandle.glyphCanvasNode == made && grid.model.selection == [made])
        #expect(!grid.model.items.contains(.placeholder(0xE9)))
        #expect(commands.perform(TypefaceFeatures.ClipboardID.encodingNone))
        #expect(grid.model.items.count == grid.model.cells.count)
        // Layout rules, directly.
        let cells = grid.model.cells
        let unencoded = try #require(cells.first { $0.codepoints.isEmpty })
        #expect(GlyphGridModel.layout([unencoded], placeholders: [0x41], sort: .unicode) == [.placeholder(0x41), .glyph(unencoded)])
        #expect(GlyphGridModel.layout([], placeholders: [0x41], sort: .unicode) == [.placeholder(0x41)])
        #expect(GlyphGridController.countText(shown: 2, of: 3, missing: 0) == "2 of 3 glyphs")
        #expect(GlyphGridItem.label(of: 0x41) == ("A", "U+0041") && GlyphGridItem.placeholder(0x41).glyph == nil)
    }

    @Test func dragReordersTheSelectionInCustomOrder() async throws {
        let (fixture, a) = try await Self.drawn()
        defer { fixture.close() }
        let grid = try #require(fixture.mode.grid)
        let view = grid.gridView
        view.relayout(width: 800)
        let b = fixture.glyph("B"), c = fixture.glyph("C")
        func centre(_ glyph: OpID) -> NSPoint {
            let rect = view.rect(of: grid.model.itemPosition(of: glyph)!)
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        func left(_ glyph: OpID) -> NSPoint {
            let rect = view.rect(of: grid.model.itemPosition(of: glyph)!)
            return NSPoint(x: rect.minX + 2, y: rect.midY)
        }
        grid.model.select([b, c])
        // A press on a selected cell that does not move selects it alone.
        view.press(at: centre(c))
        view.dragged(to: NSPoint(x: centre(c).x + 1, y: centre(c).y))
        view.released(at: centre(c))
        #expect(grid.model.selection == [c])
        // Dragged before A: C moves ahead of it.
        let orderOfA = try #require(fixture.index[a]?.order)
        view.press(at: centre(c))
        view.dragged(to: left(a))
        #expect(view.dropItem == grid.model.itemPosition(of: a))
        view.display()
        view.released(at: left(a))
        await Self.settle(fixture)
        #expect(fixture.index[c]?.order == orderOfA && view.dropItem == nil)
        #expect(grid.model.dropOrder(before: grid.model.items.count) == fixture.index.count)
        #expect(view.dropPosition(at: NSPoint(x: -10, y: -10)) == grid.model.items.count)
        let right = view.rect(of: 0)
        #expect(view.dropPosition(at: NSPoint(x: right.maxX - 2, y: right.midY)) == 1)
        // Not in Unicode order: a press on a selected cell just selects.
        grid.model.sort = .unicode
        view.press(at: centre(a), modifiers: [])
        view.released(at: centre(a))
        #expect(grid.model.selection == [a] && !grid.model.canReorder)
        // Shift and Command still extend and toggle; a press past the cells clears.
        view.press(at: centre(b), modifiers: .command)
        #expect(grid.model.selection == [a, b])
        view.press(at: NSPoint(x: -5, y: -5))
        #expect(grid.model.selection.isEmpty)
        view.released(at: .zero)
        // A drag onto the end with nothing to show still draws the marker.
        grid.model.sort = .custom
        grid.model.select([a])
        view.press(at: centre(a))
        view.dragged(to: NSPoint(x: 5_000, y: 5_000))
        view.display()
        view.released(at: NSPoint(x: 5_000, y: 5_000))
        await Self.settle(fixture)
        #expect(fixture.index.glyphs.last?.id == a)
    }

    @Test func theObjectPanelEditsTheSelectedGlyphs() async throws {
        let (fixture, a) = try await Self.drawn()
        defer { fixture.close() }
        let grid = try #require(fixture.mode.grid)
        let selection = ActiveSelection(document: fixture.document)
        grid.model.select([a])
        var model = try #require(fixture.features.glyphPanel(for: selection))
        #expect(model.single?.name == "A" && model.title == "A" && model.width == 520 && model.left == 100 && model.right == 120)
        #expect(model.kind == .base && model.markColor == 0 && model.export == .on && model.note == "" && model.codepoints.map(\.label) == ["U+0041 A"])
        #expect(InspectorRegistry.standard.replacement(for: selection) != nil)
        PanelRendering.host(GlyphPanelView(model: model))
        // Rename: refused when taken or invalid.
        #expect(model.problem(renaming: "B") == GlyphPanelModel.nameTaken + "B" && model.problem(renaming: "9x") == GlyphPanelModel.invalidName)
        #expect(model.rename("B") == nil && model.rename("A") == nil)
        #expect(GlyphSectionView.commitName("B", model) == GlyphPanelModel.nameTaken + "B")
        #expect(GlyphSectionView.commitName("Alpha", model) == nil)
        await Self.settle(fixture)
        #expect(fixture.index[a]?.name == "Alpha")
        // Unicode: a character, a codepoint or a name.
        #expect(GlyphPanelModel.codepoint(from: "é") == 0xE9 && GlyphPanelModel.codepoint(from: "U+00E9") == 0xE9 && GlyphPanelModel.codepoint(from: "00e9") == 0xE9)
        #expect(GlyphPanelModel.codepoint(from: "latin small letter e with acute") == 0xE9 && GlyphPanelModel.codepoint(from: "zz") == nil)
        #expect(GlyphPanelModel.codepoint(from: " ") == nil)
        model = try #require(fixture.features.glyphPanel(for: selection))
        #expect(model.problem(adding: "B") == GlyphPanelModel.codepointTaken + "B" && model.problem(adding: "zz") == GlyphPanelModel.unknownCharacter)
        #expect(model.addCodepoint("A") == nil && model.addCodepoint("zz") == nil)
        #expect(GlyphSectionView.commitCodepoint("zz", model) == GlyphPanelModel.unknownCharacter)
        #expect(GlyphSectionView.commitCodepoint("U+0391", model) == nil)
        await Self.settle(fixture)
        #expect(fixture.index[a]?.codepoints == [0x41, 0x391])
        model = try #require(fixture.features.glyphPanel(for: selection))
        _ = await model.perform(model.removeCodepoint(0x391))?.value
        #expect(fixture.index[a]?.codepoints == [0x41])
        // Metrics, kind, colour, export, note: one change each.
        _ = await model.perform(model.setWidth(600))?.value
        _ = await model.perform(model.setLeft(50))?.value
        #expect(GlyphOutlines.metrics(of: a, in: fixture.document.state)?.leftSideBearing == 50)
        _ = await model.perform(model.setRight(40))?.value
        #expect(GlyphOutlines.metrics(of: a, in: fixture.document.state)?.rightSideBearing == 40)
        _ = await model.perform(model.setKind(.ligature))?.value
        _ = await model.perform(model.setMarkColor(4))?.value
        _ = await model.perform(model.setExport(false))?.value
        _ = await model.perform(model.setNote("stem"))?.value
        let read = try #require(fixture.index[a])
        #expect(read.kind == .ligature && read.markColor == 4 && read.skipExport && read.note == "stem")
        #expect(model.setWidth(-1) == nil)
        // Several glyphs: shared values or mixed; no name or Unicode.
        let b = fixture.glyph("B")
        grid.model.select([a, b])
        model = try #require(fixture.features.glyphPanel(for: selection))
        #expect(model.single == nil && model.title == "2 glyphs" && model.kind == nil && model.export == .mixed && model.left == nil && !model.hasOutline)
        #expect(model.rename("x") == nil && model.problem(renaming: "x") == nil && model.problem(adding: "x") == nil && model.removeCodepoint(0x41) == nil)
        #expect(model.setLeft(1) == nil && model.setRight(1) == nil && model.component == nil && model.anchor == nil)
        PanelRendering.host(GlyphPanelView(model: model))
        // Nothing selected: the panel says so.
        grid.model.select([])
        model = try #require(fixture.features.glyphPanel(for: selection))
        #expect(model.glyphs.isEmpty && model.setKind(.base) == nil && model.setMarkColor(1) == nil && model.setExport(true) == nil && model.setNote("") == nil)
        PanelRendering.host(GlyphPanelView(model: model))
        // Not a typeface window, or Sketches: the usual panel.
        fixture.mode.view = .sketches
        #expect(fixture.features.glyphPanel(for: selection) == nil)
        fixture.mode.view = .glyphs
        #expect(fixture.features.glyphPanel(for: nil) == nil && fixture.features.glyphPanel(for: ActiveSelection(document: .memory(title: "x"))) == nil)
        #expect(GlyphSectionView.kinds.count == 4)
    }

    @Test func theGlyphTabShowsThePickedAnchorAndComponent() async throws {
        let (fixture, a) = try await Self.drawn()
        defer { fixture.close() }
        let b = fixture.glyph("B")
        _ = await fixture.document.perform(AddComponent(a, to: b, transform: .translation(x: 10, y: -20))).value
        _ = await fixture.document.perform(AddAnchor("top", at: Point(x: 250, y: -700), to: b)).value
        let tab = try #require(fixture.features.openGlyph(b, from: fixture.window))
        defer { tab.close() }
        fixture.front = tab
        let mode = try #require(fixture.features.mode(of: tab))
        let handles = try #require(mode.glyphHandles)
        let selection = ActiveSelection(model: tab.selection.model, document: tab.documentHandle)
        var model = try #require(fixture.features.glyphPanel(for: selection))
        #expect(model.single?.id == b && model.component == nil && model.anchor == nil)
        // The anchor pressed on the canvas: its section.
        let revision = fixture.features.glyphPanelState.revision
        let anchor = try #require(fixture.index[b]?.anchors.first)
        handles.picked = .anchor(anchor.id)
        #expect(fixture.features.glyphPanelState.revision > revision)
        model = try #require(fixture.features.glyphPanel(for: selection))
        let value = try #require(model.anchor)
        #expect(value.name == "top" && value.x == 250 && value.y == 700 && value.role == .base)
        PanelRendering.host(GlyphPanelView(model: model))
        _ = await model.perform(model.moveAnchor(x: 260))?.value
        model = try #require(fixture.features.glyphPanel(for: selection))
        _ = await model.perform(model.moveAnchor(y: 710))?.value
        #expect(fixture.index[b]?.anchors.first?.position == Point(x: 260, y: -710))
        model = try #require(fixture.features.glyphPanel(for: selection))
        #expect(model.renameAnchor("top") == nil && model.renameAnchor(" ") == nil && model.setAnchorRole(.base) == nil)
        _ = await model.perform(model.renameAnchor("above"))?.value
        _ = await model.perform(model.setAnchorRole(.mark))?.value
        #expect(fixture.index[b]?.anchors.first?.name == "above" && fixture.index[b]?.anchors.first?.role == .mark)
        _ = await model.perform(model.removeAnchor())?.value
        #expect(fixture.index[b]?.anchors.isEmpty == true)
        // The component pressed: position, scale, rotation, decompose.
        let component = try #require(fixture.index[b]?.components.first)
        handles.picked = .component(component.id)
        model = try #require(fixture.features.glyphPanel(for: selection))
        var placed = try #require(model.component)
        #expect(placed.sourceName == "A" && placed.x == 10 && placed.y == 20 && placed.scale == 100 && placed.rotation == 0 && placed.status == .resolved)
        tab.canvas.setNeedsOverlayDisplay()
        handles.draw(in: GlyphCanvasHandlesTests.context(), viewport: GlyphCanvasHandlesTests.viewport, context: tab.toolManager!.context)
        PanelRendering.host(GlyphPanelView(model: model))
        var opened: [OpID] = []
        model.open = { opened.append($0) }
        ComponentSectionView.openSource(placed, model)
        #expect(opened == [a])
        _ = await model.perform(model.placeComponent(x: 30, y: 40))?.value
        model = try #require(fixture.features.glyphPanel(for: selection))
        placed = try #require(model.component)
        #expect(placed.x == 30 && placed.y == 40)
        _ = await model.perform(model.placeComponent(scale: 50, rotation: 90))?.value
        model = try #require(fixture.features.glyphPanel(for: selection))
        placed = try #require(model.component)
        #expect(placed.scale == 50 && placed.rotation == 90 && placed.x == 30 && placed.y == 40)
        #expect(model.placeComponent(scale: 0) == nil)
        // Decompose (kbd:[Cmd+Shift+D]) takes the picked component only.
        #expect(fixture.environment.commands.command(TypefaceFeatures.GlyphMenuID.decompose)?.defaultKey == KeyEquivalent("d", [.command, .shift]))
        #expect(fixture.features.decomposeCommand([b]) is DecomposeComponents)
        _ = await model.perform(model.decomposeComponent())?.value
        #expect(fixture.index[b]?.components.isEmpty == true)
        model = try #require(fixture.features.glyphPanel(for: selection))
        #expect(model.component == nil && model.placeComponent(x: 1) == nil && model.decomposeComponent() == nil)
        #expect(model.moveAnchor(x: 1) == nil && model.renameAnchor("x") == nil && model.setAnchorRole(.mark) == nil && model.removeAnchor() == nil)
        #expect(fixture.features.decomposeCommand([b]) is CommandBatch)
        // A press on nothing clears the pick; with objects selected the usual panel shows.
        _ = handles.press(TestEvents.point(900, 900), context: tab.toolManager!.context)
        #expect(handles.picked == nil)
        let object = try #require(GlyphArtwork.objectIDs(on: b, in: fixture.document.state).first)
        tab.selection.model.set(Selection([SelectionID(object)]))
        #expect(fixture.features.glyphPanel(for: selection) == nil)
        #expect(GlyphPanelModel.rounded(-0.0000001) == 0)
        fixture.front = fixture.window
    }

    @Test func addComponentAndAnchorSheetsAndShortcuts() async throws {
        let (fixture, a) = try await Self.drawn()
        defer { fixture.close() }
        let b = fixture.glyph("B")
        #expect(fixture.features.presentAddComponent() == nil && fixture.features.presentAddAnchor() == nil)
        #expect(!fixture.features.glyphTabKey("r", modifiers: [.command, .shift], in: fixture.window))
        let tab = try #require(fixture.features.openGlyph(b, from: fixture.window))
        defer { tab.close() }
        fixture.front = tab
        let commands = fixture.environment.commands
        #expect(commands.validate(TypefaceFeatures.PanelID.addComponent)?.isEnabled == true)
        // The shortcuts the spec names, on a glyph tab only.
        #expect(!fixture.features.glyphTabKey("r", modifiers: .command, in: tab) && !fixture.features.glyphTabKey("x", modifiers: [.command, .shift], in: tab))
        #expect(fixture.features.glyphTabKey("R", modifiers: [.command, .shift], in: tab))
        tab.window?.attachedSheet.map { tab.window?.endSheet($0) }
        #expect(fixture.features.glyphTabKey("a", modifiers: [.command, .shift], in: tab))
        tab.window?.attachedSheet.map { tab.window?.endSheet($0) }
        let keys = try #require(fixture.features.mode(of: tab)?.glyphKeys)
        #expect(!keys.handle("x", [.command, .shift]))
        var seen: [String] = []
        keys.handle = { characters, _ in
            seen.append(characters)
            return characters == "r"
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "R", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        #expect(keys.performKeyEquivalent(with: event) && seen == ["r"])
        let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        #expect(!keys.performKeyEquivalent(with: other))
        // Add Component: by name or character; unknown and self refused.
        let component = AddComponentModel(document: tab.documentHandle, glyph: b, perform: tab.typefacePerform)
        #expect(component.summary == "" && !component.add() && component.problem == GlyphPartsModel.unknownGlyph)
        component.text = "B"
        #expect(component.summary == "B  U+0042" && !component.add() && component.problem == AddComponentModel.loop)
        component.text = "nothing"
        #expect(component.summary == GlyphPartsModel.unknownGlyph)
        component.text = "A"
        #expect(component.found?.id == a && component.add())
        await Self.settle(fixture)
        #expect(fixture.index[b]?.components.map(\.source) == [a])
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(name: "stem")])).value
        component.text = "stem"
        #expect(component.summary == "stem")
        PanelRendering.host(AddComponentSheet(model: component, close: {}))
        // Add Anchor: the role from the name or chosen; bad input refused.
        let anchor = AddAnchorModel(document: tab.documentHandle, glyph: b, at: Point(x: 120, y: -300), perform: tab.typefacePerform)
        #expect(anchor.x == "120" && anchor.y == "300" && AddAnchorModel.Role.allCases.map(\.title) == ["From name", "Base", "Mark"])
        anchor.name = "bad name"
        #expect(!anchor.add() && anchor.problem == GlyphPartsModel.invalidAnchor)
        anchor.name = "_top"
        #expect(anchor.add())
        anchor.name = "ogonek"
        anchor.role = .mark
        #expect(anchor.add())
        anchor.name = "bottom"
        anchor.role = .base
        #expect(anchor.add())
        await Self.settle(fixture)
        #expect(fixture.index[b]?.anchors.map(\.role) == [.mark, .mark, .base] && fixture.index[b]?.anchors.first?.position == Point(x: 120, y: -300))
        PanelRendering.host(AddAnchorSheet(model: anchor, close: {}))
        #expect(AddAnchorModel(document: tab.documentHandle, glyph: b, at: .zero, perform: tab.typefacePerform).y == "0")
        // Add Anchor Here: at the context menu's point, whole units.
        _ = tab.contextMenu(at: tab.viewport.toView(Point(x: 80.4, y: -500.6)))
        #expect(tab.contextPoint.map { abs($0.x - 80.4) < 1e-6 } == true)
        #expect(commands.validate(TypefaceFeatures.PanelID.addAnchorHere)?.isEnabled == true)
        #expect(commands.perform(TypefaceFeatures.PanelID.addAnchorHere))
        let sheet = try #require(tab.window?.attachedSheet)
        tab.window?.endSheet(sheet)
        fixture.front = fixture.window
        #expect(commands.validate(TypefaceFeatures.PanelID.addAnchorHere)?.isEnabled == false)
    }

    @Test func fontInfoColourWellsPanoseAndRescaleProgress() async throws {
        let fixture = await TypefaceWindowFixture.typeface(nil)
        defer { fixture.close() }
        _ = await fixture.document.perform(AddGlyphs.range(0x100...0x37F)).value
        #expect(fixture.index.count > FontInfoModel.progressThreshold)
        let model = FontInfoModel(document: fixture.document)
        #expect(model.panose == [UInt8](repeating: 0, count: 10) && FontInfoModel.title(of: .bearing) == "Side bearing color")
        model.binding(panose: 0).wrappedValue = 2
        model.binding(panose: 2).wrappedValue = 8
        model.binding(.baseline).wrappedValue = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(model.binding(.baseline).wrappedValue.components?.first == 1)
        var shown: String?
        var closed = false
        model.showProgress = { text in
            shown = text
            return { closed = true }
        }
        model.upmText = "2048"
        _ = await model.commit()?.value
        let info = WTModel.FontInfo(fixture.document.state)
        #expect(info.os2.panose[0] == 2 && info.os2.panose[2] == 8 && info.guides.baselineColor.map { $0.red > 0.99 && $0.green < 0.01 } == true)
        #expect(info.metrics.upm == 2048 && shown == FontInfoModel.progressText(glyphs: fixture.index.count, upm: 2048) && closed)
        // Unchanged wells write nothing; the default palette clears them.
        let again = FontInfoModel(document: fixture.document)
        #expect(again.commands()?.isEmpty == true)
        again.useDefaultPalette()
        _ = await again.commit()?.value
        #expect(WTModel.FontInfo(fixture.document.state).guides.baselineColor == nil)
        // A small change shows no progress.
        let small = FontInfoModel(document: fixture.document)
        small.scaleGlyphs = false
        small.upmText = "1000"
        var shownSmall = false
        small.showProgress = { _ in
            shownSmall = true
            return {}
        }
        _ = await small.commit()?.value
        #expect(!shownSmall && WTModel.FontInfo(fixture.document.state).metrics.upm == 1000)
        #expect(FontInfoModel.stored(CGColor(gray: 0.5, alpha: 1)).map { abs($0.red - $0.blue) < 0.01 } == true)
        #expect(FontPanose.digits.count == 10 && FontPanose.choices(0, value: 9).last?.title == "Value 9" && FontPanose.choices(0, value: 1).count == 6)
        for pane in FontInfoModel.Pane.allCases {
            model.pane = pane
            PanelRendering.host(FontInfoSheet(model: model, close: {}))
        }
        PanelRendering.host(RescaleProgressView(text: "Scaling"))
        // The features' progress sheet opens on the window and closes.
        let close = fixture.features.presentProgress("Scaling", on: fixture.window.window)
        #expect(fixture.window.window?.attachedSheet != nil)
        close()
        #expect(fixture.window.window?.attachedSheet == nil)
    }
}
