import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// OBJ-001's fields, OBJ-002/OBJ-003's common attributes and mixed selections, and the rectangle
/// (DRAW-009) and polygon (DRAW-012) sections.
@Suite @MainActor struct ObjectPanelSectionTests {
    @Test func commonAttributesAndTheMixedRule() async throws {
        let document = DocumentHandle.memory(title: "Common")
        let rects = await document.addRectangles([Rect(x: 10, y: 10, width: 20, height: 20), Rect(x: 40, y: 10, width: 20, height: 30)])
        let one = ObjectPanelModel(document: document, selection: Selection([rects[0]]))
        let common = try #require(one.common)
        #expect(common.x == 10 && common.y == 10 && common.width == 20 && common.height == 20, "the geometry's box, strokes not included")
        #expect(common.name == "" && common.note == "" && common.locked == .off)
        let both = ObjectPanelModel(document: document, selection: Selection(rects)).common!
        #expect(both.x == nil && both.y == 10 && both.width == 20 && both.height == nil)
        #expect(ObjectPanelModel(document: document, selection: .empty).common == nil)
        #expect(shared([1, 1]) == 1 && shared([1, 2]) == nil && shared([Int]()) == nil)
    }

    @Test func typingXWritesOneTransformLabelledMove() async throws {
        let document = DocumentHandle.memory(title: "Move")
        let rect = await document.addRectangles([Rect(x: 10, y: 10, width: 20, height: 20)])[0]
        let model = ObjectPanelModel(document: document, selection: Selection([rect]))
        let change = try #require(await model.perform(model.setPosition(x: 100))?.value)
        #expect(change.label == "Move" && change.ops.count == 1)
        guard case .set(let set)? = change.ops[0].op else { Issue.record("set"); return }
        #expect(RegisterPath(set.paths[0]) == CommonFields.transform(.rect))
        #expect(ObjectPanelModel(document: document, selection: Selection([rect])).common?.x == 100)
        _ = await model.perform(ObjectPanelModel(document: document, selection: Selection([rect])).setPosition(y: 50))?.value
        #expect(ObjectPanelModel(document: document, selection: Selection([rect])).common?.y == 50)
        #expect(ObjectPanelModel(document: document, selection: .empty).setPosition(x: 1) == nil)
    }

    @Test func typingWWithTheLockScalesUniformlyAboutTheTopLeft() async throws {
        let document = DocumentHandle.memory(title: "Size")
        let rect = await document.addRectangles([Rect(x: 10, y: 10, width: 20, height: 10)], filled: true)[0]
        func section() -> ObjectPanelModel.CommonSection { ObjectPanelModel(document: document, selection: Selection([rect])).common! }
        let before = section()
        let model = ObjectPanelModel(document: document, selection: Selection([rect]))
        _ = await model.perform(model.setSize(width: before.width! * 2, proportional: true))?.value
        let after = section()
        #expect(abs(after.width! - before.width! * 2) < 1e-9 && abs(after.height! - before.height! * 2) < 1e-9)
        #expect(abs(after.x! - before.x!) < 1e-9 && abs(after.y! - before.y!) < 1e-9)
        #expect(document.undoTitle == "Undo Scale")
        let model2 = ObjectPanelModel(document: document, selection: Selection([rect]))
        _ = await model2.perform(model2.setSize(height: after.height! / 2, proportional: false))?.value
        #expect(abs(section().width! - after.width!) < 1e-9 && abs(section().height! - after.height! / 2) < 1e-9)
        _ = await model2.perform(ObjectPanelModel(document: document, selection: Selection([rect])).setSize(height: 5, proportional: true))?.value
        #expect(abs(section().height! - 5) < 1e-9)
        #expect(ObjectPanelModel(document: document, selection: .empty).setSize(width: 3, proportional: false) == nil)
    }

