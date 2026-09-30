import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// FONT-011, FONT-012 and FONT-013 on the glyph canvas: the advance-width and LSB handles with
/// kbd:[Shift] and kbd:[Option] and their readout, anchors drawn and dragged, components drawn,
/// dragged and opened, the mark attachment preview; FONT-003's Font units pop-up and hidden page
/// controls.
@Suite @MainActor struct GlyphCanvasHandlesTests {
    static let viewport = Viewport(size: Size(width: 800, height: 800))

    @MainActor
    final class Canvas {
        let host = RecordingHost(viewport: GlyphCanvasHandlesTests.viewport)
        let handle: DocumentHandle
        let handles: GlyphCanvasHandles
        let manager: ToolManager
        var opened: [OpID] = []

        init(_ glyph: OpID, of fixture: TypefaceWindowFixture) {
            handle = GlyphCanvas.handle(for: fixture.index[glyph]!, of: fixture.document)
            handles = GlyphCanvasHandles(glyph: glyph)
            let registry = ToolRegistry()
            registry.registerBuiltIn()
            manager = ToolManager(registry: registry, context: ToolContext(document: handle, host: host, selection: SelectionController(document: handle)))
            manager.handleLayers = [handles]
            handles.openGlyph = { [unowned self] in opened.append($0) }
        }

        /// A press at `from`, a drag through the middle (drawing the overlay), a release at `to`.
        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) async {
            manager.mouseDown(TestEvents.point(from.x, from.y, modifiers))
            manager.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            manager.drawOverlay(in: GlyphCanvasHandlesTests.context(), viewport: GlyphCanvasHandlesTests.viewport)
            manager.mouseUp(TestEvents.point(to.x, to.y, modifiers))
            await handle.settle()
            for _ in 0..<20 { await Task.yield() }
            await handle.settle()
        }

        func metrics(_ glyph: OpID) -> GlyphMetrics { GlyphOutlines.metrics(of: glyph, in: handle.state)! }

