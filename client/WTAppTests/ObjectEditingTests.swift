import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
@testable import WireTuner

/// The target a menu command acts on, changeable by a test.
@MainActor
final class EditingBox {
    var value: ObjectEditing?
    init(_ value: ObjectEditing?) { self.value = value }
}

/// The window's object commands (OBJ-009 to OBJ-020, OBJ-031's Transform Again, DRAW-026's Add
/// Points) through `ObjectEditing` and their menu commands.
@Suite @MainActor struct ObjectEditingTests {
    /// A private pasteboard per test.
    static func pasteboard() -> SystemObjectPasteboard {
        SystemObjectPasteboard(NSPasteboard(name: NSPasteboard.Name("wiretuner.test.\(UUID().uuidString)")))
    }

    @MainActor
    final class Fixture {
        let selection: SelectionFixture
        let editing: ObjectEditing
        var document: DocumentHandle { selection.document }

        init(_ selection: SelectionFixture) {
            self.selection = selection
            editing = ObjectEditing(document: selection.document, selection: SelectionController(document: selection.document), pasteboard: ObjectEditingTests.pasteboard())
            editing.nudgePause = .seconds(3600)
        }

        static func make() async -> Fixture {
            Fixture(await SelectionFixture.make())
        }

        func select(_ ids: [SelectionID]) {
            editing.selection.model.set(Selection(ids))
        }

        var selected: [SelectionID] { editing.selection.selection.ids }

        func bounds(_ id: SelectionID) -> Rect? {
            document.object(for: id)?.bounds
        }
    }

    @Test func copyAndPasteCentreInTheViewAndSelectTheCopy() async throws {
        let f = await Fixture.make()
        #expect(!f.editing.canPaste)
        #expect(f.editing.paste() == nil)
        f.editing.copy()
        #expect(!f.editing.canPaste, "nothing selected: nothing copied")
        f.select([f.selection.a])
        f.editing.copy()
        #expect(f.editing.canPaste)
        f.editing.visibleCenter = { Point(x: 300, y: 200) }
        await f.editing.paste()?.value
        await f.document.settle()
        let copy = try #require(f.selected.first)
        #expect(copy != f.selection.a)
        #expect(f.document.undoTitle == "Undo Paste")
        let bounds = try #require(f.bounds(copy))
        #expect(abs(bounds.midX - 300) < 1 && abs(bounds.midY - 200) < 1)
    }

    @Test func cutDeletesAndPasteInFrontAndBehindSitNextToTheSelection() async throws {
        let f = await Fixture.make()
        #expect(f.editing.cut() == nil)
        f.select([f.selection.b])
        _ = await f.editing.cut()?.value
        #expect(f.document.object(for: f.selection.b) == nil)
        #expect(f.document.undoTitle == "Undo Cut")
        #expect(f.editing.paste(inFront: true) == nil, "nothing selected")
        f.select([f.selection.a])
        #expect(f.editing.canPasteNextToSelection)
        await f.editing.paste(inFront: true)?.value
        await f.document.settle()
        let front = try #require(f.selected.first)
        let order = f.document.scene.topLevel
        #expect(order.firstIndex(of: front.node)! == order.firstIndex(of: f.selection.a.node)! + 1)
        f.select([f.selection.a])
        await f.editing.paste(inFront: false)?.value
        await f.document.settle()
        let behind = try #require(f.selected.first)
        let after = f.document.scene.topLevel
        #expect(after.firstIndex(of: behind.node)! + 1 == after.firstIndex(of: f.selection.a.node)!)
        // At the copied position.
        #expect(f.bounds(front) == Rect(x: 99.5, y: 9.5, width: 51, height: 51) || f.bounds(front) == f.bounds(behind))
    }

    @Test func duplicateRemembersTheTransformationOfExactlyTheDuplicates() async throws {
        let f = await Fixture.make()
        #expect(f.editing.duplicate() == nil && f.editing.clone() == nil)
        f.select([f.selection.a])
        await f.editing.duplicate()?.value
        await f.document.settle()
        let second = try #require(f.selected.first)
        #expect(f.editing.duplicateMemory?.nodes == [second.opID])
        let offset = f.bounds(second)!.minX - f.bounds(f.selection.a)!.minX
        #expect(abs(offset - 10) < 1e-9)
        // A move through the sink (a tool's drag) is remembered.
        _ = await f.editing.perform(MoveObjects([second.opID], by: Vector(dx: 20, dy: 0))).value
        #expect(f.editing.duplicateMemory?.recorded == .translation(x: 20, y: 0))
        await f.editing.duplicate()?.value
        await f.document.settle()
        let third = try #require(f.selected.first)
        #expect(abs(f.bounds(third)!.minX - f.bounds(second)!.minX - 20) < 1e-9)
        // Another command clears it; so does another selection.
        _ = await f.editing.perform(SetLocked([third.opID], locked: false)).value
        #expect(f.editing.duplicateMemory == nil)
        await f.editing.duplicate()?.value
        await f.document.settle()
        #expect(f.editing.duplicateMemory != nil)
        f.select([f.selection.b])
        #expect(f.editing.duplicateMemory == nil)
        // A transformation of other objects clears it too.
        await f.editing.duplicate()?.value
        await f.document.settle()
        _ = await f.editing.perform(TransformObjects([f.selection.a.opID], matrix: .scale(2), kind: .scale)).value
        #expect(f.editing.duplicateMemory == nil)
        // Clone: exactly on top.
        f.select([f.selection.b])
        await f.editing.clone()?.value
        await f.document.settle()
        #expect(f.bounds(f.selected[0]) == f.bounds(f.selection.b))
    }

