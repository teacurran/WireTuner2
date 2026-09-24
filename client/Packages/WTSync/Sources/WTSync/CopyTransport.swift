import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import WTProto

/// The calls that put a document's unsent work somewhere else: `DocumentService.Fork` for *Save
/// as a Copy…* when the caller can no longer edit (COLLAB-014, sharing.adoc "When your access
/// changes mid-session"), and `BranchService.CreateBranch` for a branch made on this Mac
/// (COLLAB-017, branches.adoc "Offline-created branch").  `GRPCDocumentCopyTransport` is the
/// network one; tests and the simulator supply their own.
public protocol DocumentCopyTransport: Sendable {
    func fork(_ request: Wiretuner_Docs_V1_ForkRequest, token: String) async throws -> Wiretuner_Docs_V1_ForkResponse
    func createBranch(_ request: Wiretuner_Docs_V1_CreateBranchRequest, token: String) async throws -> Wiretuner_Docs_V1_CreateBranchResponse
}

/// `DocumentCopyTransport` over grpc-swift 2 with the metadata of api-conventions.adoc; rejections
/// arrive as `SyncCallError`s, as they do from `GRPCSyncTransport`.
public final class GRPCDocumentCopyTransport<Transport: ClientTransport>: DocumentCopyTransport {
    private let client: GRPCClient<Transport>
    private let documents: Wiretuner_Docs_V1_DocumentService.Client<Transport>
    private let branches: Wiretuner_Docs_V1_BranchService.Client<Transport>
    private let identity: GRPCSyncTransport<Transport>.Identity
    private let connections: Task<Void, Never>

    /// A transport over `transport`; its connections run until `close()`.
    public init(transport: Transport, identity: GRPCSyncTransport<Transport>.Identity) {
        let client = GRPCClient(transport: transport)
        self.client = client
        documents = Wiretuner_Docs_V1_DocumentService.Client(wrapping: client)
        branches = Wiretuner_Docs_V1_BranchService.Client(wrapping: client)
        self.identity = identity
        connections = Task { try? await client.runConnections() }
    }

    /// Closes the connection once in-flight calls have finished.
    public func close() async {
        client.beginGracefulShutdown()
        await connections.value
    }

    private func metadata(_ token: String) -> Metadata {
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/\(identity.clientVersion)", forKey: "wt-client")
        metadata.addString(identity.deviceID, forKey: "wt-device")
        metadata.addString(UUID().uuidString, forKey: "wt-request-id")
        return metadata
    }

    private func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> Output {
        do {
            return try await body()
        } catch {
            throw GRPCSyncTransport<Transport>.mapped(error)
        }
    }

    public func fork(_ request: Wiretuner_Docs_V1_ForkRequest, token: String) async throws -> Wiretuner_Docs_V1_ForkResponse {
        try await unary { try await documents.fork(request, metadata: metadata(token)) }
    }

    public func createBranch(_ request: Wiretuner_Docs_V1_CreateBranchRequest, token: String) async throws
        -> Wiretuner_Docs_V1_CreateBranchResponse {
        try await unary { try await branches.createBranch(request, metadata: metadata(token)) }
    }
}

extension GRPCDocumentCopyTransport where Transport == HTTP2ClientTransport.Posix {
    /// The HTTP/2 transport to the API at `api` (`https` for TLS; the port defaults by scheme).
    public static func http2(api: URL, identity: GRPCSyncTransport<Transport>.Identity) throws -> GRPCDocumentCopyTransport {
        let tls = api.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: api.host ?? "localhost", port: api.port ?? (tls ? 443 : 80)),
            transportSecurity: tls ? .tls : .plaintext
        )
        return GRPCDocumentCopyTransport(transport: transport, identity: identity)
    }
}

/// Client-generated document ids (api-conventions.adoc): UUIDv7 (RFC 9562) -- 48 bits of Unix
/// milliseconds, version 7, the variant, 74 random bits -- which `ForkRequest.new_document_id`
/// and `CreateBranchRequest.branch_document_id` require.
public enum DocumentIdentifier {
    public static func make(milliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
                            random: [UInt8] = (0..<10).map { _ in UInt8.random(in: .min ... .max) }) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * UInt64(5 - index)))
        }
        let random = random + [UInt8](repeating: 0, count: max(0, 10 - random.count))
        bytes[6] = 0x70 | (random[0] & 0x0F)
        bytes[7] = random[1]
        bytes[8] = 0x80 | (random[2] & 0x3F)
        for index in 9..<16 {
            bytes[index] = random[index - 6]
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
            .joined(separator: "-")
    }
}
