import AppKit
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The Select menu commands (OBJ-006), cycling through stacked objects and hiding on this Mac
/// (OBJ-007).
@Suite(.serialized) @MainActor struct SelectMenuTests {
    private func window(_ environment: TestEnvironment = TestEnvironment()) async -> (DocumentWindowController, SelectionFixture) {
        let fixture = await SelectionFixture.make()
        return (DocumentWindowController(document: fixture.document, environment: environment.document), fixture)
    }

    // MARK: OBJ-006

    @Test func allSkipsLockedObjectsAndAllInDocumentTakesThePasteboard() async {
        let (controller, fixture) = await window()
        defer { controller.close() }
        let document = controller.documentHandle
        let far = await document.addRectangles([Rect(x: 2000, y: 2000, width: 10, height: 10)])[0]
        _ = await document.perform(SetLocked([fixture.b.opID], locked: true)).value
        #expect(controller.validate(selector: #selector(DocumentWindowController.selectAll(_:))))
        controller.selectAll(nil)
        #expect(controller.selection.model.ids == [fixture.a, fixture.group, fixture.square], "locked and off-page objects are not All")
        #expect(controller.validate(selector: #selector(DocumentWindowController.selectAllInDocument(_:))))
        controller.selectAllInDocument(nil)
        #expect(controller.selection.model.ids == [fixture.a, fixture.group, fixture.square, far])
    }

    @Test func superselectClimbsAndSubselectAllDescends() async {
        let (controller, fixture) = await window()
        defer { controller.close() }
        #expect(!controller.validate(selector: #selector(DocumentWindowController.superselect(_:))), "nothing selected")
        controller.selection.model.set(Selection([fixture.member]))
        #expect(controller.validate(selector: #selector(DocumentWindowController.superselect(_:))))
        controller.superselect(nil)
        #expect(controller.selection.model.ids == [fixture.group])
        #expect(!controller.validate(selector: #selector(DocumentWindowController.superselect(_:))), "disabled at the top")
        controller.superselect(nil)
        #expect(controller.selection.model.ids == [fixture.group])
        #expect(controller.validate(selector: #selector(DocumentWindowController.subselectAll(_:))))
        controller.subselectAll(nil)
        #expect(controller.selection.model.ids == [fixture.member, fixture.otherMember])
        #expect(!controller.validate(selector: #selector(DocumentWindowController.subselectAll(_:))), "members have no members")
        controller.subselectAll(nil)
        #expect(controller.selection.model.ids == [fixture.member, fixture.otherMember])
    }

    @Test func superselectMovesTheTransformHandlesWhenShown() async {
        let environment = TestEnvironment()
        SelectionCommands.install(commands: environment.commands, tools: environment.tools)
        let (controller, fixture) = await window(environment)
        defer { controller.close() }
        controller.selection.model.set(Selection([fixture.member]))
        let pointer = try? #require(controller.toolManager.activeTool as? PointerTool)
        pointer?.showHandles()
        controller.superselect(nil)
        #expect(controller.selection.model.ids == [fixture.group])
        #expect(pointer?.handlesShown == true)
    }

    @Test func textEditingDisablesTheNewSelectCommands() async throws {
        let environment = TestEnvironment()
        let (controller, _) = await window(environment)
        defer { controller.close() }
        controller.selectAll(nil)
        let field = NSTextField(string: "x")
        controller.window?.contentView?.addSubview(field)
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(field)
        if controller.isEditingText {
            #expect(!controller.validate(selector: #selector(DocumentWindowController.selectAllInDocument(_:))))
            #expect(!controller.validate(selector: #selector(DocumentWindowController.superselect(_:))))
            #expect(!controller.validate(selector: #selector(DocumentWindowController.subselectAll(_:))))
        }
        field.removeFromSuperview()
    }

    @Test func clearIsOneChangeNamedByItsCount() async {
        let (controller, fixture) = await window()
        defer { controller.close() }
        controller.selection.model.set(Selection([fixture.a, fixture.b, fixture.square]))
        #expect(controller.deletionCommand()?.label == "Delete 3 objects")
        controller.delete(nil)
        await controller.documentHandle.settle()
        #expect(controller.documentHandle.undoTitle == "Undo Delete 3 objects")
    }

    @Test func theSelectMenuListsTheCommandsWithTheirKeys() {
        let commands = CommandRegistry()
        let tools = ToolRegistry()
        StandardCommands.register(into: commands)
        tools.registerBuiltIn()
        SelectionCommands.install(commands: commands, tools: tools)
        #expect(commands.command(SelectionCommands.ID.selectAllInDocument)?.defaultKey == KeyEquivalent("a", [.command, .shift]))
        #expect(commands.command(SelectionCommands.ID.superselect)?.defaultKey == KeyEquivalent("~"))
        #expect(commands.command(SelectionCommands.ID.subselectAll)?.title == "Subselect All")
        #expect(commands.command(SelectionCommands.ID.subselectAll)?.action.responderSelectorName == "subselectAll:")
    }

