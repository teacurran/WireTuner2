import Foundation
import WTProto
import WTSync

/// The copy calls (`Fork`, `CreateBranch`) of one simulated device, refused while its link is cut
/// as a real call would fail offline (COLLAB-014, COLLAB-017 scenarios).
public struct SimCopyTransport: DocumentCopyTransport {
    public let upstream: SimServerTransport
    public let link: NetworkLink

    public init(server: SimServer, device: String, link: NetworkLink) {
        upstream = SimServerTransport(server: server, device: device)
        self.link = link
    }

    private func check() throws {
        guard !link.isPartitioned else { throw SyncCallError(code: SyncCallError.unavailable, message: "offline") }
    }

    public func fork(_ request: Wiretuner_Docs_V1_ForkRequest, token: String) async throws -> Wiretuner_Docs_V1_ForkResponse {
        try check()
        return try await upstream.fork(request, token: token)
    }

    public func createBranch(_ request: Wiretuner_Docs_V1_CreateBranchRequest, token: String) async throws
        -> Wiretuner_Docs_V1_CreateBranchResponse {
        try check()
        return try await upstream.createBranch(request, token: token)
    }
}
