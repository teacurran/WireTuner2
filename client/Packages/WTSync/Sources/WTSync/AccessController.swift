import Foundation
import WTProto

/// Role changes during a session (COLLAB-014; sharing.adoc, "When your access changes
/// mid-session" and "Merge semantics"): reads the sync client's state -- a lowered role in
/// `RoleChanged` or `Welcome`, `ROLE_INSUFFICIENT` on a push, `AccessRemoved` -- and
///
/// * makes the document read-only at once (`LocalStore.setReadOnly`: no local change enters the
///   outbox) while remote changes keep applying;
/// * freezes the outbox: the unsent changes made before are held (`SyncClient.holdOutbox`) and
///   offered as *Save as a Copy…* (`saveAsCopy`: `DocumentService.Fork` at the applied head with
///   them) or *Discard* (`discard`); they are never sent to the shared document, even when the role
///   is raised again before the person decides;
/// * on removal, after the offer, deletes the local store (`deleteStore`);
/// * on a raised role, makes the document editable again without reopening it.
///
/// WTApp creates one per open document beside the `SyncClient`, shows `status.banner` in the bar
/// under the toolbar with the two buttons while `status.unsent > 0`, and closes the window after
/// `deleteStore` for a removal.
public actor AccessController {
    /// What the bar shows.
    public struct Status: Sendable, Hashable {
        /// Whether local edits are accepted.
        public var editable: Bool
        /// Why not, when not.
        public var reason: ReadOnlyReason?
        /// Unsent changes waiting for *Save as a Copy…* or *Discard*.
        public var unsent: Int

        public init(editable: Bool = true, reason: ReadOnlyReason? = nil, unsent: Int = 0) {
            self.editable = editable
            self.reason = reason
            self.unsent = unsent
        }

        /// The bar's text: "You can no longer edit this document", "You no longer have access";
        /// nil when there is nothing to say.
        public var banner: String? {
            switch reason {
            case .accessRemoved?: "You no longer have access"
            case .role?, .roleInsufficient?: "You can no longer edit this document"
            case .clientTooOld?: "This document needs a newer version of WireTuner to edit"
            case nil: unsent > 0 ? "Changes you made while you could not edit have not been sent" : nil
            }
        }

        /// Whether the access was removed (the window closes once the offer is settled).
        public var isRemoved: Bool { reason == .accessRemoved }
    }

    /// Why an offer could not be carried out.
    public enum Failure: Error, Hashable {
        /// A copy's remaining changes were not all accepted: the last seq that was.
        case copyIncomplete(acceptedThrough: UInt64)
    }

    /// The most changes a `Fork` carries, and the bytes (the rest follow through `PushChanges`).
    public static let forkChanges = 1_000
    public static let forkBytes = 1 << 20

    let store: LocalStore
    let client: SyncClient
    let sync: any SyncTransport
    let copies: any DocumentCopyTransport
    let tokens: any TokenProvider
    /// The status now.
    public private(set) var status = Status()
    private var watcher: Task<Void, Never>?
    private let broadcast = Broadcast<Status>()
    /// The frozen changes wait for a decision.
    private var frozen = false

    /// A controller for the document `client` syncs from `store`; `sync` carries a large copy's
    /// remaining changes, `copies` the `Fork`.
    public init(store: LocalStore, client: SyncClient, sync: any SyncTransport, copies: any DocumentCopyTransport,
                tokens: any TokenProvider) {
        self.store = store
        self.client = client
        self.sync = sync
        self.copies = copies
        self.tokens = tokens
    }

    /// Starts following the sync client's state (idempotent).
    public func start() async {
        guard watcher == nil else { return }
        let states = await client.states()
        watcher = Task { [weak self] in
            for await state in states {
                await self?.apply(state)
            }
        }
    }

    /// Stops following.
    public func stop() {
        watcher?.cancel()
        watcher = nil
    }

    /// The status now and every change after.
    public func statuses() -> AsyncStream<Status> {
        broadcast.stream(initial: status)
    }

    /// Applies one published sync state.
    func apply(_ state: SyncState) async {
        var next = status
        if case .readOnly(let reason) = state {
            await store.setReadOnly(true)
            next.editable = false
            next.reason = reason
            if reason != .clientTooOld && !frozen, let unsent = try? await store.outboxCount(), unsent > 0 {
                frozen = true
                await client.holdOutbox(true)
                next.unsent = unsent
            }
        } else if !status.editable {
            // Raised again: editable without reopening; frozen changes still wait for the offer.
            await store.setReadOnly(false)
            next.editable = true
            next.reason = nil
        }
        publish(next)
    }

    private func publish(_ next: Status) {
        guard next != status else { return }
        status = next
        broadcast.yield(next)
    }

    /// *Save as a Copy…*: a new document of the caller's (`DocumentService.Fork` at the applied
    /// head) holding the frozen changes -- the first `forkChanges` (and `forkBytes`) in the call,
    /// the rest through `PushChanges` to the copy -- then the document reverts to the server's
    /// state.  Returns the copy's id.
    @discardableResult
    public func saveAsCopy(name: String, newDocumentID: String = DocumentIdentifier.make()) async throws -> String {
        let changes = try await store.outbox()
        var request = Wiretuner_Docs_V1_ForkRequest()
        request.sourceDocumentID = store.documentID
        request.newDocumentID = newDocumentID
        request.atServerSeq = await store.lastServerSeq
        request.name = String(name.prefix(256))
        var bytes = 0
        var count = 0
        while count < changes.count, count < Self.forkChanges {
            let size = (try? changes[count].serializedData().count) ?? 0
            guard count == 0 || bytes + size <= Self.forkBytes else { break }
            bytes += size
            count += 1
        }
        request.changes = Array(changes.prefix(count))
        let token = try await tokens.accessToken(forceRefresh: false)
        _ = try await copies.fork(request, token: token)
        let rest = Array(changes.dropFirst(count))
        if let last = rest.last {
            let response = try await sync.pushChanges(BulkFrames.pack(rest, documentID: newDocumentID), token: token)
            guard response.lastAcceptedSeq >= last.seq else { throw Failure.copyIncomplete(acceptedThrough: response.lastAcceptedSeq) }
        }
        try await settle()
        return newDocumentID
    }

    /// *Discard*: the frozen changes are dropped and the document reverts to the server's state.
    public func discard() async throws {
        try await settle()
    }

    private func settle() async throws {
        try await client.discardUnsent()
        frozen = false
        await client.holdOutbox(false)
        var next = status
        next.unsent = 0
        publish(next)
    }

    /// After a removal's offer: stops the sync client and deletes the local store.
    public func deleteStore() async throws {
        stop()
        await client.stop()
        try await store.delete()
    }
}
