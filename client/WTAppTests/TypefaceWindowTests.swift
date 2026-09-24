import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// A typeface document in a window with the typeface features attached (FONT-003 ... FONT-026's
/// window tests).  `front` is the window the commands act on.
@MainActor
final class TypefaceWindowFixture {
    let environment = TestEnvironment()
    let features: TypefaceFeatures
    let window: DocumentWindowController
    var front: DocumentWindowController?
    let fonts = FileManager.default.temporaryDirectory.appending(path: "WireTunerTestFonts-\(UUID().uuidString)")

    init(documents: DocumentController? = nil) {
        features = TypefaceFeatures(preferences: environment.preferences)
        features.installer = TestFontInstaller(directory: fonts, scope: .process)
        window = DocumentWindowController(document: .memory(title: "Marlowe"), environment: environment.document)
        window.confirm = { _, _ in true }
        front = window
        features.install(commands: environment.commands, documents: documents) { [unowned self] in self.front }
        features.attach(window)
    }

    /// The fixture with a typeface of `set` performed.
    static func typeface(_ set: GlyphSet? = .basicLatin) async -> TypefaceWindowFixture {
        let fixture = TypefaceWindowFixture()
        _ = await fixture.document.perform(NewTypeface(family: "Marlowe", style: "Regular", set: set)).value
        return fixture
    }

    var document: DocumentHandle { window.documentHandle }
    var mode: TypefaceWindowMode { features.mode(of: window)! }
    var index: GlyphIndex { GlyphIndex(document.state) }

    func glyph(_ name: String) -> OpID { index.glyph(named: name)!.id }

    /// A filled box on the canvas `handle` draws (glyph space on a glyph canvas).
    @discardableResult
    func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double, on handle: DocumentHandle) async -> OpID? {
        let points = [Point(x: x, y: y), Point(x: x + width, y: y), Point(x: x + width, y: y + height), Point(x: x, y: y + height)]
        var fill = Wiretuner_Doc_V1_AppearanceProps()
        fill.fills = [Appearances.basicFill(red: 0, green: 0, blue: 0)]
        let change = await handle.perform(CreatePath(contours: [NewContour(closed: true, points: points.map { VectorPoint(anchor: $0) })], appearance: fill)).value
        return change?.createdRoots.first
    }

    func close() {
        for mode in features.modes.values { mode.controller.window?.close() }
        window.close()
        try? FileManager.default.removeItem(at: fonts)
    }
}

