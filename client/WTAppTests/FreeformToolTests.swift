import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-027: the Freeform tool's pull, push and reshape, its keys, the clone, and the merges.
@Suite(.serialized) @MainActor struct FreeformToolTests {
    typealias Fixture = DrawingToolTests.Fixture

    /// A straight open path of `count` points along y = 100 from x = 0 to 300.
    static func line(_ document: DocumentHandle, count: Int = 7) async throws -> SelectionID {
        try #require(await document.addPath((0..<count).map { Point(x: Double($0) * 300 / Double(count - 1), y: 100) }))
    }

    static func contour(_ document: DocumentHandle, _ id: SelectionID) -> VectorContour? {
        document.path(id)?.contours.first
    }

    /// The largest distance from `expected` samples to the contour's curve.
    static func error(_ contour: VectorContour, from expected: [Point]) -> Double {
        let segments = ContourPoints.segments(contour.drawn, closed: contour.closed)
        let curve = Contour(segments: segments, closed: false)
        return expected.map { curve.nearestPoint(to: $0)?.distance ?? .infinity }.max() ?? 0
    }

    @Test func aPullByLengthMovesTheStretchAndKeepsThePointsOutsideIt() async throws {
        let document = DocumentHandle.memory(title: "Pull")
        let line = try await Self.line(document)
        let before = try #require(Self.contour(document, line))
        let settings = FreeformSettings()
        let f = Fixture(FreeformTool { [settings] in settings }, document: document)
        f.selection.model.set(Selection([line]))
        f.tool.mouseDown(TestEvents.point(150, 100))
        #expect(f.tool.gesture == .pull(bend: .length))
        f.tool.mouseDragged(TestEvents.point(150, 70))
        f.tool.mouseDragged(TestEvents.point(150, 60))
        // The reference: the deformed samples, before the refit.
        let expected = f.tool.contours[0].preview
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
        f.tool.mouseUp(TestEvents.point(150, 60))
        await document.settle()
        let after = try #require(Self.contour(document, line))
        #expect(document.undoTitle == "Undo Freeform")
        #expect(Self.error(after, from: expected) <= settings.pushPrecision.tolerance() + 1e-6, "within tolerance of the reference")
        #expect(after.drawn.contains { $0.anchor.y < 65 }, "the grab point followed the pointer")
        // Points outside the 100 pt stretch kept their ids and places.
        let far = before.drawn.filter { abs($0.anchor.x - 150) > 50 }
        for point in far { #expect(after.drawn.contains { $0.id == point.id && $0.anchor == point.anchor }) }
        #expect(!after.drawn.contains { $0.id == before.drawn[3].id }, "the point inside was replaced")
    }

    @Test func higherPrecisionPlacesMorePoints() async throws {
        var counts: [Int] = []
        for precision in [1, 5, 10] {
            let document = DocumentHandle.memory(title: "Precision")
            let line = try await Self.line(document, count: 3)
            var settings = FreeformSettings()
            settings.pushPrecision = PrecisionSetting(precision)
            settings.length = 300
            let f = Fixture(FreeformTool { [settings] in settings }, document: document)
            f.selection.model.set(Selection([line]))
            f.tool.mouseDown(TestEvents.point(150, 100))
            f.tool.mouseUp(TestEvents.point(150, 20))
            await document.settle()
            counts.append(Self.contour(document, line)?.drawn.count ?? 0)
        }
        #expect(counts[0] <= counts[1] && counts[1] <= counts[2] && counts[0] < counts[2], "\(counts)")
    }

    @Test func aPullBetweenPointsBendsOnlyThatSegmentsHandles() async throws {
        let document = DocumentHandle.memory(title: "Bend")
        let line = try await Self.line(document, count: 3)
        let before = try #require(Self.contour(document, line))
        var settings = FreeformSettings()
        settings.bend = .points
        let f = Fixture(FreeformTool { [settings] in settings }, document: document)
        f.selection.model.set(Selection([line]))
        f.tool.mouseDown(TestEvents.point(75, 100))
        #expect(f.tool.gesture == .pull(bend: .points))
        f.tool.mouseDragged(TestEvents.point(75, 60))
        f.tool.mouseUp(TestEvents.point(75, 60))
        await document.settle()
        let after = try #require(Self.contour(document, line))
        #expect(after.drawn.map(\.id) == before.drawn.map(\.id) && after.drawn.map(\.anchor) == before.drawn.map(\.anchor), "points stay")
        let segment = ContourPoints.segments(after.drawn, closed: false)[0]
        #expect(segment.evaluate(0.5).distance(to: Point(x: 75, y: 60)) < 1e-6, "the grabbed point follows the pointer")
        // Option before the press swaps the bend for this pull.
        f.tool.mouseDown(TestEvents.point(225, 100, .option))
        #expect(f.tool.gesture == .pull(bend: .length))
        f.tool.cancel()
        #expect(FreeformTool.bendSegment(f.tool.contours.first ?? FreeformContour(node: .zero, contour: .zero, closed: false, points: before.drawn), grab: 0, by: .zero) == nil)
    }

    @Test func pushingBesideThePathShovesItAhead() async throws {
        let document = DocumentHandle.memory(title: "Push")
        let line = try await Self.line(document)
        var settings = FreeformSettings()
        settings.pushSize = 40
        let f = Fixture(FreeformTool { [settings] in settings }, document: document)
        f.selection.model.set(Selection([line]))
        f.tool.mouseDown(TestEvents.point(150, 50))
        #expect(f.tool.gesture == .push)
        f.tool.mouseDragged(TestEvents.point(150, 90))
        f.tool.mouseDragged(TestEvents.point(150, 110))
        f.tool.mouseUp(TestEvents.point(150, 110))
        await document.settle()
        let after = try #require(Self.contour(document, line))
        let curve = Contour(segments: ContourPoints.segments(after.drawn, closed: false), closed: false)
        #expect((curve.nearestPoint(to: Point(x: 150, y: 110))?.distance ?? 0) >= 20 - settings.pushPrecision.tolerance() - 1e-6, "nothing inside the pointer")
        #expect(document.undoTitle == "Undo Freeform")
    }

    @Test func reshapeFadesWithTheDragAndTheKeysAdjustIt() async throws {
        let document = DocumentHandle.memory(title: "Reshape")
        let line = try await Self.line(document)
        var settings = FreeformSettings()
        settings.mode = .reshape
        let f = Fixture(FreeformTool { [settings] in settings }, document: document)
        f.selection.model.set(Selection([line]))
        // The keys: [ and ] resize, Up and Down change the strength.
        #expect(f.tool.keyDown(TestEvents.key("]", keyCode: 30)) && f.tool.size() == settings.reshapeSize + FreeformTool.sizeStep)
        #expect(f.tool.keyDown(TestEvents.key("[", keyCode: 33)) && f.tool.size() == settings.reshapeSize)
        #expect(f.tool.keyDown(TestEvents.key("", keyCode: 126)) && abs(f.tool.strength - 0.55) < 1e-9)
        #expect(f.tool.keyDown(TestEvents.key("", keyCode: 125)) && abs(f.tool.strength - 0.5) < 1e-9)
        #expect(!f.tool.keyDown(TestEvents.key("a", keyCode: 0)))
        f.tool.mouseDown(TestEvents.point(150, 100))
        #expect(f.tool.gesture == .reshape)
        f.tool.mouseDragged(TestEvents.point(150, 90))
        let early = f.tool.contours[0].samples.map { $0.point.distance(to: $0.original) }.max() ?? 0
        f.tool.mouseDragged(TestEvents.point(150, 80))
        f.tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: f.host.viewport)
        let late = (f.tool.contours[0].samples.map { $0.point.distance(to: $0.original) }.max() ?? 0) - early
        #expect(early > 0 && late > 0 && late < early, "the effect fades as the drag goes on")
        f.tool.mouseUp(TestEvents.point(150, 80))
        await document.settle()
        #expect(document.undoTitle == "Undo Freeform")
        // Shift constrains the pointer's movement.
        f.tool.mouseDown(TestEvents.point(0, 0))
        #expect(f.tool.constrained(TestEvents.point(30, 2, .shift)).y == 0)
        f.tool.cancel()
    }

