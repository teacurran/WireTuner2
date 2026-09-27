import Foundation
import Synchronization
import WTCRDT
import WTProto

/// The one copy of an open document's merge state (`DocumentCore`), shared by the `Document`
/// façade on the main actor and the backend actor that persists it (D-076, "The UI never waits on
/// persistence").  A local command is applied here synchronously, on the caller's thread -- the
/// main actor -- and is on screen in the same frame; what it wrote waits in `pending` until the
/// backend writes it (`WTSync.LocalStore` batches the writes, at most every 250 ms).  Every access
/// takes the lock, briefly: remote changes, acknowledgements, snapshots and salvage mutate the same
/// core from the backend's executor, so there is never a second copy to keep in step.
///
/// A backend that keeps nothing (`MemoryBackend`) makes an engine with `persists` false: nothing
/// is queued.
public final class DocumentEngine: Sendable {
    /// Whether local changes are refused (COLLAB-014), and whether a commenter's changes to
    /// comments alone are still accepted (COLLAB-034).
    public struct Gate: Sendable, Hashable {
        public var readOnly = false
        public var commentsAllowed = false

        public init(readOnly: Bool = false, commentsAllowed: Bool = false) {
            self.readOnly = readOnly
            self.commentsAllowed = readOnly && commentsAllowed
        }
    }

    /// Why a local change was refused.
    public enum Refusal: Error, Equatable {
        /// The gate is read-only (and the change is not about comments alone, for a commenter).
        case readOnly
    }

    private struct Box: Sendable {
        var core: DocumentCore
        var pending: [DocumentCore.Outcome] = []
        var gate = Gate()
        /// Set once the backend could not write what was applied: local changes are refused.
        var failure: (any Error)?
        /// When the last local change was applied (the typing pause that seals an open change).
        var lastLocal: ContinuousClock.Instant?
        var notify: (@Sendable () -> Void)?
    }

    private let box: Mutex<Box>
    /// Whether applied local changes wait in `pending` for the backend to write them.
    public let persists: Bool
    /// What a refused local change throws (the backend's own read-only error).
    private let refusal: any Error

    public init(core: DocumentCore, persists: Bool, refusal: any Error = Refusal.readOnly) {
        box = Mutex(Box(core: core))
        self.persists = persists
        self.refusal = refusal
    }

    // MARK: Reading

    /// A copy of the core (the state, replica, seqs and undo stack) as of now.
    public var core: DocumentCore { box.withLock { $0.core } }

    /// A copy of the merged state as of now.
    public var state: EngineState { box.withLock { $0.core.state } }

    /// The menu state and replica as of now.
    public var summary: DocumentUpdate {
        box.withLock { DocumentUpdate(change: nil, undo: UndoSummary($0.core.undoStack), replica: $0.core.replica) }
    }

    /// The refusal gate.
    public var gate: Gate {
        get { box.withLock { $0.gate } }
    }

    public func setGate(_ gate: Gate) {
        box.withLock { $0.gate = gate }
    }

    /// Whether applied local changes wait to be written.
    public var hasPending: Bool { box.withLock { !$0.pending.isEmpty } }

    /// When the last local change was applied, nil before any.
    public var lastLocalChange: ContinuousClock.Instant? { box.withLock { $0.lastLocal } }

    // MARK: Local changes

    /// Performs a local command now (`DocumentCore.perform`): applied, recorded on the undo stack
    /// and, for a persistent engine, queued for the backend.  Throws what the command throws, the
    /// gate's refusal, or the backend's failure, before anything changed.
    public func perform(_ command: any Command, recording: DocumentCore.Recording) throws -> DocumentUpdate {
        let (update, notify) = try box.withLock { box -> (DocumentUpdate, (@Sendable () -> Void)?) in
            if let failure = box.failure { throw failure }
            if box.gate.readOnly {
                guard box.gate.commentsAllowed else { throw refusal }
                var builder = ChangeBuilder(replica: box.core.replica, startCounter: box.core.state.clock.peek)
                try command.execute(&builder, state: box.core.state)
                guard CommentFields.onlyComments(builder.ops, in: box.core.state) else { throw refusal }
            }
            let outcome = try box.core.perform(command, recording: recording)
            return Self.queue(outcome, in: &box, persists: persists)
        }
        notify?()
        return update
    }

