import Foundation
import Synchronization
import WTCRDT
import WTProto

// DATA-011: where a script's property sets and method calls land (scripting.adoc, "JavaScript
// runtime"): every mutating call runs one `WTModel` command and returns after the change is
// emitted; reads take a snapshot of the merged state.  Scripts run on their own thread, so a
// target is called synchronously from it.

/// The document a script runs on.  Called from the script's thread only.
public protocol ScriptTarget: AnyObject, Sendable {
    /// The merged state now (a snapshot: objects created by collaborators later are not visited
    /// unless the script reads again).
    func snapshot() -> EngineState
    /// Performs `command` as one change and returns it (nil when it wrote nothing).
    @discardableResult
    func perform(_ command: any Command) throws -> Wiretuner_Doc_V1_Change?
    /// Opens and closes an undo group (`wt.document.transaction`).
    func beginGroup()
    func endGroup()
    /// The selection (read and set by `wt.document.selection`).
    var selection: [OpID] { get set }
    /// The document's name (`wt.document.name`).
    var name: String { get }
}

/// A command run under a script's label (`Script: Name blocks`).
public struct ScriptLabelled: Command {
    public var base: any Command
    public var label: String
    public var coalescing: UndoCoalescing { .none }

    public init(_ base: any Command, label: String) {
        self.base = base
        self.label = label
    }

    public func execute(_ builder: inout ChangeBuilder, state: EngineState) throws {
        try base.execute(&builder, state: state)
    }
}

/// A `ScriptTarget` over a `DocumentCore` held here: headless runs (a merge's transforms and
/// script sources, command-line tools) and tests.
public final class CoreScriptTarget: ScriptTarget, @unchecked Sendable {
    private let lock = NSLock()
    private var core: DocumentCore
    private var group: UInt64?
    private var groupDepth = 0
    private var nextGroup: UInt64 = 1
    private var chosen: [OpID] = []
    private var sent: [Wiretuner_Doc_V1_Change] = []
    public let name: String
    private let clock: @Sendable () -> Date

    public init(_ core: DocumentCore, name: String = "Untitled", clock: @escaping @Sendable () -> Date = Date.init) {
        self.core = core
        self.name = name
        self.clock = clock
    }

    /// The core as it is now.
    public var current: DocumentCore { lock.withLock { core } }
    /// Every change performed through the target, in order.
    public var changes: [Wiretuner_Doc_V1_Change] { lock.withLock { sent } }

    public func snapshot() -> EngineState { lock.withLock { core.state } }

    @discardableResult
    public func perform(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        try lock.withLock {
            let change = try core.perform(command, recording: DocumentCore.Recording(group: group, limit: 1_000, now: clock()))?.change
            if let change { sent.append(change) }
            return change
        }
    }

    /// Undoes the last step (tests: a transaction is one step).
    @discardableResult
    public func undo() -> Wiretuner_Doc_V1_Change? {
        lock.withLock {
            let change = core.undo(recording: DocumentCore.Recording(limit: 1_000, now: clock()))?.change
            if let change { sent.append(change) }
            return change
        }
    }

    public func beginGroup() {
        lock.withLock {
            groupDepth += 1
            if groupDepth == 1 {
                group = nextGroup
                nextGroup += 1
            }
        }
    }

    public func endGroup() {
        lock.withLock {
            groupDepth = max(0, groupDepth - 1)
            if groupDepth == 0 { group = nil }
        }
    }

    public var selection: [OpID] {
        get { lock.withLock { chosen } }
        set { lock.withLock { chosen = newValue } }
    }
}

/// The document as a transform or a script source sees it: readable, never changed (a data
/// merge's scripts compute values; they do not edit the document).
public final class ReadOnlyScriptTarget: ScriptTarget, @unchecked Sendable {
    private let state: EngineState
    public let name: String

    public init(_ state: EngineState, name: String = "") {
        self.state = state
        self.name = name
    }

    public func snapshot() -> EngineState { state }

    public func perform(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        throw ScriptUnavailable(call: "Changing the document from a data-merge script")
    }

    public func beginGroup() {}
    public func endGroup() {}
    public var selection: [OpID] {
        get { [] }
        set {}
    }
}

/// A `ScriptTarget` over the window's `Document`: each call hops to the main actor and waits.
/// It must never be called on the main thread (the script runs on its own thread; the main
/// actor stays free to perform the command).
public final class DocumentScriptTarget: ScriptTarget, @unchecked Sendable {
    private let document: Document
    public let name: String
    private let chosen: Mutex<[OpID]>
    private let onSelection: @MainActor @Sendable ([OpID]) -> Void