        func close() { handle.close() }
    }

    static func context() -> CGContext {
        CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Basic Latin with `A` drawn (a 100...400 box, width 500) and open on a canvas.
    static func drawnA() async throws -> (TypefaceWindowFixture, Canvas, OpID) {
        let fixture = await TypefaceWindowFixture.typeface()
        let a = fixture.glyph("A")
        let canvas = Canvas(a, of: fixture)
        _ = try #require(await fixture.box(100, -700, 300, 700, on: canvas.handle))
        return (fixture, canvas, a)
    }

    @Test func theAdvanceAndLeftBearingLinesDrag() async throws {
        let (fixture, canvas, a) = try await Self.drawnA()
        defer { canvas.close(); fixture.close() }
        #expect(canvas.handles.tools == CanvasHandleLayers.tools)
        // The advance line: 40 units wider, one change.
        await canvas.drag(Point(x: 502, y: -300), Point(x: 542, y: -300))
        #expect(canvas.metrics(a).advanceWidth == 540 && fixture.document.undoTitle == "Undo Set width")
        // Shift steps by ten.
        await canvas.drag(Point(x: 540, y: -300), Point(x: 553, y: -300), .shift)
        #expect(canvas.metrics(a).advanceWidth == 550)
        // Option moves the artwork with it, keeping the RSB.
        await canvas.drag(Point(x: 550, y: -300), Point(x: 570, y: -300), .option)
        var metrics = canvas.metrics(a)
        #expect(metrics.advanceWidth == 570 && metrics.leftSideBearing == 120 && metrics.rightSideBearing == 150)
        // The LSB line: dragged 20 right, the artwork moves 20 left; the width stays.
        await canvas.drag(Point(x: 1, y: -300), Point(x: 21, y: -300))
        metrics = canvas.metrics(a)
        #expect(metrics.leftSideBearing == 100 && metrics.advanceWidth == 570)
        // With Option the RSB is kept too.
        await canvas.drag(Point(x: 0, y: -300), Point(x: -10, y: -300), .option)
        metrics = canvas.metrics(a)
        #expect(metrics.leftSideBearing == 110 && metrics.advanceWidth == 580 && metrics.rightSideBearing == 170)
        // A press on the artwork is the tool's, not the line's; a press far from both is too.
        #expect(!canvas.handles.press(TestEvents.point(250, -300), context: canvas.manager.context))
        #expect(!canvas.handles.press(TestEvents.point(900, -300), context: canvas.manager.context))
        // A drag that does not move writes nothing; Esc drops a drag.
        let title = fixture.document.undoTitle
        await canvas.drag(Point(x: 580, y: -300), Point(x: 580.2, y: -300))
        #expect(fixture.document.undoTitle == title)
        canvas.manager.mouseDown(TestEvents.point(580, -300))
        canvas.manager.mouseDragged(TestEvents.point(700, -300))
        canvas.manager.cancel()
        await canvas.handle.settle()
        #expect(canvas.metrics(a).advanceWidth == 580 && canvas.handles.drag == nil)
    }

    @Test func readoutsAndSteps() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let glyph = try #require(fixture.index.glyph(named: "A"))
        let metrics = GlyphMetrics(advanceWidth: 500, bounds: Rect(x: 100, y: -700, width: 300, height: 700))
        func drag(_ target: GlyphCanvasHandles.Target, _ dx: Double, _ modifiers: KeyModifiers = []) -> GlyphCanvasHandles.Drag {
            GlyphCanvasHandles.Drag(target: target, start: .zero, now: Point(x: dx, y: 0), modifiers: modifiers, glyph: glyph, metrics: metrics)
        }
        #expect(GlyphCanvasHandles.readout(drag(.advance, 40)) == "LSB 100  RSB 140  Width 540")
        #expect(GlyphCanvasHandles.readout(drag(.advance, 40, .option)) == "LSB 140  RSB 100  Width 540")
        #expect(GlyphCanvasHandles.readout(drag(.left, 20)) == "LSB 80  RSB 120  Width 500")
        #expect(GlyphCanvasHandles.readout(drag(.left, 20, .option)) == "LSB 80  RSB 100  Width 480")
        #expect(GlyphCanvasHandles.readout(drag(.anchor(glyph.id), 20)) == nil)
        #expect(GlyphCanvasHandles.readout(drag(.component(glyph.id), 20)) == nil)
        #expect(GlyphCanvasHandles.stepped(13, .shift) == 10 && GlyphCanvasHandles.stepped(12.6, []) == 13)
        var frame = GlyphCanvasFrame(advanceWidth: 500)
        #expect(GlyphCanvasHandles.lineX(500, at: -700, frame: frame) == 500)
        frame.italicAngle = -12
        #expect(abs(GlyphCanvasHandles.lineX(500, at: -700, frame: frame) - (500 + 700 * tan(12 * Double.pi / 180))) < 1e-9)
        // The advance line of an empty glyph's canvas, with a width of 0, still drags to a width.
        let handles = GlyphCanvasHandles(glyph: glyph.id)
        let empty = GlyphCanvasHandles.Drag(target: .advance, start: .zero, now: Point(x: -30, y: 0), modifiers: .option, glyph: glyph,
                                            metrics: GlyphMetrics(advanceWidth: 500, bounds: nil))
        #expect((handles.command(for: empty) as? SetGlyphWidth)?.width == 470)
    }

    @Test func anchorsDrawAndDrag() async throws {
        let (fixture, canvas, a) = try await Self.drawnA()
        defer { canvas.close(); fixture.close() }
        _ = await fixture.document.perform(AddAnchor("top", at: Point(x: 250, y: -700), to: a)).value
        _ = await fixture.document.perform(AddAnchor("_bottom", at: Point(x: 250, y: 0), to: a)).value
        await canvas.handle.settle()
        await canvas.drag(Point(x: 251, y: -701), Point(x: 283, y: -742))
        let anchor = try #require(fixture.index[a]?.anchor(named: "top"))
        #expect(anchor.position != Point(x: 250, y: -700) && anchor.position.x == anchor.position.x.rounded() && anchor.position.y == anchor.position.y.rounded())
        #expect(fixture.document.undoTitle.contains("anchor"))
        // Every anchor draws (the dragged one where the pointer is).
        canvas.manager.drawOverlay(in: Self.context(), viewport: Self.viewport)
    }

    @Test func componentsDrawDragAndOpenTheirSource() async throws {
        let (fixture, canvasA, a) = try await Self.drawnA()
        defer { canvasA.close(); fixture.close() }
        let b = fixture.glyph("B")
        let before = GlyphCanvas.background(of: b, in: fixture.document.state)
        _ = await fixture.document.perform(AddComponent(a, to: b)).value
        let canvas = Canvas(b, of: fixture)
        defer { canvas.close() }
        // The component is drawn in the background: tint and outline.
        func children(_ items: [DisplayItem]) -> Int { if case .group(let group) = items[0] { group.children.count } else { 0 } }
        #expect(children(GlyphCanvas.background(of: b, in: fixture.document.state)) == children(before) + 2)
        // Dragged inside its outline: its transform moves, one change.
        await canvas.drag(Point(x: 200, y: -300), Point(x: 230, y: -290))
        let moved = try #require(fixture.index[b]?.components.first?.transform)
        #expect(moved == .translation(x: 30, y: 10) && fixture.document.undoTitle == "Undo Move component")
        // Shift keeps the move on one axis.
        await canvas.drag(Point(x: 230, y: -300), Point(x: 260, y: -295), .shift)
        #expect(fixture.index[b]?.components.first?.transform == .translation(x: 60, y: 10))
        // Double-click opens the source glyph.
        #expect(canvas.handles.press(TestEvents.point(260, -300).clicked(2), context: canvas.manager.context))
        #expect(canvas.opened == [a])
        // A removed source draws as a hatched placeholder and does not open.
        _ = await fixture.document.perform(RemoveGlyphs([a])).value
        await canvas.handle.settle()
        #expect(children(GlyphCanvas.background(of: b, in: fixture.document.state)) == children(before) + 3)
        #expect(canvas.handles.press(TestEvents.point(260, -300).clicked(2), context: canvas.manager.context))
        #expect(canvas.opened == [a])
        // Gone glyph: no handles at all.
        _ = await fixture.document.perform(RemoveGlyphs([b])).value
        #expect(canvas.handles.snapshot(canvas.handle) == nil && !canvas.handles.press(TestEvents.point(0, 0), context: canvas.manager.context))
        canvas.manager.drawOverlay(in: Self.context(), viewport: Self.viewport)
    }

    @Test func markAttachmentDrawsMarksOnTheBase() async throws {
        let (fixture, canvas, a) = try await Self.drawnA()
        defer { canvas.close(); fixture.close() }
        _ = await fixture.document.perform(AddGlyphs([NewGlyph(scalar: 0x301)])).value
        let mark = fixture.glyph("acutecomb")
        let markCanvas = Canvas(mark, of: fixture)
        defer { markCanvas.close() }
        _ = await fixture.box(0, -100, 100, 100, on: markCanvas.handle)
        _ = await fixture.document.perform(AddAnchor("_top", at: Point(x: 50, y: 0), to: mark)).value
        _ = await fixture.document.perform(AddAnchor("top", at: Point(x: 250, y: -700), to: a)).value
        await canvas.handle.settle()
        canvas.handles.showsMarkAttachment = { true }
        let shown = Self.inked(canvas)
        canvas.handles.showsMarkAttachment = { false }
        let hidden = Self.inked(canvas)
        // The acute is drawn faintly above A: more of the overlay is inked with the preview on.
        #expect(shown > hidden + 1_000)
        // The features' menu item toggles the preview for every tab.
        #expect(!fixture.features.showsMarkAttachment)
        fixture.features.toggleMarkAttachment()
        #expect(fixture.features.showsMarkAttachment)
        #expect(fixture.environment.commands.validate(TypefaceFeatures.GlyphMenuID.showMarkAttachment)?.isChecked == true)
        fixture.features.toggleMarkAttachment()
    }

    /// How many pixels the overlay inks, drawn scrolled so the glyph's em is in view.
    static func inked(_ canvas: Canvas) -> Int {
        let ctx = context()
        canvas.manager.drawOverlay(in: ctx, viewport: Viewport(scrollOrigin: Point(x: -100, y: -900), size: viewport.size))
        guard let data = ctx.data else { return 0 }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for row in 0..<ctx.height {
            for column in 0..<ctx.width where bytes[row * ctx.bytesPerRow + column * 4 + 3] != 0 { count += 1 }
        }
        return count
    }

    @Test func glyphTabsShowFontUnitsAndNoPageControls() async throws {
        let fixture = await TypefaceWindowFixture.typeface()
        defer { fixture.close() }
        let tab = try #require(fixture.features.openGlyph(fixture.glyph("A"), from: fixture.window))
        let bar = tab.statusBar
        #expect(bar.fixedUnits == TypefaceWindowMode.fontUnits && bar.units.itemTitles == ["Font units"] && !bar.units.isEnabled)
        #expect(bar.hidesPageControls && bar.addPage.isHidden && bar.pageField.isHidden)
        bar.show(units: .inches)
        #expect(bar.units.itemTitles == ["Font units"])
        #expect(fixture.mode(of: tab).glyphHandles != nil && tab.toolManager.handleLayers.first is GlyphCanvasHandles)
        // Freed again (the status bar of an ordinary window).
        bar.fixedUnits = nil
        bar.show(units: .points)
        #expect(bar.units.isEnabled && bar.units.numberOfItems > 1)
        // The grid window of a typeface keeps its page controls; a single-page document hides them.
        #expect(!fixture.window.statusBar.hidesPageControls)
        _ = await fixture.document.perform(ConvertDocumentKind(to: .singlePage)).value
        fixture.mode.update()
        #expect(fixture.window.statusBar.hidesPageControls && fixture.window.statusBar.addPage.isHidden)
        _ = await fixture.document.perform(ConvertDocumentKind(to: .multiPage)).value
        fixture.mode.update()
        #expect(!fixture.window.statusBar.hidesPageControls && !fixture.window.statusBar.addPage.isHidden)
    }
}

extension CanvasEvent {
    /// The same event as the `count`th click.
    func clicked(_ count: Int) -> CanvasEvent {
        CanvasEvent(pasteboardPoint: pasteboardPoint, viewPoint: viewPoint, modifiers: modifiers, pressure: pressure, clickCount: count, timestamp: timestamp)
    }
}
