import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The Polygon, Spiral and Arc tools (DRAW-011, DRAW-014, DRAW-015), the Pencil (DRAW-016/017) and
/// the Rotate, Scale, Skew and Reflect tools (OBJ-032), against memory documents.
@Suite @MainActor struct DrawingToolTests {
    @MainActor
    final class Fixture<T: Tool> {
        let tool: T
        let host = RecordingHost()
        let document: DocumentHandle
        let selection: SelectionController

        init(_ tool: T, document: DocumentHandle = .memory(title: "Tools"), settings: DrawingSettings = DrawingSettings()) {
            self.tool = tool
            self.document = document
            selection = SelectionController(document: document)
            var context = ToolContext(document: document, host: host, selection: selection)
            context.drawing = { settings }
            tool.activate(in: context)
        }

        func drag(_ from: Point, _ to: Point, _ modifiers: KeyModifiers = []) {
            tool.mouseDown(TestEvents.point(from.x, from.y, modifiers))
            tool.mouseDragged(TestEvents.point((from.x + to.x) / 2, (from.y + to.y) / 2, modifiers))
            tool.mouseUp(TestEvents.point(to.x, to.y, modifiers))
        }

        var created: SceneObject? {
            selection.selection.ids.first.flatMap { document.object(for: $0) }
        }
    }

