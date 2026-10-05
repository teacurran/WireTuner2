import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
@testable import WireTuner

/// fnp2's leftovers on the glyph canvas and the Add Glyph sheet: a pressed anchor or component is
/// taken as the object -- the arrow keys move it and Delete removes it (FONT-012, FONT-013) -- and
/// Add Glyph's *Kind* and btn:[Add and Open] (FONT-008, FONT-010).
@Suite @MainActor struct GlyphHandleKeysTests {
    @Test func arrowsAndDeleteActOnThePickedAnchorAndComponent() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let a = fixture.glyph("A"), b = fixture.glyph("B")
        _ = await fixture.document.perform(AddComponent(a, to: b, transform: .translation(x: 10, y: -20))).value
        _ = await fixture.document.perform(AddAnchor("top", at: Point(x: 250, y: -700), to: b)).value
        let tab = try #require(fixture.features.openGlyph(b, from: fixture.window))
        defer { tab.close() }
        fixture.front = tab
        let handles = try #require(fixture.features.mode(of: tab)?.glyphHandles)
        let manager = try #require(tab.toolManager)
        let step = manager.context.drawing().arrowDistance, big = manager.context.drawing().shiftArrowDistance
        // Nothing picked: the keys are the objects'.
        #expect(manager.handleDeletion() == nil && !manager.nudgeHandle(by: Vector(dx: 1, dy: 0)))
        let anchor = try #require(fixture.index[b]?.anchors.first)
        handles.picked = .anchor(anchor.id)
        #expect(manager.nudge(keyCode: 124, modifiers: []))
        await fixture.document.settle()
        #expect(manager.nudge(keyCode: 125, modifiers: .shift))
        await fixture.document.settle()
        #expect(fixture.index[b]?.anchors.first?.position == Point(x: (250 + step).rounded(), y: (-700 + big).rounded()))
        // Delete removes it (menu:Edit[Clear] is enabled for it).
        #expect(tab.validate(selector: #selector(DocumentWindowController.delete(_:))))
        tab.delete(nil)
        await fixture.document.settle()
        #expect(fixture.index[b]?.anchors.isEmpty == true && manager.handleDeletion() == nil)
        #expect(!handles.nudge(by: Vector(dx: 1, dy: 0), context: manager.context))
        // The component: moved by whole units, then removed.
        let component = try #require(fixture.index[b]?.components.first)
        handles.picked = .component(component.id)
        #expect(manager.nudge(keyCode: 123, modifiers: []))
        await fixture.document.settle()
        #expect(fixture.index[b]?.components.first?.transform == .translation(x: (10 - step).rounded(), y: -20))
        // With an object selected, Delete and the arrows are the object's.
        let path = try #require(await fixture.box(0, -100, 50, 50, on: tab.documentHandle))
        tab.selection.model.set(Selection([SelectionID(path)]))
        #expect(manager.handleDeletion() == nil && !manager.nudgeHandle(by: Vector(dx: 1, dy: 0)))
        tab.selection.selectNone()
        tab.delete(nil)
        await fixture.document.settle()
        #expect(fixture.index[b]?.components.isEmpty == true)
        #expect(!handles.nudge(by: Vector(dx: 1, dy: 0), context: manager.context) && handles.deletionCommand(context: manager.context) == nil)
        // The bearing lines are not objects.
        handles.picked = .advance
        #expect(!handles.nudge(by: Vector(dx: 1, dy: 0), context: manager.context) && handles.deletionCommand(context: manager.context) == nil)
    }

    @Test func pressingAnAnchorTakesItAsTheObject() async throws {
        let (fixture, canvas, a) = try await GlyphCanvasHandlesTests.drawnA()
        defer { canvas.close(); fixture.close() }
        _ = await fixture.document.perform(AddAnchor("top", at: Point(x: 250, y: -700), to: a)).value
        await canvas.handle.settle()
        let path = try #require(GlyphArtwork.objectIDs(on: a, in: canvas.handle.state).first)
        canvas.manager.context.selection.model.set(Selection([SelectionID(path)]))
        canvas.manager.mouseDown(TestEvents.point(250, -700))
        canvas.manager.mouseUp(TestEvents.point(250, -700))
        await canvas.handle.settle()
        #expect(canvas.manager.context.selection.model.isEmpty && canvas.handles.picked != nil)
        #expect(canvas.manager.nudge(keyCode: 126, modifiers: []))
        await canvas.handle.settle()
        #expect(canvas.handle.state.isLive(path))
        let moved = try #require(GlyphIndex(canvas.handle.state)[a]?.anchors.first?.position)
        #expect(moved.y < -700)
    }

    @Test func addGlyphChoosesTheKindAndOpens() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        fixture.front = fixture.window
        let window = try #require(fixture.features.presentAddGlyph())
        fixture.window.window?.endSheet(window)
        let model = AddGlyphModel(document: fixture.document, after: fixture.glyph("A"), perform: { fixture.document.perform($0) })
        TypefaceFontTests().host(AddGlyphSheet(model: model, close: {}))
        // The kind follows the text until one is chosen.
        model.text = "f_f"
        #expect(model.kind == .ligature)
        model.text = "\u{0301}"
        #expect(model.kind == .mark)
        model.text = "partA"
        #expect(model.kind == .base)
        model.choose(.component)
        model.text = "Ä"
        #expect(model.kind == .component)
        var opened: [OpID] = []
        model.openGlyph = { opened.append($0) }
        let added = try #require(await model.addAndOpen()?.value)
        let glyph = try #require(fixture.index[added])
        // A Component is unencoded.
        #expect(glyph.name == "Adieresis" && glyph.kind == .component && glyph.codepoints.isEmpty && opened == [added])
        // Nothing new: nothing added or opened.
        #expect(model.addAndOpen() == nil && !model.addAndOpenButton() && model.problem == AddGlyphModel.exists)
        model.text = "Ö"
        model.choose(.mark)
        #expect(model.addAndOpenButton())
        await fixture.document.settle()
        #expect(fixture.index.glyph(named: "Odieresis")?.kind == .mark && fixture.index.glyph(named: "Odieresis")?.codepoints == [0xD6])
        // Each glyph keeps its own kind when none is chosen.
        let other = AddGlyphModel(document: fixture.document, after: nil, perform: { fixture.document.perform($0) })
        other.text = "e\u{0300}"
        #expect(other.commit())
        await fixture.document.settle()
        #expect(fixture.index.glyph(named: "gravecomb")?.kind == .mark && fixture.index.glyph(named: "e")?.kind == .base)
    }
}
