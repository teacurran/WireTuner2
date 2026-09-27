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
/// "Concurrency"; D-076).  The state itself is the backend's `engine`, which the `Document` façade
/// applies local commands to synchronously on the main actor; the actor persists what they wrote
/// off the main actor and serialises everything else (remote changes, acknowledgements, snapshots).
/// `WTSync.LocalStore` is the persistent backend (the local changes applied since its last write
/// are written together in one transaction, at most every 250 ms, docs/spec/offline.adoc);
/// `MemoryBackend` keeps everything in memory.
public protocol DocumentBackend: Actor {
    /// The merge state, shared with the façade.
    nonisolated var engine: DocumentEngine { get }
    /// The current menu state and replica, for a façade opening over the backend.
    func summary() -> DocumentUpdate
    /// Performs a local command (`DocumentCore.perform`) and writes it before returning;
    /// `change` is nil when it appended no ops.  The façade uses `engine.perform`, which does not
    /// wait for the write.
    func perform(_ command: any Command, recording: DocumentCore.Recording) throws -> DocumentUpdate
    /// Undoes the top undo step (`DocumentCore.undo`), written before returning.
    func undo(recording: DocumentCore.Recording) throws -> DocumentUpdate
    /// Redoes the top redo step (`DocumentCore.redo`), written before returning.
    func redo(recording: DocumentCore.Recording) throws -> DocumentUpdate
    /// Applies a change from the server's log.
    func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) throws -> DocumentUpdate
    /// Runs `body` over the merged state.
    func read<T: Sendable>(_ body: @Sendable (EngineState) throws -> T) rethrows -> T
    /// Writes every local change the engine has applied and not yet written.
    func flush() async throws
}

/// A backend without persistence: a document not yet stored, previews, tests.
public actor MemoryBackend: DocumentBackend {
    public nonisolated let engine: DocumentEngine

    /// The document state.
    public var core: DocumentCore { engine.core }

    public init(core: DocumentCore) {
        engine = DocumentEngine(core: core, persists: false)
    }

    public init(replica: UInt64, schema: Schema = .generated) {
        engine = DocumentEngine(core: DocumentCore(state: EngineState(schema: schema), replica: replica), persists: false)
    }

    public func summary() -> DocumentUpdate {
        engine.summary
    }

    public func perform(_ command: any Command, recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try engine.perform(command, recording: recording)
    }

    public func undo(recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try engine.undo(recording: recording)
    }

    public func redo(recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try engine.redo(recording: recording)
    }

    public func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) -> DocumentUpdate {
        engine.update { core in
            core.receive(change, serverSeq: serverSeq)
            return DocumentUpdate(change: change, undo: UndoSummary(core.undoStack), replica: core.replica)
        }
    }

    public func read<T: Sendable>(_ body: @Sendable (EngineState) throws -> T) rethrows -> T {
        try body(engine.state)
    }

    public func flush() {}

    /// Replaces the whole core (a memory document's snapshot bootstrap or salvage); the façade
    /// catches up with `Document.reload()`.
    public func replace(with core: DocumentCore) {
        engine.replace(with: core)
    }
}