    static func bitmap() -> CGContext {
        CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    @Test func polygonDragsFromTheCentre() async throws {
        var options = DrawingToolOptions()
        options.polygon = .init(sides: 6, star: false, automatic: true, sharpness: 0.5)
        let f = Fixture(PolygonTool(), settings: DrawingSettings(constrainAngle: 0, tools: options))
        #expect(f.host.messages.last?.hasPrefix("Drag from the center") == true)
        f.tool.mouseDown(TestEvents.point(100, 100))
        f.tool.mouseDragged(TestEvents.point(130, 110))
        #expect(f.tool.preview != nil)
        f.tool.drawOverlay(in: Self.bitmap(), viewport: f.host.viewport)
        f.tool.flagsChanged(TestEvents.point(0, 0, .shift))
        #expect(f.tool.shape?.shape.rotation == 0, "Shift snaps the first vertex to the constrain angle")
        f.tool.spaceChanged(down: true)
        f.tool.mouseDragged(TestEvents.point(140, 110, .shift))
        #expect(f.tool.anchor == Point(x: 110, y: 100), "Space repositions")
        f.tool.spaceChanged(down: false)
        f.tool.mouseUp(TestEvents.point(140, 110, .shift))
        await f.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        let polygon = try #require(f.created)
        #expect(polygon.kind == .polygon)
        let props = f.document.state.props(polygon.id).polygon
        #expect(props.sides == 6 && abs(props.radius - Point(x: 110, y: 100).distance(to: Point(x: 140, y: 110))) < 0.01)
        // A manual star with the sheet's sharpness.
        options.polygon = .init(sides: 5, star: true, automatic: false, sharpness: 0)
        let star = Fixture(PolygonTool(), settings: DrawingSettings(tools: options))
        star.drag(Point(x: 50, y: 50), Point(x: 50, y: 90))
        await star.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        let starProps = try #require(star.created.map { star.document.state.props($0.id).polygon })
        #expect(starProps.star && !starProps.autoInner && abs(starProps.innerRadius - 4) < 0.01)
        // Tiny and cancelled drags draw nothing.
        let sink = RecordingSink()
        let tiny = Fixture(PolygonTool())
        var context = ToolContext(document: tiny.document, host: tiny.host)
        context.commandSink = sink
        tiny.tool.activate(in: context)
        tiny.drag(Point(x: 0, y: 0), Point(x: 0.5, y: 0))
        tiny.tool.mouseDown(TestEvents.point(0, 0))
        tiny.tool.cancel()
        tiny.tool.mouseUp(TestEvents.point(40, 0))
        tiny.tool.mouseDragged(TestEvents.point(40, 0))
        tiny.tool.flagsChanged(TestEvents.point(0, 0))
        tiny.tool.spaceChanged(down: true)
        #expect(sink.commands.isEmpty && tiny.tool.preview == nil && tiny.tool.info == ToolInfo())
        #expect(!tiny.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        tiny.tool.drawOverlay(in: Self.bitmap(), viewport: tiny.host.viewport)
        tiny.tool.deactivate()
    }

    @Test func spiralsStartAtTheCentreForEveryDrawFrom() async throws {
        for from in DrawingToolOptions.DrawFrom.allCases {
            var options = DrawingToolOptions()
            options.spiralDrawFrom = from
            for modifiers: KeyModifiers in [[], .option] {
                let f = Fixture(SpiralTool(), settings: DrawingSettings(tools: options))
                f.drag(Point(x: 100, y: 100), Point(x: 160, y: 140), modifiers)
                await f.document.settle()
                try await Task.sleep(for: .milliseconds(20))
                let spiral = try #require(f.created)
                let first = spiral.transform.apply(try #require(spiral.path?.contours[0].drawn.first).anchor)
                let expected: Point = switch (modifiers.contains(.option) ? .center : from) {
                case .center: Point(x: 100, y: 100)
                case .edge: Point(x: 160, y: 140)
                case .corner: Point(x: 130, y: 120)
                }
                #expect(first.distance(to: expected) < 1e-6, "\(from) \(modifiers)")
                #expect(f.document.undoTitle == "Undo Draw spiral")
            }
        }
        let shift = Fixture(SpiralTool())
        shift.tool.mouseDown(TestEvents.point(0, 0))
        shift.tool.mouseDragged(TestEvents.point(50, 3, .shift))
        #expect(shift.tool.ends?.outer.y == 0)
        #expect(shift.tool.preview != nil)
        var corner = DrawingToolOptions()
        corner.spiralDrawFrom = .corner
        let degenerate = Fixture(SpiralTool(), settings: DrawingSettings(tools: corner))
        degenerate.tool.mouseDown(TestEvents.point(10, 10))
        #expect(degenerate.tool.path?.contours.isEmpty == true)
        #expect(degenerate.tool.command() == nil)
    }

    @Test func arcsFollowTheSheetAndTheModifiers() async throws {
        let cases: [(KeyModifiers, points: Int, closed: Bool)] = [([], 2, false), (.command, 3, true), (.option, 2, false), (.control, 2, false),
                                                                   ([.command, .option, .control], 3, true)]
        for (modifiers, count, closed) in cases {
            let f = Fixture(ArcTool())
            f.drag(Point(x: 10, y: 10), Point(x: 50, y: 30), modifiers)
            await f.document.settle()
            try await Task.sleep(for: .milliseconds(20))
            let contour = try #require(f.created?.path?.contours[0])
            #expect(contour.points.count == count && contour.closed == closed)
        }
        var sheet = DrawingToolOptions()
        sheet.arcOpen = false
        sheet.arcFlipped = true
        sheet.arcConcave = true
        let f = Fixture(ArcTool(), settings: DrawingSettings(tools: sheet))
        f.tool.mouseDown(TestEvents.point(0, 0))
        f.tool.mouseDragged(TestEvents.point(40, 10, .shift))
        let path = try #require(f.tool.path)
        #expect(path.contours[0].closed && path.contours[0].points[1].anchor == Point(x: 40, y: 40))
        #expect(f.tool.preview != nil)
        f.tool.mouseDragged(TestEvents.point(0, 10))
        #expect(f.tool.path == nil && f.tool.command() == nil)
    }

    @Test func thePencilFitsAStrokeAndDrawsOptionSpansStraight() async throws {
        let f = Fixture(PencilTool())
        #expect(f.host.messages.last == PencilTool.statusMessage)
        f.tool.mouseDown(TestEvents.point(0, 0))
        for i in 1...30 {
            let t = Double(i) / 30 * .pi
            f.tool.mouseDragged(TestEvents.point(100 - 100 * cos(t), 100 * sin(t)))
        }
        f.tool.mouseDragged(TestEvents.point(200, 50, .option))
        f.tool.mouseDragged(TestEvents.point(200, 90, [.option, .shift]))
        f.tool.drawOverlay(in: Self.bitmap(), viewport: f.host.viewport)
        f.tool.mouseUp(TestEvents.point(200, 90, [.option, .shift]))
        await f.document.settle()
        try await Task.sleep(for: .milliseconds(20))
        let contour = try #require(f.created?.path?.contours[0])
        #expect(!contour.closed)
        #expect(contour.drawn.last?.anchor.distance(to: Point(x: 200, y: 90)) ?? 99 < 1e-9)
        #expect(contour.drawn.last?.inHandle == .zero)
        #expect(f.document.undoTitle == "Undo Pencil")
        // A click draws nothing.
        f.tool.mouseDown(TestEvents.point(5, 5))
        f.tool.mouseUp(TestEvents.point(5, 5))
        #expect(f.tool.command() == nil)
        f.tool.flagsChanged(TestEvents.point(0, 0))
        #expect(!f.tool.keyDown(TestEvents.key("a", keyCode: 0)))
    }

    @Test func thePencilContinuesASelectedPathFromEitherEnd() async throws {
        let document = DocumentHandle.memory(title: "Continue")
        let line = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 50, y: 0)]))
        var options = DrawingToolOptions()
        options.pencilDotted = true
        let f = Fixture(PencilTool(), document: document, settings: DrawingSettings(tools: options))
        f.selection.model.set(Selection([line]))
        f.tool.pointerMoved(TestEvents.point(50, 1))
        #expect(f.tool.hoverContinues && f.tool.cursor == PenCursors.add)
        f.tool.pointerMoved(TestEvents.point(25, 30))
        #expect(!f.tool.hoverContinues)
        f.tool.mouseDown(TestEvents.point(50, 0))
        #expect(f.tool.continuation?.end == .end)
        for x in stride(from: 55.0, through: 100, by: 5) { f.tool.mouseDragged(TestEvents.point(x, 0)) }
        f.tool.drawOverlay(in: Self.bitmap(), viewport: f.host.viewport)
        f.tool.mouseUp(TestEvents.point(100, 0))
        await document.settle()
        #expect(document.path(line)?.contours[0].drawn.last?.anchor.distance(to: Point(x: 100, y: 0)) ?? 99 < 1)
        #expect(document.undoTitle == "Undo Pencil")
        // From the start.
        f.tool.mouseDown(TestEvents.point(0, 0))
        #expect(f.tool.continuation?.end == .start)
        for x in stride(from: -5.0, through: -40, by: -5) { f.tool.mouseDragged(TestEvents.point(x, 0)) }
        f.tool.mouseUp(TestEvents.point(-40, 0))
        await document.settle()
        #expect(document.path(line)?.contours[0].drawn.first?.anchor.distance(to: Point(x: -40, y: 0)) ?? 99 < 1)
        // The path deleted meanwhile: a new path.
        f.tool.mouseDown(TestEvents.point(-40, 0))
        _ = await document.perform(DeleteNodes([line.opID])).value
        for x in stride(from: -45.0, through: -80, by: -5) { f.tool.mouseDragged(TestEvents.point(x, 10)) }
        #expect(f.tool.command() is CreatePath)
        f.tool.deactivate()
    }

    @Test func strokeCaptureSpans() {
        var capture = StrokeCapture(start: .zero, straight: true)
        capture.add(Point(x: 10, y: 1), straight: true, constraint: .standard)
        #expect(capture.allSpans == [.straight(.zero, Point(x: 10, y: 0))])
        capture.add(Point(x: 20, y: 5), straight: false, constraint: nil)
        capture.add(Point(x: 30, y: 5), straight: false, constraint: nil)
        #expect(capture.spans == [.straight(.zero, Point(x: 10, y: 0))])
        #expect(capture.samples == [Point(x: 10, y: 0), Point(x: 20, y: 5), Point(x: 30, y: 5)])
        capture.add(Point(x: 40, y: 5), straight: true, constraint: nil)
        #expect(capture.allSpans.count == 3)
        #expect(capture.trail.first == .zero && capture.trail.last == Point(x: 40, y: 5))
    }

    @Test func transformToolsProduceTheirMatrices() async throws {
        let document = DocumentHandle.memory(title: "Transform")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        func run(_ kind: TransformKind, to end: Point, _ modifiers: KeyModifiers = [], from reference: Point = Point(x: 10, y: 0)) async -> TransformObjects? {
            let sink = RecordingSink()
            let f = Fixture(TransformTool(kind), document: document, settings: DrawingSettings(constrainAngle: 30))
            f.selection.model.set(Selection([rect]))
            var context = ToolContext(document: document, host: f.host, selection: f.selection)
            context.commandSink = sink
            context.drawing = { DrawingSettings(constrainAngle: 30) }
            f.tool.activate(in: context)
            f.tool.mouseDown(TestEvents.point(0, 0))
            f.tool.mouseDragged(TestEvents.point(reference.x, reference.y))
            f.tool.mouseDragged(TestEvents.point(end.x, end.y, modifiers))
            #expect(!f.tool.preview.isEmpty)
            f.tool.drawOverlay(in: Self.bitmap(), viewport: f.host.viewport)
            f.tool.mouseUp(TestEvents.point(end.x, end.y, modifiers))
            return sink.commands.first as? TransformObjects
        }
        let rotate = try #require(await run(.rotate, to: Point(x: 0, y: 10)))
        #expect(nearlyEqual(rotate.matrix, .rotation(radians: .pi / 2)) && rotate.center == .zero && rotate.kind == .rotate)
        let snapped = try #require(await run(.rotate, to: Point(x: 10 * cos(0.6), y: 10 * sin(0.6)), .shift))
        #expect(nearlyEqual(snapped.matrix, .rotation(radians: .pi / 4)), "Shift snaps 34° to 45° with a 30° constrain angle")
        let scale = try #require(await run(.scale, to: Point(x: 20, y: 20), from: Point(x: 10, y: 10)))
        #expect(nearlyEqual(scale.matrix, .scale(x: 2, y: 2)))
        let uniform = try #require(await run(.scale, to: Point(x: 30, y: 20), .shift, from: Point(x: 10, y: 10)))
        #expect(nearlyEqual(uniform.matrix, .scale(3)))
        let skew = try #require(await run(.skew, to: Point(x: 15, y: 10), from: Point(x: 10, y: 10)))
        #expect(nearlyEqual(skew.matrix, .shear(x: 0.5, y: 0)))
        let skewAxis = try #require(await run(.skew, to: Point(x: 15, y: 11), .shift, from: Point(x: 10, y: 10)))
        #expect(skewAxis.matrix.b == 0)
        let reflect = try #require(await run(.reflect, to: Point(x: 0, y: 10)))
        #expect(nearlyEqual(reflect.matrix, WTGeometry.AffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)), "a vertical axis flips left to right")
        let copy = try #require(await run(.rotate, to: Point(x: 0, y: 10), .option))
        #expect(copy.copies == 1)
        // The real document: one change, the copy selected.
        let f = Fixture(TransformTool(.rotate), document: document)
        f.selection.model.set(Selection([rect]))
        f.tool.mouseDown(TestEvents.point(0, 0))
        f.tool.mouseDragged(TestEvents.point(10, 0))
        f.tool.flagsChanged(TestEvents.point(0, 0, .option))
        f.tool.mouseUp(TestEvents.point(0, 10, .option))
        await document.settle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(document.undoTitle == "Undo Rotate with 1 copy")
        #expect(f.selection.selection.ids != [rect])
        // Points: point registers.
        let path = try #require(await document.addPath([Point(x: 0, y: 50), Point(x: 10, y: 50)]))
        let contour = document.path(path)!.contours[0]
        let point = PointReference(node: path.node, contour: contour.id, point: contour.points[1].id)
        f.selection.model.set(Selection([path]).applying([path], sub: [path: .points([point])], mode: .add))
        f.tool.mouseDown(TestEvents.point(0, 50))
        f.tool.mouseDragged(TestEvents.point(10, 50))
        f.tool.mouseDragged(TestEvents.point(0, 60))
        #expect(f.tool.command()?.label == "Rotate Point")
        f.tool.cancel()
        // Nothing selected, or no drag: nothing.
        f.selection.model.clear()
        f.tool.mouseDown(TestEvents.point(0, 0))
        f.tool.mouseDragged(TestEvents.point(1, 0))
        #expect(f.tool.matrix == nil && f.tool.command() == nil)
        f.tool.mouseDragged(TestEvents.point(10, 0))
        #expect(f.tool.command() == nil)
        #expect(!f.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        f.tool.flagsChanged(TestEvents.point(0, 0))
        f.tool.deactivate()
        #expect(TransformTool(.scale).statusMessage.contains("scale"))
    }

    @Test func settingsComeFromPreferences() throws {
        let store = PreferenceStore(defaults: UserDefaults(suiteName: "drawing-tools-\(UUID().uuidString)")!)
        _ = store.set(7, for: DrawingToolPreferences.polygonSides)
        _ = store.set(true, for: DrawingToolPreferences.spiralExpanding)
        _ = store.set(true, for: DrawingToolPreferences.spiralByIncrements)
        _ = store.set("edge", for: DrawingToolPreferences.spiralDrawFrom)
        _ = store.set(false, for: DrawingToolPreferences.arcOpen)
        _ = store.set(9, for: DrawingToolPreferences.pencilPrecision)
        let settings = DrawingSettings(preferences: store)
        #expect(settings.tools.polygon.sides == 7 && settings.tools.spiral.kind == .expanding && settings.tools.spiral.drawBy == .increments)
        #expect(settings.tools.spiralDrawFrom == .edge && !settings.tools.arcOpen && settings.tools.pencilPrecision == PrecisionSetting(9))
        #expect(settings.autoJoin && settings.arrowDistance == 1 && settings.shiftArrowDistance == 10)
        let ids = DrawingTools.descriptors().map(\.id)
        #expect(ids == ["polygon", "spiral", "arc", "pencil", "bezigon", "rotate", "scale", "skew", "reflect"])
        let registry = ToolRegistry()
        DrawingTools.install(into: registry)
        for descriptor in registry.descriptors { #expect(!(descriptor.make() is UnimplementedTool)) }
    }

    @Test func optionsSheetsListTheToolsPreferences() throws {
        let store = PreferenceStore(defaults: UserDefaults(suiteName: "tool-sheets-\(UUID().uuidString)")!)
        let registry = ToolRegistry()
        registry.registerBuiltIn()
        DrawingTools.install(into: registry)
        ToolOptionSheets.install(into: registry, store: store)
        ToolOptionSheets.install(into: ToolRegistry(), store: store)
        for id in ToolOptionSheets.keys.keys {
            let descriptor = try #require(registry.descriptor(for: id))
            let controller = try #require(descriptor.options?())
            #expect(controller.title == "\(descriptor.title) Options")
            let window = TestWindow.make(contentViewController: controller)
            let parent = TestWindow.make(.init(x: 0, y: 0, width: 400, height: 300), defer: true)
            parent.beginSheet(window)
            ToolOptionsPlaceholder.close(window)
        }
        var dismissed = false
        let sheet = ToolOptionsSheet(title: "Arc", keys: ToolOptionSheets.keys[ArcTool.id]!, store: store) { dismissed = true }
        _ = sheet.body
        sheet.dismiss()
        #expect(dismissed)
    }
}

func nearlyEqual(_ a: WTGeometry.AffineTransform, _ b: WTGeometry.AffineTransform) -> Bool {
    abs(a.a - b.a) < 1e-9 && abs(a.b - b.b) < 1e-9 && abs(a.c - b.c) < 1e-9 && abs(a.d - b.d) < 1e-9 && abs(a.tx - b.tx) < 1e-9 && abs(a.ty - b.ty) < 1e-9
}