    @MainActor
    public init(_ document: Document, name: String, selection: [OpID] = [], onSelection: @escaping @MainActor @Sendable ([OpID]) -> Void = { _ in }) {
        self.document = document
        self.name = name
        chosen = Mutex(selection)
        self.onSelection = onSelection
    }

    /// Runs `body` on the main actor and waits for its value (never from the main thread).
    private func hop<T: Sendable>(_ body: @escaping @MainActor @Sendable () async -> T) -> T {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let box = Mutex<T?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let value = await body()
            box.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        return box.withLock { $0! }
    }

    public func snapshot() -> EngineState {
        hop { [document] in document.state }
    }

    @discardableResult
    public func perform(_ command: any Command) throws -> Wiretuner_Doc_V1_Change? {
        let box = UncheckedCommand(command)
        let result: Result<Wiretuner_Doc_V1_Change?, UncheckedError> = hop { [document] in
            do { return .success(try await document.perform(box.command)) } catch { return .failure(UncheckedError(error)) }
        }
        return try result.mapError(\.error).get()
    }

    public func beginGroup() {
        hop { [document] in document.beginGroup() }
    }

    public func endGroup() {
        hop { [document] in
            if document.isGrouping { document.endGroup() }
        }
    }

    public var selection: [OpID] {
        get { chosen.withLock { $0 } }
        set {
            chosen.withLock { $0 = newValue }
            let report = onSelection
            Task { @MainActor in report(newValue) }
        }
    }
}

/// Carries a command across to the main actor (commands are `Sendable`; the existential box is
/// not seen as such by every compiler).
private struct UncheckedCommand: @unchecked Sendable {
    let command: any Command
    init(_ command: any Command) { self.command = command }
}

/// Carries a command's error back from the main actor.
private struct UncheckedError: Error, @unchecked Sendable {
    let error: any Error
    init(_ error: any Error) { self.error = error }
}

/// Batching of a transaction's sets (scripting.adoc, "Merge semantics"): inside
/// `wt.document.transaction` the property sets accumulate into changes of at most 10,000 ops
/// (one `CompositeCommand` each, under the transaction's label), all one undo step; outside,
/// every set is its own change.  A script stopped mid-transaction flushes what it had, so the
/// document is consistent and partially applied.
final class ScriptWriter: @unchecked Sendable {
    let target: any ScriptTarget
    let defaultLabel: String
    private var transactionLabel: String?
    private var depth = 0
    private var pending: [any Command] = []
    private var pendingOps = 0
    private var base: EngineState?
    /// How many changes the run emitted.
    private(set) var changes = 0
    /// Ops per change inside a transaction.
    var maxOps = MergeChunking.maxOps

    init(target: any ScriptTarget, label: String) {
        self.target = target
        defaultLabel = label
    }

    var label: String { transactionLabel.map { "Script: \($0)" } ?? defaultLabel }

    var inTransaction: Bool { depth > 0 }

    /// The state reads see: the snapshot at the last flush inside a transaction, else now.
    func state() -> EngineState {
        if inTransaction, let base { return base }
        return target.snapshot()
    }

    /// Runs `command` now (outside a transaction) or queues it (inside one).  Creation passes
    /// `immediate` so its id is known at once.
    @discardableResult
    func write(_ command: any Command, immediate: Bool = false) throws -> Wiretuner_Doc_V1_Change? {
        guard inTransaction, !immediate else {
            try flush()
            let change = try target.perform(ScriptLabelled(command, label: label))
            if change != nil { changes += 1 }
            if inTransaction { base = target.snapshot() }
            return change
        }
        var scratch = ChangeBuilder(replica: 1, startCounter: 1)
        try command.execute(&scratch, state: state())
        if pendingOps + scratch.ops.count > maxOps, !pending.isEmpty { try flush() }
        pending.append(command)
        pendingOps += scratch.ops.count
        return nil
    }

    /// Emits the queued sets as one change.
    func flush() throws {
        guard !pending.isEmpty else { return }
        let batch = CompositeCommand(label, pending)
        pending = []
        pendingOps = 0
        if try target.perform(batch) != nil { changes += 1 }
        base = target.snapshot()
    }

    func begin(_ label: String) {
        if depth == 0 {
            transactionLabel = label
            target.beginGroup()
            base = target.snapshot()
        }
        depth += 1
    }

    func end() throws {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0 else { return }
        defer {
            target.endGroup()
            transactionLabel = nil
            base = nil
        }
        try flush()
    }

    /// Closes every open transaction after a stop or an error, keeping what was queued.
    func abandon() {
        while depth > 0 { try? end() }
    }
}