    // MARK: OBJ-007 cycling

    /// Five filled squares stacked at (100, 100), bottom first, and a pointer over them.
    @MainActor
    final class Stack {
        let document = DocumentHandle.memory(title: "Stack")
        let host = RecordingHost(viewport: SelectionFixture.viewport)
        let controller: SelectionController
        let tool: PointerTool
        var squares: [SelectionID] = []

        init(subselect: Bool = false) {
            document.pages = [Rect(x: 0, y: 0, width: 400, height: 300)]
            controller = SelectionController(document: document)
            tool = PointerTool(subselect: subselect)
            tool.activate(in: ToolContext(document: document, host: host, selection: controller))
        }

        func build() async {
            squares = await document.addRectangles((0..<5).map { Rect(x: 100 - Double($0), y: 100, width: 50, height: 50) })
        }

        func cycleClick(_ x: Double = 120, _ y: Double = 120) {
            tool.mouseDown(TestEvents.point(x, y, [.control, .option]))
            tool.mouseUp(TestEvents.point(x, y, [.control, .option]))
        }
    }

    @Test func cyclingVisitsEachStackedObjectInZOrderAndWraps() async {
        let stack = Stack()
        await stack.build()
        var visited: [SelectionID] = []
        for _ in 0..<6 {
            stack.cycleClick()
            visited.append(contentsOf: stack.controller.selection.ids)
        }
        #expect(visited == Array(stack.squares.reversed()) + [stack.squares.last!], "top first, then down, then wraps")
        #expect(stack.tool.info.objectKind == "Rectangle, 1 of 5", "the Info toolbar names the object cycled to")
        #expect(stack.tool.cycle?.stack.count == 5)
        // Moving away past the pick distance starts a new stack.
        stack.tool.pointerMoved(TestEvents.point(300, 250))
        #expect(stack.tool.cycle == nil && stack.tool.info.objectKind == nil)
        stack.cycleClick(300, 250)
        #expect(stack.controller.selection.isEmpty, "nothing under the pointer")
        stack.cycleClick()
        stack.tool.pointerMoved(TestEvents.point(121, 121))
        #expect(stack.tool.cycle != nil, "a small move keeps the stack")
        // A plain click ends the cycle.
        stack.tool.mouseDown(TestEvents.point(120, 120))
        stack.tool.mouseUp(TestEvents.point(120, 120))
        #expect(stack.tool.cycle == nil)
    }

    @Test func cyclingInsideAGroupWithSubselect() async {
        let fixture = await SelectionFixture.make()
        let controller = SelectionController(document: fixture.document)
        let tool = PointerTool(subselect: true)
        let host = RecordingHost(viewport: SelectionFixture.viewport)
        tool.activate(in: ToolContext(document: fixture.document, host: host, selection: controller))
        tool.mouseDown(TestEvents.point(210, 20, [.control, .option]))
        #expect(controller.selection.ids == [fixture.member], "the Subselect tool cycles members")
        #expect(controller.stack(at: Point(x: 210, y: 20), viewport: SelectionFixture.viewport, subselect: false) == [fixture.group])
        withExtendedLifetime(host) {}
    }

    @Test func controlOptionClickReachesThePointerInsteadOfTheContextMenu() async {
        let environment = TestEnvironment()
        SelectionCommands.install(commands: environment.commands, tools: environment.tools)
        let (controller, _) = await window(environment)
        defer { controller.close() }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [.control, .option], timestamp: 0,
                                       windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(controller.canvas.cyclesSelection(event))
        let plain = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [.control], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        #expect(!controller.canvas.cyclesSelection(plain))
        controller.toolManager.select(.hand)
        #expect(!controller.canvas.cyclesSelection(event))
    }

    // MARK: OBJ-007 hiding

    /// A `LocalHiding` storage in memory.
    @MainActor
    final class MemoryStore {
        var data: Data?
        var saves = 0

        var storage: LocalHiding.Storage {
            LocalHiding.Storage(load: { self.data }, save: {
                self.data = $0
                self.saves += 1
            })
        }
    }

