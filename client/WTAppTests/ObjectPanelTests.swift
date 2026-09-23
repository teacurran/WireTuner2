import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// DRAW-004: the Object panel's path and point sections.
@Suite @MainActor struct ObjectPanelTests {
    /// A document with an open three-point path and a closed triangle.
    @MainActor
    final class Fixture {
        let document = DocumentHandle.memory(title: "Panel")
        var open = SelectionID(NodeID(counter: 0, replica: 0))
        var closed = SelectionID(NodeID(counter: 0, replica: 0))

        static func make() async -> Fixture {
            let fixture = Fixture()
            fixture.open = await fixture.document.addPath([Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 10, y: 10)])!
            fixture.closed = await fixture.document.addPath([Point(x: 50, y: 50), Point(x: 60, y: 50), Point(x: 55, y: 60)], closed: true)!
            return fixture
        }

        func model(_ selection: Selection) -> ObjectPanelModel {
            ObjectPanelModel(document: document, selection: selection)
        }

        func point(_ id: SelectionID, _ index: Int) -> PointReference {
            let contour = document.path(id)!.contours[0]
            return PointReference(node: id.node, contour: contour.id, point: contour.drawn[index].id)
        }
    }

    @Test func thePathSectionShowsMixedStateAndCounts() async {
        let fixture = await Fixture.make()
        #expect(fixture.model(.empty).path == nil && fixture.model(.empty).point == nil)
        let one = fixture.model(Selection([fixture.open])).path
        #expect(one?.closed == .off && one?.evenOdd == .off && one?.flatness == 0 && one?.points == 3)
        let both = fixture.model(Selection([fixture.open, fixture.closed])).path
        #expect(both?.closed == .mixed, "the contours differ")
        #expect(both?.points == 6)
        #expect(MixedState([true, true]) == .on && MixedState([false]) == .off && MixedState([true, false]).isOn == false)
    }

    @Test func eachControlWritesOneChangeWithItsLabelAndUndoes() async throws {
        let fixture = await Fixture.make()
        let document = fixture.document
        let model = fixture.model(Selection([fixture.open, fixture.closed]))
        _ = await model.perform(model.setClosed(true))?.value
        #expect(document.undoTitle == "Undo Close Path")
        #expect(fixture.model(Selection([fixture.open, fixture.closed])).path?.closed == .on)
        _ = await document.undo().value
        #expect(fixture.model(Selection([fixture.open, fixture.closed])).path?.closed == .mixed)

        let changes = document.changeCount
        _ = await model.perform(model.setEvenOdd(true))?.value
        #expect(document.changeCount == changes + 1, "one change for both paths")
        #expect(document.undoTitle == "Undo Even/Odd Fill")
        #expect(fixture.model(Selection([fixture.open, fixture.closed])).path?.evenOdd == .on)

        _ = await model.perform(model.setFlatness(2))?.value
        #expect(document.undoTitle == "Undo Flatness")
        #expect(fixture.model(Selection([fixture.open])).path?.flatness == 2)
        #expect(model.setFlatness(-1) == nil, "negative flatness is refused")

        _ = await model.perform(model.setClosed(false))?.value
        #expect(document.undoTitle == "Undo Open Path")
        #expect(fixture.model(.empty).setClosed(true) == nil && fixture.model(.empty).setEvenOdd(true) == nil)
        #expect(fixture.model(.empty).perform(nil) == nil)
    }

    @Test func thePointSectionEditsTheOneSelectedPoint() async throws {
        let fixture = await Fixture.make()
        let document = fixture.document
        let reference = fixture.point(fixture.open, 1)
        let selection = Selection().applying([fixture.open], sub: [fixture.open: .points([reference])], mode: .replace)
        let point = try #require(fixture.model(selection).point)
        #expect(point.kind == .corner && !point.automatic && point.location == Point(x: 10, y: 0) && !point.handlesUnlinked)

        _ = await fixture.model(selection).perform(fixture.model(selection).setKind(.curve))?.value
        #expect(document.undoTitle == "Undo Set Point Type")
        #expect(fixture.model(selection).point?.kind == .curve)

        _ = await fixture.model(selection).perform(fixture.model(selection).setAutomatic(true))?.value
        #expect(document.undoTitle == "Undo Automatic")
        #expect(fixture.model(selection).point?.automatic == true)
        #expect(fixture.model(selection).point.map { $0.location } == Point(x: 10, y: 0))

        _ = await fixture.model(selection).perform(fixture.model(selection).setAutomatic(false))?.value
        _ = await fixture.model(selection).perform(fixture.model(selection).retractHandles())?.value
        #expect(document.undoTitle == "Undo Retract Handles")
        let contour = try #require(document.path(fixture.open)?.contours.first)
        #expect(contour.drawn[1].inHandle == .zero && contour.drawn[1].outHandle == .zero)

        _ = await fixture.model(selection).perform(fixture.model(selection).setLocation(Point(x: 12, y: 3)))?.value
        #expect(document.undoTitle == "Undo Move Point")
        #expect(fixture.model(selection).point?.location == Point(x: 12, y: 3))
        _ = await document.undo().value
        #expect(fixture.model(selection).point?.location == Point(x: 10, y: 0))
        #expect(fixture.model(selection).setLocation(Point(x: .nan, y: 0)) == nil)

        let two = selection.applying([fixture.open], sub: [fixture.open: .points([fixture.point(fixture.open, 0)])], mode: .add)
        #expect(fixture.model(two).point == nil, "two points: no point section")
        let none = fixture.model(Selection([fixture.open]))
        #expect(none.setKind(.curve) == nil && none.retractHandles() == nil && none.setAutomatic(true) == nil && none.setLocation(.zero) == nil)
    }

    @Test func rectanglesAreNotPaths() async throws {
        let document = DocumentHandle.memory(title: "Shapes")
        let ids = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        let corner = PointReference(node: ids[0].node, contour: .zero, point: OpID(counter: 1, replica: 0))
        let model = ObjectPanelModel(document: document, selection: Selection().applying(ids, sub: [ids[0]: .points([corner])], mode: .replace))
        #expect(model.path == nil && model.point == nil)
    }

    @Test func aRemoteChangeReachesThePanelModel() async throws {
        let fixture = await Fixture.make()
        let document = fixture.document
        // A change from another replica closing the open path, as the sync client delivers it.
        var other = DocumentCore(state: document.state, replica: 0xBEEF)
        let contour = try #require(document.path(fixture.open)?.contours.first)
        let outcome = try other.perform(SetClosed(node: fixture.open.opID, closed: true, contours: [contour.id]),
                                        recording: DocumentCore.Recording(limit: 10, now: Date()))
        _ = await document.receive(try #require(outcome?.change)).value
        #expect(fixture.model(Selection([fixture.open])).path?.closed == .on)
    }

    @Test func theControlsBindThroughTheModel() async throws {
        let fixture = await Fixture.make()
        let document = fixture.document
        let reference = fixture.point(fixture.open, 1)
        let selection = Selection([fixture.open]).applying([fixture.open], sub: [fixture.open: .points([reference])], mode: .replace)
        var model = fixture.model(selection)
        let path = try #require(model.path)
        PathSectionView.closed(path, model).wrappedValue = true
        await document.settle()
        #expect(fixture.model(selection).path?.closed == .on)
        #expect(PathSectionView.closed(path, model).wrappedValue == false, "the binding reads the section it was built from")
        PathSectionView.evenOdd(path, model).wrappedValue = true
        await document.settle()
        #expect(fixture.model(selection).path?.evenOdd == .on && !PathSectionView.evenOdd(path, model).wrappedValue)
        PathSectionView.flatness(model)(3)
        await document.settle()
        #expect(fixture.model(selection).path?.flatness == 3)
        #expect(["on", "off", "mixed"] == [MixedState.on, .off, .mixed].map(PathSectionView.accessibilityValue))

        model = fixture.model(selection)
        let point = try #require(model.point)
        #expect(PointSectionView.kind(point, model).wrappedValue == .corner)
        PointSectionView.kind(point, model).wrappedValue = .curve
        await document.settle()
        #expect(fixture.model(selection).point?.kind == .curve)
        #expect(PointSectionView.automatic(point, model).wrappedValue == false)
        PointSectionView.automatic(point, model).wrappedValue = true
        await document.settle()
        #expect(fixture.model(selection).point?.automatic == true)
        PointSectionView.retract(model)()
        await document.settle()
        #expect(document.undoTitle == "Undo Retract Handles")
        PointSectionView.location(point, model, horizontal: true)(20)
        await document.settle()
        #expect(fixture.model(selection).point?.location == Point(x: 20, y: 0))
        PointSectionView.location(point, model, horizontal: false)(5)
        await document.settle()
        #expect(fixture.model(selection).point?.location == Point(x: 10, y: 5), "Y keeps the section's X")

        #expect(FieldFormat<Double>.number.parse(" 2.5 ", nil) == 2.5 && FieldFormat<Double>.number.parse("abc", nil) == nil)
    }

    @Test func flatnessThatDiffersIsBlank() async {
        let fixture = await Fixture.make()
        _ = await fixture.document.perform(SetFlatness(node: fixture.open.opID, flatness: 2)).value
        #expect(fixture.model(Selection([fixture.open, fixture.closed])).path?.flatness == nil)
    }

    @Test func theBodyRendersForEveryState() async {
        let fixture = await Fixture.make()
        let reference = fixture.point(fixture.open, 1)
        let selection = SelectionModel(Selection().applying([fixture.open], sub: [fixture.open: .points([reference])], mode: .replace))
        let active = ActiveSelection(model: selection, document: fixture.document)
        let view = NSHostingView(rootView: ObjectPanelBody(selection: active))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.width > 0)
        _ = NSHostingView(rootView: ObjectPanelBody(selection: nil)).fittingSize
        _ = NSHostingView(rootView: ObjectPanelBody(selection: ActiveSelection())).fittingSize
        let field = CommitField(title: "X", value: 1.5, identifier: "x") { _ in }
        let host = NSHostingView(rootView: field)
        _ = host.fittingSize
        host.rootView = CommitField(title: "X", value: 2.5, identifier: "x") { _ in }
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        let unlinked = ObjectPanelModel.PointSection(
            node: fixture.open.opID, contour: .zero, point: .zero, kind: .curve, automatic: false, location: .zero, handlesUnlinked: true
        )
        _ = NSHostingView(rootView: PointSectionView(section: unlinked, model: fixture.model(.empty))).fittingSize
        #expect(FieldFormat<Double>.number.format(nil) == "")
        #expect(FieldFormat<Double>.number.format(1.25) == "1.25" && FieldFormat<Double>.number.format(1234.5) == "1234.5")
        #expect(PointSectionView.kinds.map(\.1) == ["Corner", "Curve", "Connector"])
    }
}