    @Test func groupUngroupLockAndArrange() async throws {
        let f = await Fixture.make()
        #expect(f.editing.group() == nil && f.editing.ungroup() == nil && f.editing.setLocked(true) == nil && f.editing.arrange(.bringToFront) == nil)
        f.select([f.selection.a, f.selection.b])
        await f.editing.group()?.value
        await f.document.settle()
        let group = try #require(f.selected.first)
        #expect(f.document.object(for: group)?.kind == .group)
        #expect(f.editing.canUngroup)
        await f.editing.ungroup()?.value
        await f.document.settle()
        #expect(Set(f.selected) == [f.selection.a, f.selection.b])
        f.select([f.selection.a])
        #expect(f.editing.canSetLocked(true) && !f.editing.canSetLocked(false))
        _ = await f.editing.setLocked(true)?.value
        #expect(f.editing.canSetLocked(false))
        _ = await f.editing.setLocked(false)?.value
        _ = await f.editing.arrange(.bringToFront)?.value
        #expect(f.document.scene.topLevel.last == f.selection.a.node)
        // Ungrouping a rectangle converts it; a path cannot be ungrouped.
        f.select([f.selection.square])
        await f.editing.ungroup()?.value
        await f.document.settle()
        let converted = try #require(f.selected.first)
        #expect(f.document.object(for: converted)?.kind == .path)
        #expect(!f.editing.canUngroup)
    }

    @Test func transformAgainAndAddPoints() async throws {
        let f = await Fixture.make()
        #expect(f.editing.transformAgain() == nil && !f.editing.canTransformAgain)
        f.select([f.selection.a])
        _ = await f.editing.perform(TransformObjects([f.selection.a.opID], matrix: .rotation(radians: 0.1), about: .zero, kind: .rotate)).value
        #expect(f.editing.lastTransform?.kind == .rotate && f.editing.canTransformAgain)
        f.select([f.selection.b])
        _ = await f.editing.transformAgain()?.value
        #expect(f.document.undoTitle == "Undo Rotate")
        #expect(f.editing.addPoints() == nil && !f.editing.hasSelectedPaths)
        let path = try #require(await f.document.addPath([Point(x: 0, y: 200), Point(x: 40, y: 200)]))
        f.select([path])
        #expect(f.editing.hasSelectedPaths)
        _ = await f.editing.addPoints()?.value
        #expect(f.document.path(path)?.pointCount == 3)
    }

    @Test func nudgesMoveObjectsOrPointsAndGroupIntoOneUndoStep() async throws {
        let f = await Fixture.make()
        #expect(!f.editing.nudge(by: Vector(dx: 1, dy: 0)), "nothing selected")
        f.select([f.selection.a])
        let before = f.bounds(f.selection.a)!
        for _ in 0..<10 { #expect(f.editing.nudge(by: Vector(dx: 1, dy: 0))) }
        #expect(f.editing.isNudging)
        await f.document.settle()
        f.editing.endNudging()
        f.editing.endNudging()
        await f.document.settle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(f.bounds(f.selection.a)!.minX - before.minX - 10) < 1e-9)
        _ = await f.document.undo().value
        #expect(f.bounds(f.selection.a) == before, "ten presses are one undo step")
        // With points selected, the points move.
        let path = try #require(await f.document.addPath([Point(x: 0, y: 200), Point(x: 40, y: 200)]))
        let contour = f.document.path(path)!.contours[0]
        let point = PointReference(node: path.node, contour: contour.id, point: contour.points[1].id)
        f.editing.selection.model.set(Selection([path]).applying([path], sub: [path: .points([point])], mode: .add))
        let command = try #require(f.editing.nudgeCommand(Vector(dx: 0, dy: 5)))
        #expect(command.label == "Move Point")
        #expect(ObjectEditing.nudgeDelta(keyCode: 123, distance: 2) == Vector(dx: -2, dy: 0))
        #expect(ObjectEditing.nudgeDelta(keyCode: 124, distance: 2) == Vector(dx: 2, dy: 0))
        #expect(ObjectEditing.nudgeDelta(keyCode: 125, distance: 2) == Vector(dx: 0, dy: 2))
        #expect(ObjectEditing.nudgeDelta(keyCode: 126, distance: 2) == Vector(dx: 0, dy: -2))
        #expect(ObjectEditing.nudgeDelta(keyCode: 0, distance: 2) == nil)
    }

