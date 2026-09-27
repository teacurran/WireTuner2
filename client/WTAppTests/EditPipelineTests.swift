import AppKit
import Foundation
import Metal
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// D-076 in the app: gestures write intent, not input events; typing is on screen at once and
/// written per word; an edit never shows the pasteboard through the edited object.
@Suite(.serialized) @MainActor struct EditPipelineTests {
    typealias Fixture = PointerMoveTests.Fixture
    static let frameBudget: Duration = .microseconds(8_333)

    // MARK: Handle drags

    /// 200 drag events of a Bezier handle write nothing and preview each position; mouse-up writes
    /// one change.  Each event stays well within a frame.
    @Test func aHandleDragOf200EventsIsOneChangeAndNoCommandPerEvent() async throws {
        let f = await Fixture.make(subselect: true)
        let path = try await PointHandleTests.path(f, kind: .curve)
        PointHandleTests.select(f, path, [1])
        let layer = PointHandleLayer()
        let context = PointHandleTests.context(f)
        let changes = f.document.changeCount
        let revision = try #require(f.document.model).revision
        #expect(layer.press(TestEvents.point(170, 200), context: context))
        var times: [Double] = []
        for step in 1...200 {
            let start = DispatchTime.now().uptimeNanoseconds
            layer.drag(TestEvents.point(170 + Double(step % 40), 200 - Double(step % 30)), context: context)
            layer.draw(in: DrawingToolTests.bitmap(), viewport: SelectionFixture.viewport, context: context)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        #expect(f.document.changeCount == changes && f.document.model?.revision == revision, "no command per drag event")
        let preview = try #require(layer.preview(context))
        #expect(preview.ends.count == 2, "a curve point's two handles, the other one pivoting")
        #expect(abs(preview.dragged.x - (170 + Double(200 % 40))) < 1e-9 && abs(preview.dragged.y - (200 - Double(200 % 30))) < 1e-9)
        layer.release(TestEvents.point(175, 170), context: context)
        #expect(f.document.changeCount == changes + 1, "one change, applied before release returns")
        #expect(f.document.undoTitle == "Undo Move Handle")
        #expect(PointHandleTests.point(f, path, 1).outHandle == Vector(dx: 25, dy: -30))
        #expect(layer.preview(context) == nil && layer.dragging == nil)
        // Esc mid-drag drops the preview and writes nothing.
        #expect(layer.press(TestEvents.point(175, 170), context: context))
        layer.drag(TestEvents.point(190, 150), context: context)
        #expect(layer.preview(context) != nil)
        layer.cancel(context: context)
        #expect(layer.preview(context) == nil && f.document.changeCount == changes + 1)
        let stats = CanvasPerformanceTests.Stats(samples: times)
        print("D-076 handle drag, per event: \(stats)")
        PerfBudget.expect(.seconds(stats.p95), within: Self.frameBudget, "handle drag event",
                          enforcedInDebug: "the app's tests build Debug only; a Debug figure within the budget is a Release one too")
    }

    /// The preview of a written drag stays up until the tiles show the change (the host reports
    /// it), so the object never jumps back.
    @Test func aWrittenDragKeepsItsPreviewUntilTheTilesCatchUp() async throws {
        let f = await Fixture.make(subselect: true)
        let path = try await PointHandleTests.path(f, kind: .corner)
        PointHandleTests.select(f, path, [1])
        let host = DeferringHost(viewport: SelectionFixture.viewport)
        let context = ToolContext(document: f.document, host: host, selection: f.controller)
        let layer = PointHandleLayer()
        #expect(layer.press(TestEvents.point(170, 200), context: context))
        layer.drag(TestEvents.point(170, 180), context: context)
        layer.release(TestEvents.point(170, 180), context: context)
        #expect(layer.lingering != nil, "the preview stays while the tiles render")
        layer.draw(in: DrawingToolTests.bitmap(), viewport: SelectionFixture.viewport, context: context)
        host.catchUp()
        #expect(layer.lingering == nil)
        // The Pointer's move keeps its outline the same way.
        let tool = PointerTool()
        var pointerContext = ToolContext(document: f.document, host: host, selection: f.controller)
        pointerContext.optionDragCopies = { true }
        tool.activate(in: pointerContext)
        f.controller.model.set(Selection([f.selection.a]))
        tool.mouseDown(TestEvents.point(30, 30))
        tool.mouseDragged(TestEvents.point(40, 35))
        tool.mouseUp(TestEvents.point(40, 35))
        #expect(!tool.lingering.isEmpty && tool.movePreview.isEmpty)
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: SelectionFixture.viewport)
        tool.mouseDown(TestEvents.point(300, 300))   // a new gesture ends it too
        #expect(tool.lingering.isEmpty)
        tool.mouseUp(TestEvents.point(300, 300))
        host.catchUp()
    }