    @Test func hiddenObjectsAreNotDrawnHitOrSelectedUntilShowAll() async throws {
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        let fixture = await SelectionFixture.make()
        let store = MemoryStore()
        fixture.document.hiding = LocalHiding(document: fixture.document, storage: store.storage)
        let controller = DocumentWindowController(document: fixture.document, environment: environment.document)
        defer { controller.close() }
        VisibilityCommands.install(into: environment.commands) { nil }
        #expect(environment.commands.validate(StandardCommands.ID.hideSelection) == .disabled(ViewCommands.noDocument))
        #expect(environment.commands.validate(StandardCommands.ID.showAllObjects) == .disabled(ViewCommands.noDocument))
        for id in [StandardCommands.ID.hideSelection, StandardCommands.ID.showAllObjects] {
            if case .perform(let run)? = environment.commands.command(id)?.action { run() }
        }
        VisibilityCommands.install(into: environment.commands) { controller }
        #expect(environment.commands.validate(StandardCommands.ID.hideSelection) == .disabled(ViewCommands.nothingSelected))
        #expect(environment.commands.validate(StandardCommands.ID.showAllObjects) == .disabled(VisibilityCommands.nothingHidden))
        controller.selection.model.set(Selection([fixture.a, fixture.member]))
        #expect(environment.commands.perform(StandardCommands.ID.hideSelection))
        await fixture.document.hiding.settle()
        #expect(controller.selection.model.isEmpty, "hidden objects leave the selection")
        #expect(fixture.document.item(for: fixture.a) == nil && fixture.document.item(for: fixture.member) == nil)
        #expect(controller.selection.pick(at: Point(x: 30, y: 30), viewport: SelectionFixture.viewport, subselect: false) == nil)
        controller.selectAll(nil)
        #expect(controller.selection.model.ids == [fixture.b, fixture.group, fixture.square])
        #expect(LocalHiding.decode(try #require(store.data)) == [fixture.a.opID, fixture.member.opID])
        #expect(environment.commands.validate(StandardCommands.ID.showAllObjects) == .enabled)
        #expect(environment.commands.perform(StandardCommands.ID.showAllObjects))
        await fixture.document.hiding.settle()
        #expect(fixture.document.item(for: fixture.a) != nil)
        #expect(LocalHiding.decode(try #require(store.data)) == [])
        fixture.document.hiding.showAll()
        await fixture.document.hiding.settle()
        #expect(store.saves == 2, "Show All with nothing hidden writes nothing")
    }

    @Test func hiddenObjectsStayHiddenOnReopenAndDeletedOnesLeaveTheSet() async throws {
        let fixture = await SelectionFixture.make()
        let store = MemoryStore()
        store.data = LocalHiding.encode([fixture.a.opID, fixture.b.opID, OpID(counter: 999, replica: 9)])
        let hiding = LocalHiding(document: fixture.document, storage: store.storage)
        await hiding.settle()
        #expect(hiding.hidden == [fixture.a.opID, fixture.b.opID], "a node that no longer exists is dropped on restore")
        #expect(LocalHiding.decode(try #require(store.data)) == [fixture.a.opID, fixture.b.opID])
        #expect(fixture.document.item(for: fixture.a) == nil)
        // Deleted remotely: out of the set.
        await fixture.document.receiveRemote(SetLocked([fixture.square.opID], locked: true))
        #expect(hiding.hidden == [fixture.a.opID, fixture.b.opID], "an unrelated change keeps the set")
        await fixture.document.receiveRemote(DeleteNodes([fixture.a.opID]))
        await hiding.settle()
        #expect(hiding.hidden == [fixture.b.opID])
        hiding.hide([fixture.b.opID])
        #expect(hiding.hidden == [fixture.b.opID], "hiding what is hidden changes nothing")
        #expect(LocalHiding.decode(try #require(store.data)) == [fixture.b.opID])
        hiding.hide([])
        #expect(LocalHiding.decode(Data("nonsense".utf8)) == nil)
        #expect(LocalHiding.decode(Data("[[1]]".utf8)) == [])
        // Without stored data nothing is hidden.
        let empty = LocalHiding(document: DocumentHandle.memory(title: "Empty"), storage: MemoryStore().storage)
        await empty.settle()
        #expect(empty.hidden.isEmpty && !empty.canShowAll)
    }

    @Test func theHiddenSetLivesInTheLocalStoreViewTable() async throws {
        let directory = TestEnvironment.temporaryDirectory()
        let id = UUID().uuidString
        let url = directory.appending(path: "store.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await LocalStore.open(documentID: id, at: url)
        let model = await WTModel.Document(backend: store, undoLevels: 10)
        let document = DocumentHandle(id: id, title: "Stored", model: model)
        let hiding = LocalHiding(document: document)
        await hiding.settle()
        let node = OpID(counter: 5, replica: 5)
        hiding.hide([node])
        await hiding.settle()
        #expect(LocalHiding.decode(try #require(try await store.viewValue(forKey: LocalHiding.viewKey))) == [node])
        try await store.close()
        let memory = LocalHiding.localStore(of: DocumentHandle.memory(title: "No store"))
        #expect(await memory.load() == nil)
        await memory.save(Data())
    }
}
