import Foundation
import WTCRDT
import WTProto

/// The state of a document at a server sequence (COLLAB-021; history.adoc, "Merge semantics" and
/// "Offline behavior"): what the version window shows and what `WTModel.RestoreCommand` restores.
/// From the local log when it can rebuild the seq (`LocalStore.state(atServerSeq:)`, which works
/// offline), else from the server: the newest snapshot at or before the seq (`FetchSnapshot`),
/// then `FetchChanges` through exactly it, replayed into a scratch state.
public enum VersionStates {
    /// Why a version's state could not be built.
    public enum Failure: Error, Hashable {
        /// The server's changes skipped a seq (the history is not contiguous there).
        case gap(expected: UInt64, got: UInt64)
        /// The server's changes stopped before the seq.
        case incomplete(through: UInt64)
    }

    /// The state of the document in `store` at `serverSeq`: the local log's when it can rebuild
    /// it, else fetched through `transport` (nil: offline, which throws `incomplete` for a seq the
    /// local log cannot rebuild).
    public static func state(at serverSeq: UInt64, store: LocalStore, transport: (any SyncTransport)?,
                             token: @Sendable () async throws -> String) async throws -> EngineState {
        if let local = try await store.state(atServerSeq: serverSeq) {
            return local
        }
        guard let transport else { throw Failure.incomplete(through: 0) }
        return try await fetch(store.documentID, at: serverSeq, transport: transport, token: try await token(), schema: store.schema)
    }

    /// The state of `documentID` at `serverSeq` from the server.
    public static func fetch(_ documentID: String, at serverSeq: UInt64, transport: any SyncTransport, token: String,
                             schema: Schema = .generated) async throws -> EngineState {
        var state = EngineState(schema: schema)
        var applied: UInt64 = 0
        var snapshot = Wiretuner_Sync_V1_FetchSnapshotRequest()
        snapshot.documentID = documentID
        snapshot.atOrBeforeServerSeq = serverSeq
        do {
            var frames: [Wiretuner_Doc_V1_SnapshotFrame] = []
            for try await response in transport.fetchSnapshot(snapshot, token: token) {
                frames.append(response.frame)
            }
            let decoded = try SnapshotDownload.state(frames, schema: schema)
            if decoded.serverSeq <= serverSeq {
                state = decoded.state
                applied = decoded.serverSeq
            }
        } catch let error as SyncCallError where error.reason == .historyUnavailable {
            // No snapshot at or before it: the log from the start.
        }
        guard applied < serverSeq else { return state }
        var request = Wiretuner_Sync_V1_FetchChangesRequest()
        request.documentID = documentID
        request.afterServerSeq = applied
        request.untilServerSeq = serverSeq
        for try await response in transport.fetchChanges(request, token: token) {
            for change in response.changes where change.serverSeq > applied && change.serverSeq <= serverSeq {
                guard change.serverSeq == applied + 1 else { throw Failure.gap(expected: applied + 1, got: change.serverSeq) }
                state.apply(change.change, serverSeq: change.serverSeq)
                applied = change.serverSeq
            }
        }
        guard applied == serverSeq else { throw Failure.incomplete(through: applied) }
        return state
    }
}