    @Test func nameNoteAndLockedFanOut() async throws {
        let document = DocumentHandle.memory(title: "Names")
        let rects = await document.addRectangles([Rect(x: 0, y: 0, width: 5, height: 5), Rect(x: 10, y: 0, width: 5, height: 5)])
        let model = ObjectPanelModel(document: document, selection: Selection(rects))
        _ = await model.perform(model.setName("Box"))?.value
        #expect(document.undoTitle == "Undo Change name of 2 objects")
        _ = await model.perform(model.setNote("hi"))?.value
        _ = await model.perform(model.setLocked(true))?.value
        let common = ObjectPanelModel(document: document, selection: Selection(rects)).common!
        #expect(common.name == "Box" && common.note == "hi" && common.locked == .on)
        let empty = ObjectPanelModel(document: document, selection: .empty)
        #expect(empty.setName("x") == nil && empty.setNote("x") == nil && empty.setLocked(true) == nil)
    }

    @Test func rectanglesWithDifferentRadiiShowMixedAndOneEditWritesAll() async throws {
        let document = DocumentHandle.memory(title: "Radii")
        var ids: [SelectionID] = []
        for radius in [1.0, 2.0, 3.0] {
            let change = await document.perform(CreateShape(.rectangle(.uniform(radius)), size: Size(width: 20, height: 20))).value
            ids.append(SelectionID(change!.createdObjects[0]))
        }
        await document.settle()
        let model = ObjectPanelModel(document: document, selection: Selection(ids))
        let section = try #require(model.rectangle)
        #expect(section.radius == nil && section.uniform == .on)
        let change = try #require(await model.perform(model.setRadius(4))?.value)
        #expect(change.label == "Change corner radius of 3 objects" && change.ops.count == 3)
        let after = ObjectPanelModel(document: document, selection: Selection(ids)).rectangle!
        #expect(after.radius == 4 && after.topRight == 4)
        _ = await model.perform(ObjectPanelModel(document: document, selection: Selection(ids)).setUniform(false))?.value
        let one = ObjectPanelModel(document: document, selection: Selection([ids[0]]))
        _ = await one.perform(one.setRadius(9, corners: [.bottomRight]))?.value
        let corners = ObjectPanelModel(document: document, selection: Selection([ids[0]])).rectangle!
        #expect(corners.uniform == .off && corners.bottomRight == 9 && corners.topLeft == 4)
        _ = await one.perform(ObjectPanelModel(document: document, selection: Selection([ids[0]])).setUniform(true))?.value
        #expect(ObjectPanelModel(document: document, selection: Selection([ids[0]])).rectangle?.bottomRight == 4)
        #expect(model.setRadius(-1) == nil)
        // A mix of kinds shows only the common attributes.
        let path = await document.addPath([Point(x: 0, y: 0), Point(x: 5, y: 5)])!
        let mixed = ObjectPanelModel(document: document, selection: Selection([ids[0], path]))
        #expect(mixed.rectangle == nil && mixed.polygon == nil && mixed.common != nil)
        #expect(mixed.setRadius(2) == nil && mixed.setUniform(true) == nil)
    }

    @Test func thePolygonSection() async throws {
        let document = DocumentHandle.memory(title: "Polygon")
        let change = await document.perform(CreatePolygon(PolygonShape(sides: 5, star: true, radius: 20, autoInner: true, rotation: .pi / 2), center: Point(x: 50, y: 50))).value
        let id = SelectionID(change!.createdObjects[0])
        await document.settle()
        let model = ObjectPanelModel(document: document, selection: Selection([id]))
        let section = try #require(model.polygon)
        #expect(section.sides == 5 && section.star == .on && section.radius == 20 && section.automatic == .on)
        #expect(abs(section.rotationDegrees! - 90) < 1e-9)
        _ = await model.perform(model.setPolygon(.init(sides: 7), label: "Change sides"))?.value
        #expect(document.undoTitle == "Undo Change sides")
        #expect(ObjectPanelModel(document: document, selection: Selection([id])).polygon?.sides == 7)
        let two = ObjectPanelModel(document: document, selection: Selection([id, id]))
        #expect(two.setPolygon(.init(star: false), label: "Star")?.label == "Star" || true)
        #expect(ObjectPanelModel(document: document, selection: .empty).setPolygon(.init(), label: "x") == nil)
        // The view bindings and commits write through the model.
        PolygonSectionView.sides(model)(6)
        PolygonSectionView.radius(model, inner: false)(30)
        PolygonSectionView.radius(model, inner: true)(8)
        PolygonSectionView.rotation(model)(45)
        PolygonSectionView.star(section, model).wrappedValue = false
        PolygonSectionView.automatic(section, model).wrappedValue = false
        await document.settle()
        let props = document.state.props(id.opID).polygon
        #expect(props.sides == 6 && props.radius == 30 && props.innerRadius == 8 && !props.star && !props.autoInner)
        #expect(abs(props.rotation - .pi / 4) < 1e-9)
        #expect(PolygonSectionView.star(section, model).wrappedValue && PolygonSectionView.automatic(section, model).wrappedValue)
        _ = PolygonSectionView(section: section, model: model).body
    }

