import AppKit
import SwiftUI
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// OBJ-033's remainder (the centre fields bound to the transform handles, *Fills* and *Contents*,
/// opening on a tab), OBJ-021 (names and notes) and OBJ-035 (3D Rotation and Mirror).
@Suite(.serialized) @MainActor struct TransformExtrasTests {
    // MARK: Transform panel

    @Test func theCentreFieldsFollowAndMoveTheHandles() async throws {
        let document = DocumentHandle.memory(title: "Centre")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 20)])[0]
        let link = TransformCenterLink()
        let selection = ActiveSelection(model: SelectionModel(Selection([rect])), document: document)
        let state = TransformPanelState()
        state.show(.rotate)
        #expect(TransformPanelBody.center(state.model, selection: selection, link: link) == Point(x: 20, y: 10), "the selection's centre")
        // Handles shown: the panel reads their centre and a typed centre moves it.
        var handleCenter: Point? = Point(x: 5, y: 5)
        link.register(.init(center: { handleCenter }, move: { handleCenter = $0; return true }), for: document)
        #expect(TransformPanelBody.center(state.model, selection: selection, link: link) == Point(x: 5, y: 5))
        let revision = link.revision
        TransformPanelBody.setCenter(30, horizontal: true, state: state, selection: selection, link: link)
        #expect(handleCenter == Point(x: 30, y: 5) && state.model.centerX == nil && link.revision > revision)
        TransformPanelBody.setCenter(12, horizontal: false, state: state, selection: selection, link: link)
        #expect(handleCenter == Point(x: 30, y: 12))
        // Apply turns about the handles' centre.
        state.model.angle = 90
        let change = try #require(await TransformPanelBody.apply(state.model, selection: selection, link: link)?.value)
        #expect(change.label == "Rotate")
        let expected = WTGeometry.AffineTransform.rotation(radians: -.pi / 2, around: Point(x: 30, y: 12))
        #expect(nearlyEqual(Objects.transform(of: rect.opID, in: document.state), WTGeometry.AffineTransform.translation(x: 0, y: 0).concatenating(expected)))
        // Handles hidden: typed values are kept for Apply instead.
        handleCenter = nil
        link.register(.init(center: { nil }, move: { _ in false }), for: document)
        TransformPanelBody.setCenter(7, horizontal: true, state: state, selection: selection, link: link)
        #expect(state.model.centerX == 7)
        link.unregister(document)
        link.unregister(document)
        #expect(!link.move(to: .zero, for: document) && link.center(for: document) == nil)
        #expect(TransformPanelBody.center(state.model, selection: nil, link: link) == nil)
        TransformPanelBody.setCenter(1, horizontal: true, state: state, selection: nil, link: link)
    }

    @Test func thePointerToolRegistersItsHandlesCentre() async throws {
        let document = DocumentHandle.memory(title: "Pointer")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 20)])[0]
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.selection.model.set(Selection([rect]))
        let pointer = PointerTool()
        pointer.activate(in: context)
        defer { pointer.deactivate() }
        #expect(TransformCenterLink.shared.center(for: document) == nil, "no handles shown")
        #expect(!pointer.moveHandleCenter(to: .zero))
        pointer.showHandles()
        #expect(TransformCenterLink.shared.center(for: document) == Point(x: 20, y: 10))
        #expect(TransformCenterLink.shared.move(to: Point(x: 3, y: 4), for: document))
        #expect(pointer.handles?.center == Point(x: 3, y: 4))
        pointer.deactivate()
        #expect(TransformCenterLink.shared.center(for: document) == nil)
        pointer.activate(in: context)
    }

    @Test func theOptionsPersistAndOpenOnATab() throws {
        let defaults = TestDefaults()
        defer { defaults.remove() }
        let state = TransformPanelState(defaults: defaults.defaults)
        #expect(state.model.fills && state.model.contents && !state.model.strokes)
        state.model.fills = false
        state.model.strokes = true
        let reopened = TransformPanelState(defaults: defaults.defaults)
        #expect(!reopened.model.fills && reopened.model.strokes && reopened.model.contents)
        var model = TransformPanelModel()
        model.fills = false
        model.contents = false
        model.tab = .scale
        model.scaleX = 50
        let document = DocumentHandle.memory(title: "Options")
        #expect(model.command(nodes: [OpID(counter: 1, replica: 1)], state: document.state) == nil, "nothing with geometry")
        // Opening on a tab: the menu items and the tools' double-click.
        let panels = EditingPanels(defaults: nil)
        var shown: [PanelID] = []
        panels.showPanel = { shown.append($0) }
        panels.openTransform(.skew)
        #expect(panels.transform.model.tab == .skew && shown == ["transform"])
        #expect(EditingPanels.tab(for: "rotate") == .rotate && EditingPanels.tab(for: "move") == nil && EditingPanels.tab(for: "pen") == nil)
        var previous: [ToolID] = []
        let options = panels.toolOptions { previous.append($0.id) }
        options(ToolCatalog.all.first { $0.id == "reflect" }!)
        options(ToolCatalog.all.first { $0.id == .pointer }!)
        #expect(panels.transform.model.tab == .reflect && previous == [.pointer])
        let commands = panels.commands { nil }
        #expect(commands.count == 11)
        let scale = try #require(commands.first { $0.id == ContextMenuCatalog.ID.transformScale })
        if case .perform(let run) = scale.action { run() }
        #expect(panels.transform.model.tab == .scale)
        // Installing puts the three panels in the registry ahead of the placeholders.
        let registry = PanelRegistry()
        let commandRegistry = CommandRegistry()
        panels.install(panels: registry, commands: commandRegistry, selection: ActiveSelection()) { nil }
        #expect(["align", "transform", "findReplace"].allSatisfy { registry.descriptor(for: $0) != nil })
        #expect(commandRegistry.command(ContextMenuCatalog.ID.alignLeft) != nil)
    }

    @Test func thePanelBodyShowsTheCentreAndToggles() async throws {
        let document = DocumentHandle.memory(title: "Body")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 20)])[0]
        let selection = ActiveSelection(model: SelectionModel(Selection([rect])), document: document)
        let state = TransformPanelState()
        for tab in TransformPanelModel.Tab.allCases {
            state.show(tab)
            _ = TransformPanelBody(selection: selection, state: state).body
        }
        _ = TransformPanel.descriptor(selection: selection, state: state).makeView()
    }

    // MARK: Names and notes

    @Test func aTypedNameIsOneChangeAfterIdleAndStopsAtTheLimit() async throws {
        let document = DocumentHandle.memory(title: "Names")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])[0]
        let model = ObjectPanelModel(document: document, selection: Selection([rect]))
        let editor = IdleTextEditor(value: "", limit: 256, idle: .milliseconds(30))
        editor.connect { model.perform(model.setName($0)) }
        let name = "A name thirty characters long."
        #expect(name.count == 30)
        for index in name.indices { editor.edit(String(name[...index])) }
        #expect(editor.draftIsDirty && editor.isPending)
        let changesBefore = document.changeCount
        try await Task.sleep(for: .milliseconds(120))
        await document.settle()
        #expect(!editor.draftIsDirty && document.state.name(of: rect.opID) == name)
        #expect(document.changeCount == changesBefore + 1, "one change after idle")
        #expect(document.undoTitle == "Undo Change name")
        _ = await document.undo().value
        #expect(document.state.name(of: rect.opID) == nil, "one undo step")
        // The limit: input stops there.
        var beeps = 0
        let limited = IdleTextEditor(value: nil, limit: 5)
        limited.beep = { beeps += 1 }
        limited.edit("123456789")
        #expect(limited.text == "12345" && beeps == 1)
        // A remote change while a burst is pending does not replace the draft.
        limited.bind("remote")
        #expect(limited.text == "12345")
        limited.cancel()
        #expect(limited.text == "remote" && !limited.isPending)
        limited.bind("again")
        #expect(limited.text == "again")
        limited.edit("again")
        #expect(!limited.draftIsDirty, "unchanged text is no burst")
        var written: [String] = []
        let focused = IdleTextEditor(value: "a", limit: 10)
        focused.connect { written.append($0) }
        focused.edit("ab")
        IdleTextField.focusing(focused)(true, false)
        #expect(written == ["ab"], "leaving the field writes the burst at once")
        focused.flush()
        #expect(written == ["ab"])
        IdleTextField.binding(focused)(nil, "zz")
        #expect(focused.text == "zz")
        let binding = IdleTextField.text(focused)
        binding.wrappedValue = "zzz"
        #expect(binding.wrappedValue == "zzz")
        _ = IdleTextField(title: "Note", value: nil, limit: 8_192, multiline: true, identifier: "n") { _ in }.body
        _ = IdleTextField(title: "Name", value: "x", limit: 256, identifier: "m") { _ in }.body
    }

    @Test func namesShowInTheInfoToolbarAndInMoveTitles() async throws {
        let document = DocumentHandle.memory(title: "Info")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 40, height: 40)])[0]
        _ = await document.perform(SetNameOrNote([rect.opID], .name, "Logo mark")).value
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        let pointer = PointerTool()
        pointer.activate(in: context)
        pointer.pointerMoved(TestEvents.point(20, 20))
        #expect(pointer.info.objectKind == "Logo mark")
        pointer.pointerMoved(TestEvents.point(300, 250))
        #expect(pointer.info.objectKind == nil)
        // A move of the named object is titled with its name.
        let move = NamedChange.move(MoveObjects([rect.opID], by: Vector(dx: 5, dy: 0)), nodes: [rect.opID], state: document.state)
        #expect(move.label == "Move \"Logo mark\"")
        _ = await document.perform(move).value
        #expect(document.undoTitle == "Undo Move \"Logo mark\"")
        let other = await document.addRectangles([Rect(x: 100, y: 100, width: 5, height: 5)])[0]
        #expect(NamedChange.move(MoveObjects([other.opID], by: .zero), nodes: [other.opID], state: document.state).label == "Move")
        let model = ObjectPanelModel(document: document, selection: Selection([rect]))
        #expect(model.setPosition(x: 50)?.label == "Move \"Logo mark\"")
        let editing = ObjectEditing(document: document, selection: SelectionController(document: document))
        editing.selection.model.set(Selection([rect]))
        #expect(editing.nudgeCommand(Vector(dx: 1, dy: 0))?.label == "Move \"Logo mark\"")
        // Text blocks show their name too.
        let text = try #require(await document.addText("Headline", at: Point(x: 200, y: 20)))
        _ = await document.perform(SetNameOrNote([text], .name, "Title")).value
        #expect(ObjectPanelModel(document: document, selection: Selection([SelectionID(text)])).common?.name == "Title")
    }

    // MARK: 3D Rotation and Mirror

    @Test func easyThreeDRotationIsTheProjectionsSkewAndScale() async throws {
        let rotation = Rotation3D(yaw: 0.4, pitch: -0.3)
        let (cy, sy, cx, sx) = (cos(0.4), sin(0.4), cos(-0.3), sin(-0.3))
        // x' = cy·x + sy·sx·y, y' = cx·y: the first-order projection seen from the origin.
        #expect(nearlyEqual(rotation.affine, WTGeometry.AffineTransform(a: cy, b: 0, c: sy * sx, d: cx, tx: 0, ty: 0)))
        let origin = Point(x: 50, y: 50)
        let near = Point(x: 50.001, y: 50.002)
        let projected = rotation.project(near, origin: origin, eye: origin, distance: 500)
        let linear = rotation.affine.apply(Point(x: 0.001, y: 0.002))
        #expect(abs(projected.x - 50 - linear.x) < 1e-8 && abs(projected.y - 50 - linear.y) < 1e-8)
        #expect(Rotation3D(yaw: 0, pitch: 0).project(Point(x: 3, y: 4), origin: origin, eye: origin, distance: 500) == Point(x: 3, y: 4), "rotation by 0 is identity")
        #expect(Rotation3D(drag: Vector(dx: 100, dy: 0), constrained: true).yaw == .pi / 4)
        // In a window-less context: the tool writes one TransformObjects about the selection's centre.
        let document = DocumentHandle.memory(title: "3D")
        let rect = await document.addRectangles([Rect(x: 0, y: 0, width: 100, height: 40)])[0]
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.selection.model.set(Selection([rect]))
        let tool = Rotation3DTool()
        tool.activate(in: context)
        #expect(tool.command() == nil)
        tool.mouseDown(TestEvents.point(50, 20))
        tool.mouseDragged(TestEvents.point(90, 50))
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: context.viewport)
        #expect(tool.place(.origin) == Point(x: 0, y: 40) && tool.place(.gravity) == Point(x: 50, y: 20) && tool.place(.click) == Point(x: 50, y: 20))
        let command = try #require(tool.command())
        #expect(command.label == "3D rotate")
        let expected = Rotation3D(drag: Vector(dx: 40, dy: 30), constrained: false)
        let before = Objects.transform(of: rect.opID, in: document.state)
        _ = await document.perform(command).value
        let center = Point(x: 50, y: 20)
        let about = WTGeometry.AffineTransform.translation(Vector(dx: -center.x, dy: -center.y)).concatenating(expected.affine).concatenating(.translation(Vector(dx: center.x, dy: center.y)))
        #expect(nearlyEqual(Objects.transform(of: rect.opID, in: document.state), before.concatenating(about)))
        tool.mouseUp(TestEvents.point(90, 50))
        tool.flagsChanged(TestEvents.point(0, 0))
        tool.pointerMoved(TestEvents.point(7, 8))
        #expect(!tool.keyDown(TestEvents.escape) && !tool.hasSomethingToCancel)
        tool.deactivate()
    }

    @Test func expertThreeDRotationProjectsPathPointsFromTheProjectionPoint() async throws {
        let document = DocumentHandle.memory(title: "Expert")
        let path = try #require(await document.addPath([Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100)], closed: true))
        let rect = await document.addRectangles([Rect(x: 200, y: 0, width: 10, height: 10)])[0]
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.selection.model.set(Selection([path, rect]))
        let settings = Rotation3DSettings(expert: true, rotateFrom: .click, distance: 300, projectFrom: .point, projectX: 10, projectY: 20)
        let tool = Rotation3DTool { settings }
        tool.activate(in: context)
        tool.mouseDown(TestEvents.point(0, 0))
        tool.mouseDragged(TestEvents.point(60, 0))
        let before = try #require(document.path(path)?.contours[0].drawn)
        let command = try #require(tool.command())
        _ = await document.perform(command).value
        let after = try #require(document.path(path)?.contours[0].drawn)
        let rotation = Rotation3D(drag: Vector(dx: 60, dy: 0), constrained: false)
        for (old, new) in zip(before, after) {
            let expected = rotation.project(old.anchor, origin: .zero, eye: Point(x: 10, y: 20), distance: 300)
            #expect(new.id == old.id && abs(new.anchor.x - expected.x) < 1e-6 && abs(new.anchor.y - expected.y) < 1e-6)
        }
        #expect(Objects.transform(of: rect.opID, in: document.state) != .identity, "other objects take the easy transformation")
        // The X/Y point falls back to the last pointer position when unset.
        let unset = Rotation3DTool { Rotation3DSettings(expert: true, projectFrom: .point) }
        unset.activate(in: context)
        unset.pointerMoved(TestEvents.point(33, 44))
        #expect(unset.place(.point) == Point(x: 33, y: 44))
        #expect(unset.place(.click) == unset.place(.center), "no press: the centre")
        let settingsFromPreferences = Rotation3DSettings(preferences: TestEnvironment().preferences)
        #expect(settingsFromPreferences == Rotation3DSettings())
    }

    @Test func mirrorInMultipleModeMakesSixReflectedClonesInOneChange() async throws {
        let document = DocumentHandle.memory(title: "Mirror")
        let rect = await document.addRectangles([Rect(x: 60, y: 0, width: 20, height: 10)])[0]
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.selection.model.set(Selection([rect]))
        let tool = MirrorTool { MirrorSettings(axis: .multiple, axes: 6) }
        tool.activate(in: context)
        tool.mouseDown(TestEvents.point(50, 50))
        tool.mouseUp(TestEvents.point(50, 50))
        await document.settle()
        #expect(document.undoTitle == "Undo Mirror")
        let objects = document.scene.topLevel.count
        #expect(objects == 7, "the original and six clones")
        let matrices = MirrorGeometry.matrices(MirrorSettings(axis: .multiple, axes: 6))
        #expect(matrices.count == 6 && matrices.allSatisfy { abs($0.determinant + 1) < 1e-9 }, "all reflections")
        #expect(MirrorGeometry.matrices(MirrorSettings(axis: .multiple, axes: 3, rotate: true)).allSatisfy { abs($0.determinant - 1) < 1e-9 })
        #expect(MirrorGeometry.matrices(MirrorSettings(axis: .both)).count == 3)
        #expect(nearlyEqual(MirrorGeometry.matrices(MirrorSettings(axis: .horizontal))[0], .scale(x: 1, y: -1)))
        #expect(nearlyEqual(MirrorGeometry.matrices(MirrorSettings(axis: .vertical))[0], .scale(x: -1, y: 1)))
        #expect(MirrorSettings(preferences: TestEnvironment().preferences) == MirrorSettings())
    }

    @Test func mirrorKeysAndCloseParts() async throws {
        let document = DocumentHandle.memory(title: "Mirror keys")
        let rect = await document.addRectangles([Rect(x: 60, y: 0, width: 20, height: 10)])[0]
        let host = RecordingHost()
        let context = ToolContext(document: document, host: host, selection: SelectionController(document: document))
        context.selection.model.set(Selection([rect]))
        let tool = MirrorTool { MirrorSettings(axis: .multiple, axes: 2) }
        tool.activate(in: context)
        #expect(!tool.keyDown(TestEvents.key("", keyCode: 124)), "no drag: the keys do nothing")
        tool.mouseDown(TestEvents.point(50, 50))
        #expect(tool.keyDown(TestEvents.key("", keyCode: 124)) && tool.effective.axes == 3)
        #expect(tool.keyDown(TestEvents.key("", keyCode: 123)) && tool.effective.axes == 2)
        #expect(tool.keyDown(TestEvents.key("", keyCode: 126)) && tool.effective.rotate)
        #expect(!tool.keyDown(TestEvents.key("a", keyCode: 0)))
        tool.mouseDragged(TestEvents.point(80, 20, [.option, .shift]))
        #expect(abs(tool.angle - .pi / 4) < 1e-9 && tool.center == Point(x: 50, y: 50))
        tool.drawOverlay(in: DrawingToolTests.bitmap(), viewport: context.viewport)
        tool.flagsChanged(TestEvents.point(0, 0))
        tool.cancel()
        #expect(!tool.hasSomethingToCancel && tool.command() == nil)
        // Close paths: an open path whose ends touch the vertical axis joins its reflection.
        let half = try #require(await document.addPath([Point(x: 100, y: 0), Point(x: 80, y: 20), Point(x: 100, y: 40)]))
        context.selection.model.set(Selection([half]))
        let closer = MirrorTool { MirrorSettings(axis: .vertical, closePaths: true) }
        closer.activate(in: context)
        closer.mouseDown(TestEvents.point(100, 20))
        closer.mouseUp(TestEvents.point(100, 20))
        await document.settle()
        let joined = try #require(document.path(half)?.contours[0])
        #expect(joined.closed && joined.drawn.count == 4, "the half, then its reflection's middle point")
        #expect(joined.drawn.map(\.anchor).contains(Point(x: 120, y: 20)))
        closer.deactivate()
        tool.deactivate()
    }
}