    @Test func optionWhileDraggingReshapesACopy() async throws {
        let document = DocumentHandle.memory(title: "Clone")
        let line = try await Self.line(document)
        let before = try #require(Self.contour(document, line))
        let f = Fixture(FreeformTool(), document: document)
        f.selection.model.set(Selection([line]))
        f.tool.mouseDown(TestEvents.point(150, 100))
        f.tool.mouseDragged(TestEvents.point(150, 80))
        f.tool.flagsChanged(TestEvents.point(150, 80, .option))
        f.tool.mouseDragged(TestEvents.point(150, 60, .option))
        #expect(f.tool.clone)
        f.tool.mouseUp(TestEvents.point(150, 60, .option))
        await document.settle()
        #expect(document.undoTitle == "Undo Clone")
        #expect(Self.contour(document, line) == before, "the original is unchanged")
        #expect(document.scene.topLevel.count == 2, "a new node")
    }

    @Test func pressureScalesTheSizeAndLength() {
        var settings = FreeformSettings()
        settings.pressureSize = true
        settings.pressureLength = true
        let tool = FreeformTool { [settings] in settings }
        let pen = CanvasEvent(pasteboardPoint: .zero, viewPoint: .zero, pressure: 0.5, isTablet: true)
        #expect(tool.size(pen) == settings.pushSize / 2 && tool.size(TestEvents.point(0, 0)) == settings.pushSize)
        #expect(tool.length(pen, zoom: 2) == settings.length / 2 / 2 && tool.length(nil, zoom: 1) == settings.length)
        #expect(tool.command() == nil && tool.targets().isEmpty && !tool.hasSomethingToCancel)
        tool.mouseDragged(TestEvents.point(0, 0))
    }

    @Test func aReshapeKeepsAConcurrentMoveOutsideTheStretchAndResolvesInsideByRegister() async throws {
        let document = DocumentHandle.memory(title: "Merge freeform")
        let line = try await Self.line(document)
        let before = try #require(Self.contour(document, line))
        var remote = DocumentCore(state: document.state, replica: 0xFFFF_FFFF)
        let recording = DocumentCore.Recording(limit: 1, now: Date())
        let outside = try #require(try remote.perform(MovePoints(node: line.opID, contour: before.id, point: before.drawn[0].id, to: Point(x: 0, y: 130)), recording: recording)?.change)
        let inside = try #require(try remote.perform(MovePoints(node: line.opID, contour: before.id, point: before.drawn[3].id, to: Point(x: 150, y: 140)), recording: recording)?.change)
        let f = Fixture(FreeformTool(), document: document)
        f.selection.model.set(Selection([line]))
        f.tool.mouseDown(TestEvents.point(150, 100))
        f.tool.mouseUp(TestEvents.point(150, 70))
        await document.settle()
        _ = await document.receive(outside).value
        _ = await document.receive(inside).value
        await document.settle()
        let merged = try #require(Self.contour(document, line))
        #expect(merged.drawn.first { $0.id == before.drawn[0].id }?.anchor == Point(x: 0, y: 130), "outside the stretch: both kept")
        #expect(document.state.store.element(line.opID, PathFields.point(before.id, before.drawn[3].id))?.isDeleted == true, "inside: the point was replaced, the edit is on its tombstone")
    }
}