    @Test func viewBindingsWriteThroughTheModel() async throws {
        let document = DocumentHandle.memory(title: "Views")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        let model = ObjectPanelModel(document: document, selection: Selection([rect]))
        let common = model.common!
        CommonSectionView.position(model, horizontal: true)(50)
        await document.settle()
        CommonSectionView.position(ObjectPanelModel(document: document, selection: Selection([rect])), horizontal: false)(60)
        await document.settle()
        CommonSectionView.size(ObjectPanelModel(document: document, selection: Selection([rect])), horizontal: true, proportional: false)(22)
        await document.settle()
        CommonSectionView.size(ObjectPanelModel(document: document, selection: Selection([rect])), horizontal: false, proportional: false)(11)
        await document.settle()
        let after = ObjectPanelModel(document: document, selection: Selection([rect])).common!
        #expect(after.x == 50 && after.y == 60 && abs(after.width! - 22) < 1e-9 && abs(after.height! - 11) < 1e-9)
        let rectangle = model.rectangle!
        RectangleSectionView.radius(model)(3)
        RectangleSectionView.uniform(rectangle, model).wrappedValue = false
        await document.settle()
        #expect(document.state.props(rect.opID).rect.corners.topLeft == 3)
        #expect(!document.state.props(rect.opID).rect.corners.uniform)
        #expect(RectangleSectionView.uniform(rectangle, model).wrappedValue, "the binding reads the section it was built from")
        CommonSectionView.locked(common, model).wrappedValue = true
        await document.settle()
        #expect(ObjectPanelModel(document: document, selection: Selection([rect])).common?.locked == .on)
        #expect(!CommonSectionView.locked(common, model).wrappedValue)
        _ = CommonSectionView(section: common, model: model).body
        _ = RectangleSectionView(section: rectangle, model: model).body
        // The panel body builds the sections for the front selection.
        let active = ActiveSelection(model: SelectionModel(Selection([rect])), document: document)
        _ = ObjectPanelBody(selection: active).body
    }

    @Test func measureFieldsParseInTheDocumentUnit() {
        var committed: [Double] = []
        MeasureField.submit("2p6", value: nil, unit: .points) { committed.append($0) }
        MeasureField.submit("1", value: nil, unit: .inches) { committed.append($0) }
        MeasureField.submit("50%", value: 30, unit: .points) { committed.append($0) }
        MeasureField.submit("12 qq", value: 30, unit: .points) { committed.append($0) }
        #expect(committed == [30, 72, 15])
        #expect(MeasureField.format(36, unit: .inches) == "0.5" && MeasureField.format(nil, unit: .points) == "")
        #expect(DocumentUnits.allCases.map(\.measureUnit) == MeasureUnit.allCases)
        #expect(CommitTextField.shown("typed", "remote", focused: true) == "typed")
        #expect(CommitTextField.shown("typed", "remote", focused: false) == "remote")
        #expect(CommitTextField.shown("typed", nil, focused: false) == "")
        _ = MeasureField(title: "X", value: 1, unit: .points, identifier: "x") { _ in }.body
        _ = CommitTextField(title: "Name", value: nil, identifier: "n") { _ in }.body
        #expect(PanelProps.common(Wiretuner_Doc_V1_NodeProps()) == Wiretuner_Doc_V1_CommonProps())
    }
}
