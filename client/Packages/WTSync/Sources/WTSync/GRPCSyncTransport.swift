import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import WTProto

/// `SyncTransport` over grpc-swift 2: one long-lived client, so every call of a document session
/// -- the subscription and up to 32 pipelined pushes -- shares one HTTP/2 connection, whose
/// streams open in the order the calls are made (docs/spec/sync-protocol.adoc, "In-flight window
/// with unary pushes").  Every call carries the metadata of docs/spec/api-conventions.adoc:
/// the bearer token, `wt-client`, `wt-device` and a fresh `wt-request-id`.
public final class GRPCSyncTransport<Transport: ClientTransport>: SyncTransport {
    /// Who is calling, apart from the token.
    public struct Identity: Sendable, Hashable {
        /// `macos/<app version>/<build>` without the `macos/` prefix.
        public var clientVersion: String
        /// The stable per-install device id (not the replica id).
        public var deviceID: String

        public init(clientVersion: String, deviceID: String) {
            self.clientVersion = clientVersion
            self.deviceID = deviceID
        }
    }

    private let client: GRPCClient<Transport>
    private let service: Wiretuner_Sync_V1_SyncService.Client<Transport>
    private let blobService: Wiretuner_Blob_V1_BlobService.Client<Transport>
    private let identity: Identity
    private let connections: Task<Void, Never>

    /// A transport over `transport`; its connections run until `close()`.
    public init(transport: Transport, identity: Identity) {
        let client = GRPCClient(transport: transport)
        self.client = client
        service = Wiretuner_Sync_V1_SyncService.Client(wrapping: client)
        blobService = Wiretuner_Blob_V1_BlobService.Client(wrapping: client)
        self.identity = identity
        connections = Task { try? await client.runConnections() }
    }

    /// Closes the connection once in-flight calls have finished.
    public func close() async {
        client.beginGracefulShutdown()
        await connections.value
    }

    func metadata(_ token: String) -> Metadata {
        var metadata = Metadata()
        metadata.addString("Bearer \(token)", forKey: "authorization")
        metadata.addString("macos/\(identity.clientVersion)", forKey: "wt-client")
        metadata.addString(identity.deviceID, forKey: "wt-device")
        metadata.addString(UUID().uuidString, forKey: "wt-request-id")
        return metadata
    }

    /// An `RPCError` as `SyncCallError`, its `ErrorInfo` reason and `RetryInfo` delay read from
    /// the `google.rpc.Status` details; any other error as it is.
    static func mapped(_ error: any Error) -> any Error {
        guard let rpc = error as? RPCError else { return error }
        let details = (try? rpc.unpackGoogleRPCStatus())?.details ?? []
        let reason = details.lazy.compactMap(\.errorInfo).first.flatMap { SyncCallError.reason(named: $0.reason) }
        let delay = details.lazy.compactMap(\.retryInfo).first?.delay
        return SyncCallError(code: rpc.code.rawValue, reason: reason, message: rpc.message, retryAfter: delay)
    }

    private func unary<Output: Sendable>(_ body: () async throws -> Output) async throws -> Output {
        do {
            return try await body()
        } catch {
            throw Self.mapped(error)
        }
    }

    private func stream<Output: Sendable>(
        _ body: @escaping @Sendable (AsyncThrowingStream<Output, any Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<Output, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func subscribe(_ request: Wiretuner_Sync_V1_SubscribeRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Sync_V1_ServerFrame, any Error> {
        let metadata = metadata(token)
        return stream { [service] continuation in
            try await service.subscribe(request, metadata: metadata) { response in
                for try await frame in response.messages {
                    continuation.yield(frame)
                }
            }
        }
    }

    public func pushChange(_ request: Wiretuner_Sync_V1_PushChangeRequest, token: String) async throws
        -> Wiretuner_Sync_V1_PushChangeResponse {
        try await unary { try await service.pushChange(request, metadata: metadata(token)) }
    }

    public func pushChangeBatch(_ request: Wiretuner_Sync_V1_PushChangeBatchRequest, token: String) async throws
        -> Wiretuner_Sync_V1_PushChangeBatchResponse {
        try await unary { try await service.pushChangeBatch(request, metadata: metadata(token)) }
    }

    public func pushChanges(_ frames: [Wiretuner_Sync_V1_PushChangesRequest], token: String) async throws
        -> Wiretuner_Sync_V1_PushChangesResponse {
        try await unary {
            try await service.pushChanges(metadata: metadata(token)) { writer in
                try await writer.write(contentsOf: frames)
            }
        }
    }

    public func updatePresence(_ request: Wiretuner_Sync_V1_UpdatePresenceRequest, token: String) async throws {
        _ = try await unary { try await service.updatePresence(request, metadata: metadata(token)) }
    }

    public func ack(_ request: Wiretuner_Sync_V1_AckRequest, token: String) async throws -> Wiretuner_Sync_V1_AckResponse {
        try await unary { try await service.ack(request, metadata: metadata(token)) }
    }

    public func fetchChanges(_ request: Wiretuner_Sync_V1_FetchChangesRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchChangesResponse, any Error> {
        let metadata = metadata(token)
        return stream { [service] continuation in
            try await service.fetchChanges(request, metadata: metadata) { response in
                for try await message in response.messages {
                    continuation.yield(message)
                }
            }
        }
    }

    public func fetchSnapshot(_ request: Wiretuner_Sync_V1_FetchSnapshotRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Sync_V1_FetchSnapshotResponse, any Error> {
        let metadata = metadata(token)
        return stream { [service] continuation in
            try await service.fetchSnapshot(request, metadata: metadata) { response in
                for try await message in response.messages {
                    continuation.yield(message)
                }
            }
        }
    }
}

/// The blob service on the same connection (SYNC-008).
extension GRPCSyncTransport: BlobTransport {
    public func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) async throws -> Wiretuner_Blob_V1_StatResponse {
        try await unary { try await blobService.stat(request, metadata: metadata(token)) }
    }

    public func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws
        -> Wiretuner_Blob_V1_UploadResponse {
        try await unary {
            try await blobService.upload(metadata: metadata(token)) { writer in
                try await writer.write(.with { $0.header = header })
                for try await chunk in chunks {
                    try await writer.write(.with { $0.chunk = chunk })
                }
            }
        }
    }

    public func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String)
        -> AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error> {
        let metadata = metadata(token)
        return stream { [blobService] continuation in
            try await blobService.download(request, metadata: metadata) { response in
                for try await message in response.messages {
                    continuation.yield(message)
                }
            }
        }
    }
}

extension GRPCSyncTransport where Transport == HTTP2ClientTransport.Posix {
    /// The HTTP/2 transport to the API at `api` (`https` for TLS; the port defaults by scheme).
    public static func http2(api: URL, identity: Identity) throws -> GRPCSyncTransport {
        let tls = api.scheme == "https"
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: api.host ?? "localhost", port: api.port ?? (tls ? 443 : 80)),
            transportSecurity: tls ? .tls : .plaintext
        )
        return GRPCSyncTransport(transport: transport, identity: identity)
    }
}