    /// A slider-style gesture previews and writes once; a streamed colour writes once it settles.
    @Test func continuousGesturesPreviewAndWriteOnce() async throws {
        let document = DocumentHandle.memory(title: "Gesture")
        let rect = await document.addRectangles([Rect(x: 10, y: 10, width: 40, height: 30)])[0]
        let start = try #require(document.object(for: rect)?.bounds?.minX)
        let revision = document.model!.revision
        document.beginGesture()
        #expect(document.isInGesture)
        for step in 1...50 {
            _ = document.perform(NamedChange.move(MoveOffGrid.command([rect.opID], by: Vector(dx: Double(step), dy: 0), in: document.state),
                                                  nodes: [rect.opID], state: document.state))
        }
        #expect(document.model!.revision == revision && document.isPreviewing, "previewed, nothing written")
        let written = try #require(document.endGesture())
        #expect(await written.value != nil && !document.isPreviewing && !document.isInGesture)
        #expect(document.undoTitle == "Undo Move")
        #expect(abs((document.object(for: rect)?.bounds?.minX ?? 0) - start - 50) < 1e-6, "the last position is the one written")
        // A cancelled gesture writes nothing; a gesture that ends inside another waits for the outer.
        document.beginGesture()
        document.beginGesture()
        _ = document.perform(NamedChange.move(MoveOffGrid.command([rect.opID], by: Vector(dx: 5, dy: 0), in: document.state),
                                              nodes: [rect.opID], state: document.state))
        #expect(document.endGesture() == nil && document.isInGesture)
        #expect(document.endGesture(cancelling: true) == nil && !document.isPreviewing)
        #expect(document.endGesture() == nil, "no gesture open")
        // A streamed input: previewed, written once after the pause.
        let before = document.model!.revision
        for step in 1...10 {
            ContinuousInput.settle {
                _ = document.perform(NamedChange.move(MoveOffGrid.command([rect.opID], by: Vector(dx: 0, dy: Double(step)), in: document.state),
                                                      nodes: [rect.opID], state: document.state))
            }
        }
        #expect(document.model!.revision == before && document.isPreviewing)
        let deadline = ContinuousClock.now + .seconds(5)
        while document.model!.revision == before, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(document.model!.revision == before + 1 && !document.isPreviewing)
        let edit = GestureEdit(document: document)
        #expect(edit.commit() == nil && !edit.isActive)
        edit.cancel()
    }

