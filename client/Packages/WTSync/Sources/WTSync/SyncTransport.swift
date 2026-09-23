import Foundation
import WTModel
import WTProto

/// The sync service as the client calls it (docs/spec/sync-protocol.adoc, "Services"): one
/// server-streaming `Subscribe`, unary pushes, a client-streaming bulk upload, and the catch-up
/// downloads.  `GRPCSyncTransport` is the grpc-swift 2 implementation; tests drive `SyncClient`
/// through the same seam.  A call the server refused throws `SyncCallError`; anything else thrown
/// is a transport failure, which ends the session.
public protocol SyncTransport: Sendable {
    func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error>
    func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws
        -> Wiretuner_Sync_V1_PushChangeResponse
    func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws
        -> Wiretuner_Sync_V1_PushChangeBatchResponse
    func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws
        -> Wiretuner_Sync_V1_PushChangesResponse
    func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws
    func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse
    func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error>
    func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error>
}

/// A call the server answered with an error status: the gRPC code, and the reason
/// `google.rpc.ErrorInfo` carried (docs/spec/api-conventions.adoc, "Errors").
public struct SyncCallError: Error, Sendable, Hashable, CustomStringConvertible {
    public var code: Int
    public var reason: Wiretuner_Sync_V1_ErrorReason?
    public var message: String
    /// The `google.rpc.RetryInfo` delay, when the status carried one.
    public var retryAfter: Duration?

    public init(code: Int, reason: Wiretuner_Sync_V1_ErrorReason? = nil, message: String = "", retryAfter: Duration? = nil) {
        self.code = code
        self.reason = reason
        self.message = message
        self.retryAfter = retryAfter
    }

    /// A rejection a batch or bulk response carried.
    public init(_ rejected: Wiretuner_Sync_V1_ChangeRejected) {
        self.init(code: Int(rejected.code), reason: rejected.reason, message: rejected.message)
    }

    public static let cancelled = 1
    public static let invalidArgument = 3
    public static let notFound = 5
    public static let permissionDenied = 7
    public static let resourceExhausted = 8
    public static let failedPrecondition = 9
    public static let aborted = 10
    public static let unavailable = 14
    public static let unauthenticated = 16

    /// The reason as it travels in `ErrorInfo.reason` (the enum value name without
    /// `ERROR_REASON_`) read back into the enum; nil for a name this client does not know.
    public static func reason(named name: String) -> Wiretuner_Sync_V1_ErrorReason? {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }),
              let rejected = try? Wiretuner_Sync_V1_ChangeRejected(jsonString: #"{"reason":"ERROR_REASON_\#(name)"}"#) else {
            return nil
        }
        return rejected.reason
    }

    public var description: String {
        "status \(code)\(reason.map { " \($0)" } ?? ""): \(message)"
    }
}

/// Where the sync client gets its bearer token.  `forceRefresh` asks for a new one after the
/// server answered `UNAUTHENTICATED`.  Throwing `TokenFailure.signInRequired` means refreshing
/// failed for good (the state becomes *Sign in to sync*); anything else thrown is transient.
public protocol TokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

/// A token refresh that cannot succeed without the user.
public enum TokenFailure: Error, Sendable, Hashable {
    case signInRequired
}

/// The caller's presence (docs/_includes/collaboration/presence.adoc): current state, read at
/// up to 20 Hz and sent when it changed (and every few seconds, so the entry does not expire).
public protocol PresenceSource: Sendable {
    func presence() async -> Wiretuner_Sync_V1_PresenceUpdate?
}

/// Where remote changes are applied, in `server_seq` order: the `Document` façade of an open
/// window, or the `LocalStore` itself for a headless upload.  Either way the change must reach
/// the store the `SyncClient` sends from (a `Document` over that store as its backend), which
/// records it -- or, for this replica's own echo, its acknowledgement -- and the applied sequence.
public protocol RemoteChangeSink: AnyObject, Sendable {
    func applyRemote(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) async throws
    /// Records a stable point the server published: the replica's horizon (D-067,
    /// crdt-model.adoc "Stable points, horizons and collection points"), which only moves forward.
    func advanceHorizon(to stableSeq: UInt64) async
}

extension LocalStore: RemoteChangeSink {
    public func applyRemote(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) throws {
        _ = try receive(change, serverSeq: serverSeq)
    }
}

extension Document: RemoteChangeSink {
    public func applyRemote(_ change: Wiretuner_Doc_V1_Change, serverSeq: UInt64) async throws {
        try await receive(change, serverSeq: serverSeq)
    }

    /// Forwards to the backend, the `LocalStore` holding the document's `DocumentCore`.
    public func advanceHorizon(to stableSeq: UInt64) async {
        await (backend as? any RemoteChangeSink)?.advanceHorizon(to: stableSeq)
    }
}
