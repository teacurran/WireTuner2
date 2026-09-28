import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTRender
@testable import WireTuner

/// DRAW-061: the Object panel's ellipse row.
@Suite(.serialized) @MainActor struct EllipseSectionTests {
    @Test func theRowShowsAndWritesTheArc() async throws {
        let document = DocumentHandle.memory(title: "Ellipse")
        let node = try #require(await document.perform(CreateShape(.ellipse, size: Size(width: 80, height: 40))).value?.createdObjects.first)
        let model = ObjectPanelModel(document: document, selection: Selection([SelectionID(node)]))
        let section = try #require(model.ellipse)
        #expect(section.start == 0 && section.end == 0 && section.closed == .on)
        EllipseSectionView.angle(model, end: false)(30)
        await document.settle()
        EllipseSectionView.angle(ObjectPanelModel(document: document, selection: Selection([SelectionID(node)])), end: true)(120)
        await document.settle()
        EllipseSectionView.closed(section, ObjectPanelModel(document: document, selection: Selection([SelectionID(node)]))).wrappedValue = false
        await document.settle()
        #expect(document.undoTitle == "Undo Change arc")
        let after = try #require(ObjectPanelModel(document: document, selection: Selection([SelectionID(node)])).ellipse)
        #expect(after.start == 30 && after.end == 120 && after.closed == .off)
        #expect(EllipseSectionView.closed(section, model).wrappedValue, "the binding reads the section it was built from")
        _ = EllipseSectionView(section: after, model: model).body
        // The registry shows the row for an ellipse only.
        let views = InspectorRegistry.standard.views(for: model).map(\.id)
        #expect(views.contains("ellipse"))
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        let mixed = ObjectPanelModel(document: document, selection: Selection([SelectionID(node), rect]))
        #expect(mixed.ellipse == nil && mixed.setArc(start: 5) == nil)
        #expect(ObjectPanelModel(document: document, selection: Selection([])).ellipse == nil)
    }
}