    @Test func aNudgeBurstEndsAfterThePause() async throws {
        let f = await Fixture.make()
        f.editing.nudgePause = .milliseconds(10)
        f.select([f.selection.a])
        f.editing.nudge(by: Vector(dx: 1, dy: 0))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!f.editing.isNudging)
    }

    @Test func theToolManagerNudgesWithTheArrowKeyDistances() async throws {
        let f = await Fixture.make()
        let host = RecordingHost()
        var context = ToolContext(document: f.document, host: host, selection: f.editing.selection)
        context.objectEditing = f.editing
        context.drawing = { DrawingSettings(arrowDistance: 2, shiftArrowDistance: 20) }
        let manager = ToolManager(registry: ToolRegistry(), context: context, initialTool: .pointer) { _ in false }
        f.select([f.selection.a])
        let before = f.bounds(f.selection.a)!
        #expect(manager.nudge(keyCode: 124, modifiers: []))
        #expect(manager.nudge(keyCode: 125, modifiers: .shift))
        #expect(!manager.nudge(keyCode: 124, modifiers: .command), "Command+arrow is a shortcut")
        #expect(!manager.nudge(keyCode: 12, modifiers: []))
        #expect(manager.keyDown(TestEvents.key("\u{F703}", keyCode: 124)))
        await f.document.settle()
        let after = f.bounds(f.selection.a)!
        #expect(abs(after.minX - before.minX - 4) < 1e-9 && abs(after.minY - before.minY - 20) < 1e-9)
        var bare = ToolContext(document: f.document, host: host)
        bare.drawing = { DrawingSettings() }
        #expect(!ToolManager(registry: ToolRegistry(), context: bare, initialTool: .pointer) { _ in false }.nudge(keyCode: 124, modifiers: []))
    }

    @Test func theMenuCommandsValidateAndRun() async throws {
        let f = await Fixture.make()
        let target = EditingBox(f.editing)
        let commands = ObjectMenuCommands.commands { target.value }
        func command(_ id: CommandID) -> WireTuner.Command { commands.first { $0.id == id }! }
        let ids = ContextMenuCatalog.ID.self
        #expect(command(ids.group).validation() == .disabled(ObjectMenuCommands.noSelection))
        f.select([f.selection.a, f.selection.b])
        for id in [ids.duplicate, ids.clone, ids.group, ids.lock, ids.bringToFront, ids.bringForward, ids.sendBackward, ids.sendToBack] {
            #expect(command(id).validation().isEnabled, "\(id)")
        }
        #expect(!command(ids.unlock).validation().isEnabled)
        #expect(command(ids.ungroup).validation().isEnabled)
        #expect(!command(ObjectMenuCommands.ID.pasteInFront).validation().isEnabled)
        #expect(!command(ObjectMenuCommands.ID.transformAgain).validation().isEnabled)
        #expect(!command(ObjectMenuCommands.ID.addPoints).validation().isEnabled)
        if case let .perform(action) = command(ids.lock).action { action() }
        await f.document.settle()
        #expect(f.document.undoTitle == "Undo Lock 2 objects")
        for id in [ids.unlock, ids.bringToFront, ids.bringForward, ids.sendBackward, ids.sendToBack, ids.clone, ids.duplicate, ids.group, ids.ungroup,
                   ObjectMenuCommands.ID.pasteInFront, ids.pasteBehind, ObjectMenuCommands.ID.transformAgain, ObjectMenuCommands.ID.addPoints] {
            if case let .perform(action) = command(id).action { action() }
            await f.document.settle()
        }
        target.value = nil
        #expect(command(ids.group).validation() == .disabled("No document is open"))
        if case let .perform(action) = command(ids.group).action { action() }
        let registry = CommandRegistry()
        ObjectMenuCommands.install(into: registry) { nil }
        #expect(registry.contains(ids.group))
    }

    @Test func theSystemPasteboardHoldsThePayload() {
        let pasteboard = Self.pasteboard()
        #expect(pasteboard.read() == nil)
        pasteboard.write([1, 2, 3])
        #expect(pasteboard.read() == [1, 2, 3])
        #expect(pasteboard.pasteboard.types?.contains(SystemObjectPasteboard.type) == true)
    }
}
