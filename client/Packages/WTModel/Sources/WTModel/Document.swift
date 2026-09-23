import Foundation
import Observation
import WTCRDT
import WTProto

/// The typed document on the main actor (docs/spec/client.adoc, "Concurrency"): an observable
/// façade over the backend actor that holds the merge state.  UI code performs commands, undoes
/// and redoes through it and observes `revision` and the menu titles; it never touches the engine.
///
/// Undo (APP-011, docs/_includes/objects/undo.adoc): every performed command is one undo step,
/// except that commands performed between `beginGroup` and `endGroup` (a drag) join one step and
/// consecutive typing joins one step per word or until a one-second pause.  Undo emits a change
/// that skips whatever someone else has changed since; the stack is persisted by the backend and
/// capped by *Undo levels*, read when the document opens.
@MainActor @Observable
public final class Document {
    /// The *Undo levels* preference range and default (docs/_includes/objects/undo.adoc).
    public static let undoLevelsRange = 1...1_000
    public static let defaultUndoLevels = 100

    /// The backend holding the merge state.
    @ObservationIgnored public let backend: any DocumentBackend
    /// The *Undo levels* this document was opened with.
    public let undoLevels: Int
    /// The Edit menu's undo item title: "Undo Move 3 Objects", or "Undo" when there is nothing.
    public private(set) var undoTitle: String
    /// The Edit menu's redo item title.
    public private(set) var redoTitle: String
    /// Whether Undo is enabled.
    public private(set) var canUndo: Bool
    /// Whether Redo is enabled.
    public private(set) var canRedo: Bool
    /// The replica this document writes as.
    public private(set) var replica: UInt64
    /// Counts every change applied through the façade, local or remote; views observe it.
    public private(set) var revision = 0
    /// The last change applied through the façade.
    public private(set) var lastChange: Wiretuner_Doc_V1_Change?
    /// The merged state as of the last change the façade applied: a copy the main actor reads
    /// synchronously (display list building, panels, tools); the backend's own copy stays
    /// authoritative (docs/spec/client.adoc, "Concurrency", as built by DRAW-002).
    @ObservationIgnored public private(set) var state: EngineState

    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var groupDepth = 0
    @ObservationIgnored private var group: UInt64?
    @ObservationIgnored private var nextGroup: UInt64 = 1
    @ObservationIgnored private var observers: [UInt64: @MainActor (DocumentEvent) -> Void] = [:]
    @ObservationIgnored private var nextObserver: UInt64 = 1
    /// The last queued backend call: calls run one at a time in the order they were made, so the
    /// published state and events follow the backend's order.
    @ObservationIgnored private var tail: Task<Void, Never>?

    /// A façade over `backend`.  `undoLevels` is clamped to 1...1,000; `clock` dates changes and
    /// measures the typing pause.
    public init(backend: any DocumentBackend, undoLevels: Int = Document.defaultUndoLevels,
                clock: @escaping @Sendable () -> Date = Date.init) async {
        self.backend = backend
        self.undoLevels = min(max(undoLevels, Self.undoLevelsRange.lowerBound), Self.undoLevelsRange.upperBound)
        self.clock = clock
        let summary = await backend.summary()
        undoTitle = summary.undo.undoTitle
        redoTitle = summary.undo.redoTitle
        canUndo = summary.undo.canUndo
        canRedo = summary.undo.canRedo
        replica = summary.replica
        state = await backend.read { $0 }
    }

    /// A façade over a `MemoryBackend` holding `core`, ready at once (no suspension): a document
    /// not stored yet, previews and tests.
    public init(memory core: DocumentCore, undoLevels: Int = Document.defaultUndoLevels,
                clock: @escaping @Sendable () -> Date = Date.init) {
        backend = MemoryBackend(core: core)
        self.undoLevels = min(max(undoLevels, Self.undoLevelsRange.lowerBound), Self.undoLevelsRange.upperBound)
        self.clock = clock
        let summary = UndoSummary(core.undoStack)
        undoTitle = summary.undoTitle
        redoTitle = summary.redoTitle
        canUndo = summary.canUndo
        canRedo = summary.canRedo
        replica = core.replica
        state = core.state
    }

    // MARK: Observing

