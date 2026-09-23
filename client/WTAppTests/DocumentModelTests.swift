import AppKit
import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
import WTRender
import WTSync
@testable import WireTuner

/// The window over `WTModel.Document`: opening, commands, undo and redo, remote changes.
@Suite @MainActor struct DocumentModelTests {
    struct Refused: Error {}

    @Test func commandsIssuedBeforeTheModelOpensWaitForIt() async throws {
        let gate = AsyncGate()
        let document = DocumentHandle(title: "Slow") {
            await gate.wait()
            return DocumentOpener.memoryDocument()
        }
        var opened = 0
        document.observe { _ in opened += 1 }
        #expect(document.model == nil && document.displayList.count == 1, "the pages only")
        #expect(document.undoTitle == "Undo" && document.redoTitle == "Redo" && !document.canUndo && !document.canRedo)
        document.beginGroup()
        document.endGroup()
        let pending = document.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10)))
        await gate.open()
        let change = await pending.value
        #expect(change?.createdObjects.count == 1)
        #expect(document.selectableIDs().count == 1)
        #expect(opened == 1)
    }

    @Test func aModelThatFailsToOpenPerformsNothing() async {
        let document = DocumentHandle(title: "Broken") { throw Refused() }
        await document.settle()
        #expect(document.openError is Refused)
        #expect(await document.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10))).value == nil)
        document.close()
    }

    @Test func aStoredDocumentReopensWithItsObjects() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WireTunerStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let open = DocumentOpener.localStore(undoLevels: { 7 }) { id in directory.appending(components: id, "store.sqlite") }
        let first = DocumentHandle(id: "stored", title: "Stored") { try await open("stored") }
        await first.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(first.model?.undoLevels == 7)
        first.close()
        try await Task.sleep(for: .milliseconds(200))
        let again = DocumentHandle(id: "stored", title: "Stored") { try await open("stored") }
        await again.settle()
        #expect(again.selectableIDs().count == 1, "the local store kept the rectangle")
        again.close()
        await DocumentOpener.close(MemoryBackend(replica: 3))
    }

    @Test func launchesPickTheirOpener() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WireTunerOpener-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = TestDefaults()
        let preferences = PreferenceStore(defaults: suite.defaults)
        preferences.set(12, for: PreferenceCatalog.Sync.undoLevels)
        let app = LaunchEnvironment(arguments: [], environment: [:])
        let open = DocumentOpener.opener(for: app, preferences: preferences) { id in directory.appending(components: id, "store.sqlite") }
        let model = try await open("launch")
        #expect(model.undoLevels == 12, "the app opens local stores with the Undo levels preference")
        await DocumentOpener.close(model.backend)
        let test = LaunchEnvironment(arguments: [LaunchEnvironment.uiTestingArgument], environment: [:])
        let memory = try await DocumentOpener.opener(for: test, preferences: preferences)("t")
        #expect(memory.backend is MemoryBackend, "test launches keep memory documents")
        #expect(try DocumentOpener.defaultLocation("doc").lastPathComponent == "store.sqlite")
        let unopened = DocumentHandle(title: "Unopened") {
            try await Task.sleep(for: .seconds(60))
            throw Refused()
        }
        #expect(!unopened.state.store.isCreated(OpID(counter: 1, replica: 1)), "before the model opens the state is empty")
    }

    @Test func pagesPlaceInRowsAndTheScenesAreReachable() {
        let page = Rect(x: Pasteboard.side - 100, y: 0, width: 100, height: 100)
        let placed = Pasteboard.placement(after: page, among: [])
        #expect(placed.minX == page.minX && placed.minY == page.maxY + Pasteboard.pageGap, "a full row starts a new one below")
        let document = DocumentHandle.memory(title: "Scene")
        #expect(document.scene.displayList == document.displayList)
    }

    @Test func aFailingCommandIsLoggedAndPerformsNothing() async {
        let document = DocumentHandle.memory(title: "Errors")
        let change = await document.perform(SetFlatness(node: OpID(counter: 99, replica: 9), flatness: 1)).value
        #expect(change == nil)
        #expect(document.changeCount == 0)
    }

    @Test func remoteChangesAreDrawnAndBatchedPerFrame() async throws {
        var scheduled: [@MainActor () -> Void] = []
        let batcher = InvalidationBatcher(scheduler: { scheduled.append($0) })
        let document = DocumentHandle(title: "Remote", model: DocumentOpener.memoryDocument(), invalidation: batcher)
        let before = batcher.flushCount
        var other = DocumentCore(state: EngineState(), replica: 0xFACE)
        let outcome = try other.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 5, height: 5)),
                                        recording: DocumentCore.Recording(limit: 10, now: Date()))
        _ = await document.receive(try #require(outcome?.change), serverSeq: 1).value
        #expect(document.selectableIDs().count == 1)
        #expect(batcher.flushCount == before, "remote changes wait for the next frame")
        #expect(scheduled.count == 1)
        scheduled.removeAll()
        _ = await document.perform(CreateShape(.ellipse, size: Size(width: 5, height: 5))).value
        #expect(batcher.flushCount == before + 1, "a local change flushes at once, carrying the burst")
    }

    @Test func undoAndRedoFollowTheFrontDocument() async throws {
        let environment = TestEnvironment()
        StandardCommands.register(into: environment.commands)
        let controller = DocumentWindowController(document: .memory(title: "Undo"), environment: environment.document)
        defer { controller.close() }
        let front = TargetBox()
        front.window = controller
        UndoCommands.install(into: environment.commands) { front.window }
        let registry = environment.commands
        #expect(registry.validate(StandardCommands.ID.undo) == CommandValidation(isEnabled: false, title: "Undo"))
        #expect(registry.validate(StandardCommands.ID.redo) == CommandValidation(isEnabled: false, title: "Redo"))
        await controller.documentHandle.addRectangles([Rect(x: 0, y: 0, width: 10, height: 10)])
        #expect(registry.validate(StandardCommands.ID.undo) == CommandValidation(isEnabled: true, title: "Undo Rectangle"))
        #expect(registry.perform(StandardCommands.ID.undo))
        await controller.documentHandle.settle()
        #expect(controller.documentHandle.selectableIDs().isEmpty)
        #expect(registry.validate(StandardCommands.ID.redo) == CommandValidation(isEnabled: true, title: "Redo Rectangle"))
        #expect(registry.perform(StandardCommands.ID.redo))
        await controller.documentHandle.settle()
        #expect(controller.documentHandle.selectableIDs().count == 1)
        #expect(registry.command(StandardCommands.ID.undo)?.defaultKey == KeyEquivalent("z", .command))
        // While a text field edits, the keys go to the field.
        let field = NSTextField(string: "x")
        controller.window?.contentView?.addSubview(field)
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(field)
        if controller.isEditingText {
            #expect(registry.validate(StandardCommands.ID.undo) == CommandValidation(isEnabled: true, title: "Undo"))
            #expect(registry.validate(StandardCommands.ID.redo) == CommandValidation(isEnabled: true, title: "Redo"))
            UndoCommands.perform(controller, undo: true)
            UndoCommands.perform(controller, undo: false)
            #expect(controller.documentHandle.selectableIDs().count == 1)
        }
        field.removeFromSuperview()
        front.window = nil
        #expect(registry.validate(StandardCommands.ID.undo)?.isEnabled == false)
        UndoCommands.perform(nil, undo: true)
    }

    @Test func theDocumentControllerOpensModelsThroughTheEnvironment() async {
        let environment = TestEnvironment()
        var openedIDs: [String] = []
        var documentEnvironment = environment.document
        documentEnvironment.openModel = { id in
            openedIDs.append(id)
            return DocumentOpener.memoryDocument()
        }
        let controller = DocumentController(environment: documentEnvironment)
        let window = controller.newDocument(show: false)
        await window.documentHandle.settle()
        #expect(openedIDs == [window.documentHandle.id])
        #expect(window.documentHandle.model != nil)
        controller.close(window.documentHandle.id)
        #expect(controller.documents.isEmpty)
    }
}

/// A one-shot gate a test opens to let a suspended task continue.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