@Suite @MainActor struct TypefaceWindowTests {
    @Test func theWindowFollowsTheDocumentKind() async throws {
        let fixture = TypefaceWindowFixture()
        defer { fixture.close() }
        _ = await fixture.document.openedModel()
        fixture.mode.update()
        #expect(fixture.mode.layout == .multiPage && fixture.mode.grid == nil)
        let accessories = fixture.window.window?.titlebarAccessoryViewControllers.count ?? 0
        _ = await fixture.document.perform(NewTypeface(family: "Marlowe", style: "Regular")).value
        let grid = try #require(fixture.mode.grid)
        #expect(fixture.mode.layout == .typeface && !grid.view.isHidden)
        #expect(fixture.window.window?.titlebarAccessoryViewControllers.count == accessories + 1)
        #expect(grid.model.cells.count == 96 && grid.countLabel.stringValue == "96 glyphs")
        // Sketches shows the pasteboard; the switch's segment says so.
        fixture.mode.switcher.selectedSegment = TypefaceWindowMode.View.sketches.rawValue
        NSApp.sendAction(try #require(fixture.mode.switcher.action), to: fixture.mode.switcher.target, from: fixture.mode.switcher)
        #expect(fixture.mode.view == .sketches && grid.view.isHidden)
        fixture.mode.view = .glyphs
        #expect(!grid.view.isHidden && fixture.mode.switcher.selectedSegment == 0)
        // Converted to an illustration (by anyone): the switch and the grid go.
        _ = await fixture.document.perform(ConvertDocumentKind(to: .multiPage)).value
        #expect(fixture.mode.layout == .multiPage && grid.view.isHidden)
        #expect(fixture.window.window?.titlebarAccessoryViewControllers.count == accessories)
        // A change that keeps the kind only reloads the grid.
        _ = await fixture.document.perform(ConvertDocumentKind(to: .typeface)).value
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(scalar: 0xE9)])).value
        #expect(grid.model.cells.count == 97)
    }

    @Test func aGlyphOpensInATabDrawingItsOwnCanvas() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let a = fixture.glyph("A")
        let tab = try #require(fixture.features.openGlyph(a, from: fixture.window))
        let handle = tab.documentHandle
        #expect(handle.canvasNode == a && handle.title == "A" && tab.isPrimaryView == false)
        #expect(fixture.features.openGlyph(a, from: fixture.window) === tab)
        #expect(fixture.features.gridDocument(of: tab) === fixture.document)
        #expect(GlyphCanvas.documentID(ofTab: handle.id) == fixture.document.id)
        // What the tab's tools create lands on the glyph, in the same change.
        let object = try #require(await fixture.box(100, -700, 300, 700, on: handle))
        #expect(GlyphArtwork.objectIDs(on: a, in: fixture.document.state) == [object])
        #expect(handle.scene.topLevel == [NodeID(object)] && fixture.document.scene.topLevel.isEmpty)
        #expect(fixture.document.canUndo && fixture.document.undoTitle.contains("Path"))
        // The background is the glyph's metric lines; a new width redraws it.
        let before = handle.scene.displayList.items[0]
        let bar = try #require(fixture.mode(of: tab).glyphBar)
        #expect(bar.widthText == "500" && bar.leftText == "100" && bar.rightText == "100" && bar.hasOutline)
        bar.widthText = "600"
        _ = await bar.commitWidth()?.value
        #expect(handle.scene.displayList.items[0] != before)
        #expect(handle.canvasSnapGuides.count == 7 && fixture.document.canvasSnapGuides.isEmpty)
        // The glyph canvas scrolls over the em.
        let frame = try #require(GlyphCanvas.frame(for: a, in: fixture.document.state))
        #expect(tab.canvas.navigation.scroller.pasteboard == GlyphCanvas.scrollBounds(frame))
        // Closing the tab leaves the document's model open.
        handle.close()
        #expect(handle.model != nil)
    }

    @Test func glyphTabsCloseWhenTheirGlyphGoes() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let b = fixture.glyph("B")
        let tab = try #require(fixture.features.openGlyph(b, from: fixture.window))
        var closed: [DocumentWindowController] = []
        fixture.mode(of: tab).closeWindow = { closed.append($0) }
        _ = await fixture.document.perform(RemoveGlyphs([b])).value
        #expect(closed.first === tab)
        // A glyph that is gone does not open; a tab over a glyph of an illustration closes.
        #expect(fixture.features.openGlyph(b, from: fixture.window) == nil)
        let c = fixture.glyph("C")
        let other = try #require(fixture.features.openGlyph(c, from: fixture.window))
        var closedOther = false
        fixture.mode(of: other).closeWindow = { _ in closedOther = true }
        _ = await fixture.document.perform(ConvertDocumentKind(to: .multiPage)).value
        #expect(closedOther)
    }

    @Test func stepsThroughTheGlyphsInGridOrder() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let a = fixture.glyph("A")
        let tab = try #require(fixture.features.openGlyph(a, from: fixture.window))
        fixture.front = tab
        let next = try #require(fixture.features.stepGlyph(by: 1))
        #expect(next.documentHandle.canvasNode == fixture.glyph("B"))
        fixture.front = next
        let back = try #require(fixture.features.stepGlyph(by: -1))
        #expect(back.documentHandle.canvasNode == a)
        // The first glyph's previous is the last; the grid window has no glyph to step from.
        fixture.front = fixture.features.openGlyph(fixture.glyph(".notdef"), from: fixture.window)
        #expect(fixture.features.stepGlyph(by: -1)?.documentHandle.canvasNode == fixture.index.glyphs.last?.id)
        fixture.front = fixture.window
        #expect(fixture.features.stepGlyph(by: 1) == nil)
        // The glyph bar steps and fits through the features.
        let bar = try #require(fixture.mode(of: back).glyphBar)
        fixture.front = back
        bar.next()
        bar.previous()
        bar.fit()
        #expect(fixture.features.targetGlyphs(in: back) == [a])
    }

    @Test func aTypefaceOnlyGlyphSetHasOneGlyphToStepTo() async throws {
        let fixture = await TypefaceWindowFixture.typeface(nil)
        defer { fixture.close() }
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(scalar: 0x41)])).value
        let tab = try #require(fixture.features.openGlyph(fixture.glyph("A"), from: fixture.window))
        fixture.front = tab
        #expect(fixture.features.stepGlyph(by: 1) === tab)
    }

    @Test func documentsRegisterGlyphTabsWithTheirDocumentsSession() async throws {
        let environment = TestEnvironment()
        let documents = DocumentController(environment: environment.document)
        let fixture = TypefaceWindowFixture(documents: documents)
        defer { fixture.close() }
        documents.makeWindowController = fixture.features.windowFactory(base: documents.makeWindowController)
        let grid = documents.open(.memory(title: "Face"), show: false)
        #expect(fixture.features.mode(of: grid) != nil)
        _ = await grid.documentHandle.perform(NewTypeface(family: "Face", style: "Bold")).value
        let a = try #require(GlyphIndex(grid.documentHandle.state).glyph(named: "A")).id
        let tab = try #require(fixture.features.openGlyph(a, from: grid))
        #expect(documents.windowControllers[tab.documentHandle.id] === tab)
        #expect(fixture.features.openGlyph(a, from: grid) === tab)
        #expect(tab.session === grid.session && tab.presence === grid.presence)
        // Glyph tabs are not saved as documents to reopen.
        #expect(documents.sessionState().map(\.documentID) == [grid.documentHandle.id])
        #expect(fixture.features.gridWindow(of: grid.documentHandle.id) === grid)
        // Without a parent window the environment is left as it is.
        let alone = fixture.features.glyphEnvironment(environment.document, parent: nil)
        #expect(alone.session(grid.documentHandle) == nil)
        documents.close(tab.documentHandle.id)
        documents.close(grid.documentHandle.id)
    }

    @Test func theGridSelectsOpensAndRemoves() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let grid = try #require(fixture.mode.grid)
        let a = fixture.glyph("A")
        grid.model.select([a])
        #expect(fixture.features.targetGlyphs(in: fixture.window) == [a])
        grid.onOpen?(a)
        #expect(fixture.features.gridWindow(of: GlyphCanvas.tabID(document: fixture.document.id, glyph: a)) != nil)
        grid.add(nil)
        #expect(fixture.window.window?.attachedSheet?.identifier?.rawValue == "sheet.addGlyph")
        if let sheet = fixture.window.window?.attachedSheet { fixture.window.window?.endSheet(sheet) }
        grid.onRemove?()
        await fixture.document.settle()
        #expect(fixture.index.glyph(named: "A") == nil)
    }
}

extension TypefaceWindowFixture {
    func mode(of controller: DocumentWindowController) -> TypefaceWindowMode { features.mode(of: controller)! }
}

@MainActor
extension GlyphCanvas {
    /// A canvas handle for the glyph `id` names, nil when it is not live.
    static func handle(for id: OpID, of document: DocumentHandle) -> DocumentHandle? {
        GlyphIndex(document.state)[id].map { handle(for: $0, of: document) }
    }
}
