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

    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var groupDepth = 0
    @ObservationIgnored private var group: UInt64?
    @ObservationIgnored private var nextGroup: UInt64 = 1

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
    }

    /// Performs `command` as one change (or part of the open group's undo step) and returns the
    /// change, or nil when the command appended no ops.
    @discardableResult
    public func perform(_ command: any Command) async throws -> Wiretuner_Doc_V1_Change? {
        try await publish(backend.perform(command, recording: recording()))
    }

    /// Undoes this user's last step.  Returns the emitted change, or nil when nothing was left to
    /// undo (the step still moves to the redo list) or the list was empty.
    @discardableResult
    public func undo() async throws -> Wiretuner_Doc_V1_Change? {
        try await publish(backend.undo(recording: recording()))
    }

    /// Redoes the last undone step; as `undo`.
    @discardableResult
    public func redo() async throws -> Wiretuner_Doc_V1_Change? {
        try await publish(backend.redo(recording: recording()))
    }

    /// Applies a change from the server's log (the sync client's path in).
    public func receive(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) async throws {
        _ = try await publish(backend.receive(change, serverSeq: serverSeq))
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

    private func publish(_ update: DocumentUpdate) -> Wiretuner_Doc_V1_Change? {
        undoTitle = update.undo.undoTitle
        redoTitle = update.undo.redoTitle
        canUndo = update.undo.canUndo
        canRedo = update.undo.canRedo
        replica = update.replica
        if let change = update.change {
            lastChange = change
            revision += 1
        }
        return update.change
    }
}
