import Foundation
import WTCRDT
import WTProto
import WTSync

/// The server's named versions as the history scenarios need them (COLLAB-024; history.adoc,
/// "Server", as built by SRV-011): `NameVersion` idempotent on `version_id` (the id on another
/// document is `ALREADY_EXISTS`), editors and owners only, `server_seq` 0 meaning the head and a
/// seq beyond the head refused, `through_local_change` resolved to the `server_seq` of the
/// replica's logged change whose counters hold it (not logged: `FAILED_PRECONDITION`, the
/// server's `HISTORY_UNAVAILABLE`); `ListVersions` newest first.  The log and the roles are the
/// `SimServer`'s.  `transport(link:)` gives a client its calls through its network link: a
/// partitioned client is offline.
public final class SimVersionService: Sendable {
    private let versions = Locked<[String: [Wiretuner_Docs_V1_Version]]>([:])
    public let server: SimServer

    public init(server: SimServer) {
        self.server = server
    }

    /// A document's versions, newest first.
    public func versions(of document: String) -> [Wiretuner_Docs_V1_Version] {
        versions.withLock { $0[document] ?? [] }
    }

    public func transport(link: NetworkLink) -> SimVersionTransport {
        SimVersionTransport(service: self, link: link)
    }

    public func nameVersion(_ request: Wiretuner_Docs_V1_NameVersionRequest, token: String) async throws -> Wiretuner_Docs_V1_Version {
        let caller = try await server.authorize(token: token, document: request.documentID)
        guard caller.role == .editor || caller.role == .owner else {
            throw SyncCallError(code: SyncCallError.permissionDenied, reason: .roleInsufficient, message: "not an editor")
        }
        let existing = versions.withLock { all in all.values.joined().first { $0.id == request.versionID } }
        if let existing {
            guard existing.documentID == request.documentID else { throw SyncCallError(code: 6, message: "version id used on another document") }
            return existing
        }
        let log = await server.log(request.documentID)
        let head = UInt64(log.count)
        guard request.serverSeq <= head else { throw SyncCallError(code: SyncCallError.failedPrecondition, message: "seq beyond the head") }
        var seq = request.serverSeq == 0 ? head : request.serverSeq
        if request.hasThroughLocalChange {
            let through = request.throughLocalChange
            guard let entry = log.first(where: { Self.holds($0.change, counter: through.counter, replica: through.replica) }) else {
                throw SyncCallError(code: SyncCallError.failedPrecondition, message: "through_local_change is not in the log")
            }
            seq = entry.serverSeq
        }
        var version = Wiretuner_Docs_V1_Version()
        version.id = request.versionID
        version.documentID = request.documentID
        version.serverSeq = seq
        version.name = request.name
        version.note = request.note
        version.createdBy.displayName = caller.account
        version.createdAt = .init(date: Date(timeIntervalSince1970: Double(server.clock.nowMs()) / 1000))
        return versions.withLock { all in
            if let raced = all.values.joined().first(where: { $0.id == request.versionID }) { return raced }
            all[request.documentID, default: []].insert(version, at: 0)
            return version
        }
    }

    public func listVersions(_ request: Wiretuner_Docs_V1_ListVersionsRequest, token: String) async throws -> Wiretuner_Docs_V1_ListVersionsResponse {
        _ = try await server.authorize(token: token, document: request.documentID)
        var response = Wiretuner_Docs_V1_ListVersionsResponse()
        response.versions = versions(of: request.documentID)
        return response
    }

    /// Whether `change` holds the op with `counter` of `replica`.
    static func holds(_ change: Wiretuner_Doc_V1_Change, counter: UInt64, replica: UInt64) -> Bool {
        guard change.replica == replica, counter >= change.startCounter else { return false }
        let count = change.ops.reduce(UInt64(0)) { $0 + EngineState.counters($1) }
        return counter < change.startCounter + count
    }
}

/// `SimVersionService` through one client's link.
public struct SimVersionTransport: Sendable {
    let service: SimVersionService
    let link: NetworkLink

    private func online() throws {
        guard !link.isPartitioned else { throw SyncCallError(code: SyncCallError.unavailable, message: "offline") }
    }

    public func nameVersion(_ request: Wiretuner_Docs_V1_NameVersionRequest, token: String) async throws -> Wiretuner_Docs_V1_Version {
        try online()
        return try await service.nameVersion(request, token: token)
    }

    public func listVersions(_ request: Wiretuner_Docs_V1_ListVersionsRequest, token: String) async throws -> Wiretuner_Docs_V1_ListVersionsResponse {
        try online()
        return try await service.listVersions(request, token: token)
    }
}
