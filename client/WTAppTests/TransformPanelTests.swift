import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// OBJ-033: the Transform panel.
@Suite @MainActor struct TransformPanelTests {
    @Test func rotateWithThreeCopiesAboutTheTypedCentre() async throws {
        let document = DocumentHandle.memory(title: "Transform")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        let selection = ActiveSelection(model: SelectionModel(Selection([rect])), document: document)
        var model = TransformPanelModel()
        model.tab = .rotate
        model.angle = -30
        model.centerX = 100
        model.centerY = 50
        model.copies = 3
        let change = try #require(await TransformPanelBody.apply(model, selection: selection)?.value)
        #expect(change.label == "Rotate with 3 copies")
        let copies = change.createdRoots
        #expect(copies.count == 3)
        for (k, copy) in copies.enumerated() {
            let expected = WTGeometry.AffineTransform.rotation(radians: Double(k + 1) * .pi / 6, around: Point(x: 100, y: 50))
            #expect(nearlyEqual(Objects.transform(of: copy, in: document.state), expected))
        }
    }

    @Test func eachTabsMatrix() {
        var model = TransformPanelModel()
        model.moveX = 10
        model.moveY = 5
        #expect(model.matrix == .translation(x: 10, y: -5), "positive Y moves up")
        model.tab = .reflect
        model.axis = 90
        #expect(nearlyEqual(model.matrix, WTGeometry.AffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 0, ty: 0)), "90° flips left to right")
        model.axis = 0
        #expect(nearlyEqual(model.matrix, WTGeometry.AffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)), "0° flips top to bottom")
        model.tab = .scale
        model.scaleX = 200
        #expect(model.matrix == .scale(2))
        model.uniform = false
        model.scaleY = 50
        #expect(model.matrix == .scale(x: 2, y: 0.5))
        model.tab = .skew
        model.skewX = 45
        #expect(nearlyEqual(model.matrix, .shear(x: 1, y: 0)))
        #expect(TransformPanelModel.Tab.allCases.map(\.title) == ["Move", "Rotate", "Scale", "Skew", "Reflect"])
        #expect(TransformPanelModel.Tab.move.id == "move")
    }

    @Test func applyThroughTheWindowRemembersTheTransformation() async throws {
        let document = DocumentHandle.memory(title: "Apply")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        let controller = SelectionController(document: document)
        controller.model.set(Selection([rect]))
        let editing = ObjectEditing(document: document, selection: controller,
                                    pasteboard: SystemObjectPasteboard(NSPasteboard(name: NSPasteboard.Name("transform.\(UUID().uuidString)"))))
        let selection = ActiveSelection(model: controller.model, document: document, editing: editing)
        var model = TransformPanelModel()
        model.tab = .scale
        model.scaleX = 300
        model.strokes = true
        _ = await TransformPanelBody.apply(model, selection: selection)?.value
        #expect(editing.lastTransform?.kind == .scale)
        #expect(document.object(for: rect)!.bounds!.width > 30)
        // Nothing to apply to, or a matrix without an inverse.
        #expect(TransformPanelBody.apply(model, selection: nil) == nil)
        model.scaleX = 0
        #expect(model.command(nodes: [rect.opID], state: document.state) == nil)
        #expect(TransformPanelModel().command(nodes: [], state: document.state) == nil)
        #expect(TransformPanelModel.center(of: [], in: document.state) == nil)
        // The body and the descriptor build.
        _ = TransformPanelBody(selection: selection).body
        _ = TransformPanelBody.field("X", .constant(1), unit: .points, identifier: "x")
        #expect(TransformPanel.descriptor(selection: selection).id == "transform")
    }
}