    /// A burst of arrow nudges previews and is one change.
    @Test func aNudgeBurstIsOneChange() async throws {
        let document = DocumentHandle.memory(title: "Nudge")
        let rect = await document.addRectangles([Rect(x: 10, y: 10, width: 40, height: 30)])[0]
        let selection = SelectionController(document: document)
        selection.model.set(Selection([rect]))
        let editing = ObjectEditing(document: document, selection: selection)
        let start = try #require(document.object(for: rect)?.bounds?.minX)
        let revision = document.model!.revision
        for _ in 0..<30 { #expect(editing.nudge(by: Vector(dx: 1, dy: 0))) }
        #expect(document.model!.revision == revision && editing.isNudging && document.isPreviewing)
        _ = await editing.endNudging()?.value
        #expect(document.model!.revision == revision + 1 && !document.isPreviewing)
        #expect(abs((document.object(for: rect)?.bounds?.minX ?? 0) - start - 30) < 1e-6)
        #expect(editing.endNudging() == nil)
    }

    // MARK: Typing

    /// 100 typed characters are on screen as each is typed -- the scene is rebuilt before the
    /// keystroke returns -- and are written as one change per word, not per key.
    @Test func typingAHundredCharactersIsAHandfulOfChangesAndEachIsOnScreenAtOnce() async throws {
        let document = DocumentHandle.memory(title: "Typing")
        let node = try #require(await document.perform(CreateTextBlock(.point(Point(x: 40, y: 60)))).value?.createdObjects.first)
        await document.settle()
        let session = TextEditingSession(document: document, sink: document, target: .node(node))
        var seqs: Set<UInt64> = []
        let token = document.observe { change in if let seq = change.change?.seq { seqs.insert(seq) } }
        defer { document.stopObserving(token) }
        let sentence = "the quick brown fox jumps over the lazy dog and keeps running far away until the night falls anew..."
        #expect(sentence.count == 100)
        var times: [Double] = []
        for character in sentence {
            let before = document.changeCount
            let start = DispatchTime.now().uptimeNanoseconds
            session.insert(String(character))
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            #expect(document.changeCount == before + 1, "the keystroke is in the scene when insert returns")
            await session.settle()
        }
        #expect(document.state.textNode(node)?.string == sentence)
        let words = sentence.split(separator: " ").count
        #expect(seqs.count <= words, "\(seqs.count) changes for \(words) words")
        let stats = CanvasPerformanceTests.Stats(samples: times)
        print("D-076 keystroke to screen: \(stats)")
        PerfBudget.expect(.seconds(stats.p95), within: Self.frameBudget, "keystroke on screen",
                          enforcedInDebug: "the app's tests build Debug only; a Debug figure within the budget is a Release one too")
    }

    /// Two quick size steps on a selected block, each built from the document as the press finds
    /// it (as the Text menu's Smaller/Larger do), add up: the first is in the state before the
    /// second reads it.
    @Test func twoQuickSizeStepsOnASelectedBlockAreTwoPoints() async throws {
        let document = DocumentHandle.memory(title: "Steps")
        let node = try #require(await document.addText("Size", at: Point(x: 40, y: 60)))
        func step() {
            let text = document.state.textNode(node)!
            _ = document.perform(TypeNudger.command(.size, delta: 1, node: node, range: 0..<text.length, in: text)!)
        }
        let before = TextLayoutReading.attributes(try #require(document.state.textNode(node)).values(at: 0)).size
        step()
        step()   // no await between the presses
        #expect(TextLayoutReading.attributes(try #require(document.state.textNode(node)).values(at: 0)).size == before + 2)
    }

    /// A Text tool nudge whose pause ends after its window went away writes nothing and does not
    /// crash (the nudger holds the window's editing state weakly).
    @Test func aNudgePauseEndingAfterTheWindowClosedIsHarmless() async throws {
        let document = DocumentHandle.memory(title: "Closed")
        let node = try #require(await document.addText("Nudge", at: Point(x: 40, y: 60)))
        let pause = ManualPause()
        var nudger: TypeNudger?
        do {
            let editing = ObjectEditing(document: document, selection: SelectionController(document: document))
            let session = TextEditingSession(document: document, sink: document, target: .node(node))
            session.select(anchor: 0, focus: 5)
            editing.textSession = session
            let made = TypeNudger.nudger(for: editing)
            made.sleep = { [pause] duration in await pause.wait(duration) }
            #expect(made.nudge(TypeNudge(kind: .size, delta: 1)))
            nudger = made
        }
        #expect(await eventually { pause.waiting == 1 })
        #expect(nudger?.editing == nil, "the window's editing state is gone")
        let revision = document.model!.revision
        pause.end()
        #expect(await eventually { nudger?.pending == nil })
        #expect(document.model!.revision == revision && nudger?.flush() == nil)
    }

    // MARK: Tiles

    /// The frame drawn right after an edit, before its tiles have re-rendered, shows the object's
    /// old pixels: nothing of the pasteboard shows through it.
    @Test(.enabled(if: CanvasMetalTests.hasMetal, "needs an Apple-family GPU"))
    func anEditNeverLeavesAVisibleTileHole() async throws {
        let context = try #require(MetalContext.shared)
        let document = DocumentHandle.memory(title: "Hole")
        let rect = Rect(x: 100, y: 100, width: 80, height: 60)
        let id = await document.addRectangles([rect])[0]
        var red = Wiretuner_Doc_V1_ColorRef()
        red.inline.rgb.r = 1
        _ = await document.perform(ApplyColor([id.opID], target: .fill, color: red)).value
        let canvas = CanvasView(document: document, tiles: CanvasView.makeTiles(), frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.tiles.backingScale = 1
        canvas.setViewport(Viewport(scrollOrigin: Point(x: 50, y: 50), zoom: 1, size: Size(width: 400, height: 300)))
        await canvas.tiles.settle()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 400, height: 300, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(context.device.makeTexture(descriptor: descriptor))
        func frame() throws -> BitmapSurface {
            _ = try #require(canvas.tiles.renderFrame(into: texture))
            let surface = try #require(BitmapSurface(width: 400, height: 300))
            texture.getBytes(surface.context.data!, bytesPerRow: surface.context.bytesPerRow, from: MTLRegionMake2D(0, 0, 400, 300), mipmapLevel: 0)
            return surface
        }
        let view = canvas.viewport
        let corner = view.toView(Point(x: rect.minX, y: rect.minY)), far = view.toView(Point(x: rect.maxX, y: rect.maxY))
        let pasteboard = try frame().pixel(x: 380, y: 20)
        func interior(_ surface: BitmapSurface) -> [RGBA8] {
            stride(from: Int(corner.x) + 3, to: Int(far.x) - 3, by: 5).flatMap { x in
                stride(from: Int(min(corner.y, far.y)) + 3, to: Int(max(corner.y, far.y)) - 3, by: 5).map { y in surface.pixel(x: x, y: y) }
            }
        }
        #expect(interior(try frame()).allSatisfy { $0.maxChannelDifference(to: pasteboard) > 60 })
        var blue = Wiretuner_Doc_V1_ColorRef()
        blue.inline.rgb.b = 1
        for round in 0..<3 {
            var color = blue
            color.inline.rgb.r = Double(round) / 3
            _ = document.perform(ApplyColor([id.opID], target: .fill, color: color))
            // No await: the replacement tiles cannot have landed yet.
            #expect(interior(try frame()).allSatisfy { $0.maxChannelDifference(to: pasteboard) > 60 }, "no pasteboard pixel inside the edited object")
        }
        await canvas.tiles.settle()
        #expect(interior(try frame()).allSatisfy { $0.blue > 200 })
        canvas.discardContents()
    }
}

/// A canvas host whose tiles catch up only when the test says so.
@MainActor
final class DeferringHost: CanvasHost {
    var viewport: Viewport
    private var waiting: [@MainActor () -> Void] = []

    init(viewport: Viewport) {
        self.viewport = viewport
    }

    func setViewport(_ viewport: Viewport) { self.viewport = viewport }
    func setNeedsOverlayDisplay() {}
    func toolCursorDidChange() {}
    func showStatusMessage(_ message: String) {}
    func whenTilesCatchUp(_ body: @escaping @MainActor () -> Void) { waiting.append(body) }

    func catchUp() {
        let bodies = waiting
        waiting = []
        for body in bodies { body() }
    }
}
