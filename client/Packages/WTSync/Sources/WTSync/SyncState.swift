import Foundation
import WTProto

/// A document's sync state (docs/_includes/io/saving.adoc, "Sync state machine"): the one answer
/// to "has everything I did here reached the cloud?".  `SyncClient` computes it from the session,
/// the outbox and the blob queue and publishes every transition with its cause; the UI never
/// infers it from network state.
public enum SyncState: Sendable, Hashable, CustomStringConvertible {
    /// Bootstrap or catch-up running, never connected yet.
    case opening
    /// Subscription up, outbox and in-flight window empty, no blob waiting.
    case saved
    /// Subscription up, `n` local changes on their way as pipelined pushes.
    case syncing(Int)
    /// Outbox empty, `n` blobs (not the thumbnail) still uploading.
    case uploadingBlobs(Int)
    /// No subscription (no route, connect failed, backoff); `n` is the outbox count.
    case offline(Int)
    /// A backlog at or over the bulk threshold going up through `PushChanges`; the percentage of
    /// its coalesced bytes acknowledged.
    case uploadingBacklog(Int)
    /// Divergence measurement said "ask"; the outbox is held (SYNC-006).
    case needsReview
    /// The document can be viewed, not edited.
    case readOnly(ReadOnlyReason)
    /// The token could not be renewed silently.
    case needsSignIn
    /// Blob uploads refused by the storage quota; `n` blobs wait (the blob queue's state).
    case storageFull(Int)
    /// Something retrying cannot fix.
    case error(String)

    /// The window subtitle (saving.adoc, "The sync indicator").
    public var description: String {
        switch self {
        case .opening: "Opening…"
        case .saved: "Saved to cloud"
        case .syncing(let count): count == 1 ? "Syncing 1 change" : "Syncing \(count) changes"
        case .uploadingBlobs(let count): count == 1 ? "Uploading 1 image" : "Uploading \(count) images"
        case .offline(0): "Offline"
        case .offline(let count): count == 1 ? "Offline — 1 change waiting" : "Offline — \(count) changes waiting"
        case .uploadingBacklog(let percent): "Uploading backlog \(percent)%"
        case .needsReview: "Needs review"
        case .readOnly: "View only"
        case .needsSignIn: "Sign in to sync"
        case .storageFull(let count): count == 1 ? "Storage full — 1 image waiting" : "Storage full — \(count) images waiting"
        case .error: "Can't sync"
        }
    }
}

/// Why a document is `readOnly`.
public enum ReadOnlyReason: Sendable, Hashable {
    /// The caller's role is viewer or commenter.
    case role
    /// The document's feature level is above this client's (`CLIENT_TOO_OLD`).
    case clientTooOld
    /// A push was refused with `ROLE_INSUFFICIENT`: the role was downgraded while offline.
    case roleInsufficient
    /// The caller's access to the document was removed.
    case accessRemoved
}

/// One arrow of the state machine, with what caused it.
public struct SyncTransition: Sendable, Hashable {
    public var from: SyncState
    public var to: SyncState
    public var cause: String

    public init(from: SyncState, to: SyncState, cause: String) {
        self.from = from
        self.to = to
        self.cause = cause
    }
}

/// How far bootstrap or catch-up has come (SYNC-004).
public struct CatchUpProgress: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// `FetchSnapshot`: compressed bytes received of the header's total.
        case snapshot
        /// `FetchChanges`: server sequences applied of the range.
        case changes
    }

    public var phase: Phase
    public var completed: UInt64
    public var total: UInt64

    public init(phase: Phase, completed: UInt64, total: UInt64) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    /// `completed` over `total`, 1 for an empty range.
    public var fraction: Double { total == 0 ? 1 : min(1, Double(completed) / Double(total)) }
}

/// Everything else a session reports besides its state.
public enum SyncEvent: Sendable {
    /// The merged state was replaced by a snapshot from the server; views re-read the document.
    case stateReplaced(serverSeq: UInt64)
    /// Bootstrap or catch-up progress.
    case catchUp(CatchUpProgress)
    /// Everyone present, after the replay.
    case presence(Wiretuner_Sync_V1_PresenceSnapshot)
    /// One participant's presence.
    case presenceUpdate(Wiretuner_Sync_V1_PresenceUpdate)
    /// Renamed, shared, role changed, access removed, trashed, branch, reconnect, members.
    case document(Wiretuner_Sync_V1_DocumentEvent)
    /// The server refused change `seq` with `VALIDATION_FAILED`: it was replaced by `Noop`s and
    /// must be reported as a bug (a change that passed the client validators never should).
    case changeDropped(seq: UInt64, message: String)
    /// `REPLICA_CONFLICT` or `REPLICA_EXPIRED`: the store rotated to a new replica id; the old
    /// one's unsent changes wait in `LocalStore.retiredOutbox()` for salvage.
    case replicaRotated(from: UInt64, to: UInt64)
    /// `Welcome.merge_table` names a table other than the bundled one (`WTMergeTable.version`).
    case mergeTableDiffers(server: String)
    /// The document's stable sequence as the last `Ack` answered.
    case stable(UInt64)
    /// A collection point (C, T) the last `Ack` answered (D-067): the replica may collect at it.
    case collectionPoint(seq: UInt64, timeMs: Int64)
    /// The subscription came up (after `Welcome`) or ended: presence freezes and clears on false.
    case connection(Bool)
    /// A reconnect merged without holding the outbox (SYNC-006): the toast, and the read-only
    /// review *Review what changed* opens (`SyncClient.lastMerge`).
    case merged(ReviewModel)
    /// The divergence rules, or salvage, hold the outbox until `SyncClient.resolveReview`: open the
    /// review sheet (`SyncClient.pendingReview`).
    case reviewNeeded(ReviewModel)
    /// Salvage re-issued a retired replica's unsent changes (SYNC-010).
    case salvaged(SalvageReport)
}
