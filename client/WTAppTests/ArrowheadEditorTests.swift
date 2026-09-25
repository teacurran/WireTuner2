import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// ATTR-030: the Arrowhead Editor draws a head with the app's own tools, btn:[New] saves it and puts
/// it on the stroke, and the head scales with the stroke's width.
@Suite(.serialized) @MainActor struct ArrowheadEditorTests {
    static func registry() -> ToolRegistry {
        let tools = ToolRegistry()
        tools.registerBuiltIn()
        DrawingTools.install(into: tools)
        return tools
    }

    /// An open path along y = 50 from x 20 to 120 with a stroke, its stroke editor, and the editor.
    static func stroke() async throws -> (AttributeFixture, StrokeEditorModel) {
        let fixture = AttributeFixture()
        fixture.ids = [try #require(await fixture.document.addPath([Point(x: 20, y: 50), Point(x: 120, y: 50)]))]
        let row = try #require(fixture.list().rows.firstIndex { $0.list == .strokes })
        let model = StrokeEditorModel(context: fixture.context(row), presets: StrokeEditorTests.presets(), widthPresets: ["1"], pasteboard: fixture.pasteboard)
        return (fixture, model)
    }

    @Test func aHeadDrawnWithTheToolsIsSavedAndScalesWithTheStroke() async throws {
        let (fixture, stroke) = try await Self.stroke()
        ArrowheadEditing.tools = Self.registry()
        var presented: [ArrowheadEditorController] = []
        ArrowheadEditing.present = { presented.append($0) }
        StrokeEditorView.newArrowhead(end: true, model: stroke)()
        let editor = try #require(ArrowheadEditing.current)
        #expect(presented.count == 1 && editor.manager.registry.ids.count == 5, "Pointer, Pen, Bezigon, Rectangle, Ellipse")
        #expect(editor.model.arrowhead == nil)
        editor.commit()
        #expect(presented.count == 1, "nothing drawn: New does nothing")
        // Draw a one-unit square ahead of the endpoint with the Rectangle tool.
        editor.manager.select(.rectangle)
        editor.manager.mouseDown(TestEvents.point(240, 140))
        editor.manager.mouseDragged(TestEvents.point(250, 150))
        editor.manager.mouseUp(TestEvents.point(260, 160))
        await editor.model.document.settle()
        let head = try #require(editor.model.arrowhead)
        let anchors = head.contours.flatMap(\.points).map { Point(x: $0.anchor.x, y: $0.anchor.y) }
        #expect(anchors.count == 4 && anchors.allSatisfy { $0.x >= -1e-6 && $0.x <= 1 + 1e-6 && abs($0.y) <= 0.5 + 1e-6 })
        #expect(head.name == "Custom" && head.filled)
        editor.model.name = "Block"
        editor.model.pathTrim = 0.5
        editor.drawGuides()
        editor.commit()
        await fixture.document.settle()
        let applied = fixture.stack()[try #require(fixture.list().rows.firstIndex { $0.list == .strokes })].stroke.settings.basic.endArrowhead
        #expect(applied.name == "Block" && applied.pathTrim == 0.5 && stroke.presets.arrowheads.contains { $0.name == "Block" })
        // It renders beyond the path's end in proportion to the stroke's width, at 2 pt and at 8 pt.
        var reach: [Double] = []
        for width in [2.0, 8.0] {
            _ = await fixture.document.perform(stroke.setBasicWidth(width)).value
            await fixture.document.settle()
            reach.append((fixture.document.object(for: fixture.ids[0])?.bounds?.maxX ?? 0) - 120)
        }
        #expect(reach[0] >= 2 && abs(reach[1] - reach[0] * 4) < 1e-6, "four times the width, four times the reach")
    }

    @Test func optionClickLoadsAHeadAndCancelLeavesTheStroke() async throws {
        let (fixture, stroke) = try await Self.stroke()
        ArrowheadEditing.tools = Self.registry()
        ArrowheadEditing.present = { _ in }
        let triangle = try #require(stroke.arrowheadChoices.first)
        StrokeEditorView.arrowheadAction(triangle, end: false, model: stroke, option: { true })()
        let editor = try #require(ArrowheadEditing.current)
        await editor.model.load(triangle).value
        #expect(editor.model.name == triangle.name && editor.model.arrowhead?.contours.isEmpty == false)
        PanelRendering.host(ArrowheadEditorControls(model: editor.model, manager: editor.manager, commit: {}, cancel: {}))
        ArrowheadEditorControls.choosing(.ellipse, editor.manager)()
        #expect(editor.manager.activeToolID == .ellipse)
        editor.cancel()
        await fixture.document.settle()
        #expect(fixture.stack()[try #require(fixture.list().rows.firstIndex { $0.list == .strokes })].stroke.settings.basic.startArrowhead.contours.isEmpty)
        // Without the app's tools nothing opens; a plain click applies the head.
        ArrowheadEditing.tools = nil
        #expect(ArrowheadEditing.open(loading: nil) { _ in } == nil)
        StrokeEditorView.arrowheadAction(triangle, end: false, model: stroke, option: { false })()
        await fixture.document.settle()
        #expect(!fixture.stack()[try #require(fixture.list().rows.firstIndex { $0.list == .strokes })].stroke.settings.basic.startArrowhead.contours.isEmpty)
        #expect(ArrowheadEditorModel.unit(ArrowheadEditorModel.pasteboard(Point(x: 1, y: 2))) == Point(x: 1, y: 2))
    }
}

extension ArrowheadEditorController {
    /// Draws the editor's guides into a scratch context (the overlay hook).
    func drawGuides() {
        model.drawGuides(in: DrawingToolTests.bitmap(), viewport: canvas.viewport)
    }
}
