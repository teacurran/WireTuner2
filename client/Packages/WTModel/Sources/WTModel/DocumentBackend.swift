import Foundation
import WTCRDT
import WTProto

/// What a backend call changed, for the `Document` façade to publish.
public struct DocumentUpdate: Sendable, Hashable {
    /// The change applied (local, undo, redo or remote); nil when nothing was applied.
    public var change: Wiretuner_Doc_V1_Change?
    /// The undo and redo menu state afterwards.
    public var undo: UndoSummary
    /// The replica the document writes as afterwards.
    public var replica: UInt64

    public init(change: Wiretuner_Doc_V1_Change?, undo: UndoSummary, replica: UInt64) {
        self.change = change
        self.undo = undo
        self.replica = replica
    }
}

/// The Edit menu's view of the undo stack.
public struct UndoSummary: Sendable, Hashable {
    public var undoTitle: String
    public var redoTitle: String
    public var canUndo: Bool
    public var canRedo: Bool
    public var undoCount: Int
    public var redoCount: Int

    public init(_ stack: UndoStack) {
        undoTitle = stack.undoTitle
        redoTitle = stack.redoTitle
        canUndo = stack.canUndo
        canRedo = stack.canRedo
        undoCount = stack.undo.count
        redoCount = stack.redo.count
    }
}

/// Where a document's merge state lives and how its changes are kept (docs/spec/client.adoc,
/// "Concurrency"): an actor serialising every change on its own executor, so the `Document` façade
/// on the main actor never touches the merge state directly.  `WTSync.LocalStore` is the
/// persistent backend (a local change is applied and appended to the outbox in one transaction,
/// docs/spec/offline.adoc); `MemoryBackend` keeps everything in memory.
public protocol DocumentBackend: Actor {
    /// The current menu state and replica, for a façade opening over the backend.
    func summary() -> DocumentUpdate
    /// Performs a local command (`DocumentCore.perform`); `change` is nil when it appended no ops.
    func perform(_ command: any Command, recording: DocumentCore.Recording) throws -> DocumentUpdate
    /// Undoes the top undo step (`DocumentCore.undo`).
    func undo(recording: DocumentCore.Recording) throws -> DocumentUpdate
    /// Redoes the top redo step (`DocumentCore.redo`).
    func redo(recording: DocumentCore.Recording) throws -> DocumentUpdate
    /// Applies a change from the server's log.
    func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) throws -> DocumentUpdate
    /// Runs `body` over the merged state on the backend's executor.
    func read<T: Sendable>(_ body: @Sendable (EngineState) throws -> T) rethrows -> T
}

/// A backend without persistence: a document not yet stored, previews, tests.
public actor MemoryBackend: DocumentBackend {
    /// The document state.
    public private(set) var core: DocumentCore

    public init(core: DocumentCore) {
        self.core = core
    }

    public init(replica: UInt64, schema: Schema = .generated) {
        core = DocumentCore(state: EngineState(schema: schema), replica: replica)
    }

    public func summary() -> DocumentUpdate {
        DocumentUpdate(change: nil, undo: UndoSummary(core.undoStack), replica: core.replica)
    }

    public func perform(_ command: any Command, recording: DocumentCore.Recording) throws -> DocumentUpdate {
        let outcome = try core.perform(command, recording: recording)
        return update(outcome?.change)
    }

    public func undo(recording: DocumentCore.Recording) -> DocumentUpdate {
        update(core.undo(recording: recording)?.change)
    }

    public func redo(recording: DocumentCore.Recording) -> DocumentUpdate {
        update(core.redo(recording: recording)?.change)
    }

    public func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) -> DocumentUpdate {
        core.receive(change, serverSeq: serverSeq)
        return update(change)
    }

    public func read<T: Sendable>(_ body: @Sendable (EngineState) throws -> T) rethrows -> T {
        try body(core.state)
    }

    private func update(_ change: Wiretuner_Doc_V1_Change?) -> DocumentUpdate {
        DocumentUpdate(change: change, undo: UndoSummary(core.undoStack), replica: core.replica)
    }
}