    /// A token `stopObserving` takes.
    public struct ObservationToken: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    /// Calls `handler` on the main actor after every change the façade applies (local, undo, redo
    /// or remote), with the state before and after.
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (DocumentEvent) -> Void) -> ObservationToken {
        let id = nextObserver
        nextObserver += 1
        observers[id] = handler
        return ObservationToken(id: id)
    }

    public func stopObserving(_ token: ObservationToken) {
        observers[token.id] = nil
    }

    /// Waits until every backend call made so far has finished and been published.
    public func settle() async {
        await tail?.value
    }

    /// Runs `body` after every earlier queued call.
    private func serially<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Performs `command` as one change (or part of the open group's undo step) and returns the
    /// change, or nil when the command appended no ops.
    @discardableResult
    public func perform(_ command: any Command) async throws -> Wiretuner_Doc_V1_Change? {
        let recording = recording()
        return try await serially { [backend] in
            try await self.publish(backend.perform(command, recording: recording), origin: .local)
        }
    }

    /// Undoes this user's last step.  Returns the emitted change, or nil when nothing was left to
    /// undo (the step still moves to the redo list) or the list was empty.
    @discardableResult
    public func undo() async throws -> Wiretuner_Doc_V1_Change? {
        let recording = recording()
        return try await serially { [backend] in
            try await self.publish(backend.undo(recording: recording), origin: .undo)
        }
    }

    /// Redoes the last undone step; as `undo`.
    @discardableResult
    public func redo() async throws -> Wiretuner_Doc_V1_Change? {
        let recording = recording()
        return try await serially { [backend] in
            try await self.publish(backend.redo(recording: recording), origin: .redo)
        }
    }

    /// Re-reads the backend after its state was replaced wholesale (a snapshot bootstrap or a
    /// salvage: WTSync's `SyncEvent.stateReplaced`): the replica, the Edit menu state and the merged
    /// state, then publishes one `.reload` event -- an empty change, the whole state before and
    /// after -- so every observer rebuilds from scratch (`DocumentDisplayListBuilder.reload`) and
    /// drops what no longer resolves.  Queued after every earlier call.
    public func reload() async {
        _ = try? await serially { [backend] in
            let summary = await backend.summary()
            let after = await backend.read { $0 }
            self.undoTitle = summary.undo.undoTitle
            self.redoTitle = summary.undo.redoTitle
            self.canUndo = summary.undo.canUndo
            self.canRedo = summary.undo.canRedo
            self.replica = summary.replica
            let before = self.state
            self.state = after
            self.revision += 1
            let event = DocumentEvent(change: Wiretuner_Doc_V1_Change(), origin: .reload, before: before, after: after)
            for id in self.observers.keys.sorted() {
                self.observers[id]?(event)
            }
        }
    }

    /// Applies a change from the server's log (the sync client's path in).
    public func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) async throws {
        _ = try await serially { [backend] in
            try await self.publish(backend.receive(change, serverSeq: serverSeq), origin: .remote)
        }
    }

    /// Opens an undo group: every command performed until the matching `endGroup` joins one undo
    /// step (a drag emitting a change per drag event).  Groups nest; the outermost decides.
    public func beginGroup() {
        groupDepth += 1
        if groupDepth == 1 {
            group = nextGroup
            nextGroup += 1
        }
    }

    /// Closes the group `beginGroup` opened.
    public func endGroup() {
        precondition(groupDepth > 0)   // endGroup without beginGroup
        groupDepth -= 1
        if groupDepth == 0 {
            group = nil
        }
    }

    /// Whether an undo group is open.
    public var isGrouping: Bool { groupDepth > 0 }

    /// Reads the merged state on the backend's executor.
    public func read<T: Sendable>(_ body: @escaping @Sendable (EngineState) throws -> T) async rethrows -> T {
        try await backend.read(body)
    }

    private func recording() -> DocumentCore.Recording {
        DocumentCore.Recording(group: group, limit: undoLevels, now: clock())
    }

    private func publish(_ update: DocumentUpdate, origin: DocumentEvent.Origin) async -> Wiretuner_Doc_V1_Change? {
        let after = update.change == nil ? state : await backend.read { $0 }
        undoTitle = update.undo.undoTitle
        redoTitle = update.undo.redoTitle
        canUndo = update.undo.canUndo
        canRedo = update.undo.canRedo
        replica = update.replica
        if let change = update.change {
            let before = state
            state = after
            lastChange = change
            revision += 1
            let event = DocumentEvent(change: change, origin: origin, before: before, after: after)
            for id in observers.keys.sorted() {
                observers[id]?(event)
            }
        }
        return update.change
    }
}

/// One change the `Document` façade applied.
public struct DocumentEvent: Sendable {
    /// Where the change came from.
    public enum Origin: Sendable, Hashable {
        case local, undo, redo, remote
        /// The backend's state was replaced wholesale (`Document.reload`); the change is empty.
        case reload
    }

    public let change: Wiretuner_Doc_V1_Change
    public let origin: Origin
    /// The merged state before and after the change.
    public let before: EngineState
    public let after: EngineState
}