    /// Undoes the top undo step now (`DocumentCore.undo`), as `perform`.
    public func undo(recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try reverse { $0.undo(recording: recording) }
    }

    /// Redoes the top redo step now (`DocumentCore.redo`), as `perform`.
    public func redo(recording: DocumentCore.Recording) throws -> DocumentUpdate {
        try reverse { $0.redo(recording: recording) }
    }

    private func reverse(_ body: @Sendable (inout DocumentCore) -> DocumentCore.Outcome?) throws -> DocumentUpdate {
        let (update, notify) = try box.withLock { box -> (DocumentUpdate, (@Sendable () -> Void)?) in
            if let failure = box.failure { throw failure }
            if box.gate.readOnly {
                var trial = box.core
                guard box.gate.commentsAllowed, let ops = body(&trial)?.change?.ops, CommentFields.onlyComments(ops, in: box.core.state) else {
                    throw refusal
                }
            }
            let outcome = body(&box.core)
            return Self.queue(outcome, in: &box, persists: persists)
        }
        notify?()
        return update
    }

    // Queues `outcome` for the backend (a persistent engine), and answers the update and, when the
    // queue was empty, the backend's hook to call once the lock is released.
    private static func queue(_ outcome: DocumentCore.Outcome?, in box: inout Box, persists: Bool)
        -> (DocumentUpdate, (@Sendable () -> Void)?) {
        let update = DocumentUpdate(change: outcome?.change, undo: UndoSummary(box.core.undoStack), replica: box.core.replica)
        guard let outcome else { return (update, nil) }
        box.lastLocal = .now
        guard persists, outcome.outbox != nil || outcome.edit != nil else { return (update, nil) }
        let wasEmpty = box.pending.isEmpty
        box.pending.append(outcome)
        return (update, wasEmpty ? box.notify : nil)
    }

    // MARK: The backend's side

    /// Calls `hook` (off the lock) whenever a local change is queued on an empty queue: the
    /// backend schedules its next write.
    public func onPending(_ hook: (@Sendable () -> Void)?) {
        box.withLock { $0.notify = hook }
    }

    /// Takes every queued local outcome, in the order applied.
    public func takePending() -> [DocumentCore.Outcome] {
        box.withLock { box in
            let pending = box.pending
            box.pending = []
            return pending
        }
    }

    /// Runs `body` over the core under the lock, handing it the outcomes queued before it, which
    /// leave the queue in the same step: a backend writes them ahead of whatever `body` changed,
    /// so the file keeps the order the state saw.  When `body` throws the queue is left as it was.
    public func mutate<T: Sendable>(_ body: (inout DocumentCore, [DocumentCore.Outcome]) throws -> T) rethrows -> (pending: [DocumentCore.Outcome], result: T) {
        try box.withLock { box in
            let result = try body(&box.core, box.pending)
            let pending = box.pending
            box.pending = []
            return (pending, result)
        }
    }

    /// Runs `body` over the core under the lock, leaving the queue as it is (sealing the open
    /// change, recording a horizon).
    public func update<T: Sendable>(_ body: (inout DocumentCore) throws -> T) rethrows -> T {
        try box.withLock { try body(&$0.core) }
    }

    /// Replaces the core wholesale (a memory document's snapshot bootstrap or salvage).
    public func replace(with core: DocumentCore) {
        box.withLock {
            $0.core = core
            $0.pending = []
        }
    }

    /// Records that the backend could not write what was applied: every later local change throws
    /// `failure` until the document is opened again.
    public func fail(_ failure: any Error) {
        box.withLock { $0.failure = failure }
    }

    /// The backend's failure, if any.
    public var failure: (any Error)? { box.withLock { $0.failure } }
}
