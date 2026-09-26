import CryptoKit
import Foundation
import WTProto
import WTSync

/// The server's blob store and publish service as the publish scenarios need them (WEB-013;
/// publish-html.adoc, "Server"): blobs by sha256, publishes per document newest first with the
/// current one marked, `CreatePublish` idempotent on its id and refusing a manifest naming a blob
/// it lacks, and every change announced to the document's sessions as `PublishesChanged` through
/// the `SimServer`.  `transports(link:)` gives a client its blob and publish transports through
/// that client's network link: a partitioned client is offline.
public final class SimPublishService: Sendable {
    struct State: Sendable {
        var blobs: [Data: Data] = [:]
        var uploadedBytes: Int64 = 0
        var publishes: [String: [Wiretuner_Publish_V1_Publish]] = [:]
        var manifests: [String: Wiretuner_Publish_V1_PublishManifest] = [:]
    }

    private let state = Locked(State())
    let server: SimServer

    public init(server: SimServer) {
        self.server = server
    }

    /// Blob bytes received so far.
    public var uploadedBytes: Int64 { state.withLock(\.uploadedBytes) }

    /// A document's publishes, newest first.
    public func publishes(of document: String) -> [Wiretuner_Publish_V1_Publish] {
        state.withLock { $0.publishes[document] ?? [] }
    }

    /// A client's transports, through `link`.
    public func transports(link: NetworkLink) -> SimPublishTransport {
        SimPublishTransport(service: self, link: link)
    }

    func stat(_ hash: Data) -> Bool {
        state.withLock { $0.blobs[hash] != nil }
    }

    func store(_ data: Data) {
        state.withLock {
            $0.blobs[Data(SHA256.hash(data: data))] = data
            $0.uploadedBytes += Int64(data.count)
        }
    }

    func blob(_ hash: Data) -> Data? {
        state.withLock { $0.blobs[hash] }
    }

    func create(_ request: Wiretuner_Publish_V1_CreatePublishRequest) async throws -> Wiretuner_Publish_V1_Publish {
        let outcome = state.withLock { state -> (publish: Wiretuner_Publish_V1_Publish, created: Bool)? in
            var list = state.publishes[request.documentID] ?? []
            if let existing = list.first(where: { $0.publishID == request.publishID }) { return (existing, false) }
            guard request.manifest.files.allSatisfy({ state.blobs[$0.sha256] != nil }) else { return nil }
            for index in list.indices { list[index].current = false }
            var publish = Wiretuner_Publish_V1_Publish()
            publish.publishID = request.publishID
            publish.documentID = request.documentID
            publish.serverSeq = request.serverSeq
            publish.settingName = request.settingName
            publish.access = request.access == .unspecified ? .members : request.access
            publish.url = "https://pub.sim/d/\(request.documentID)/"
            publish.current = true
            publish.fileCount = UInt32(request.manifest.files.count)
            publish.totalSize = request.manifest.files.reduce(0) { $0 + $1.size }
            list.insert(publish, at: 0)
            state.publishes[request.documentID] = list
            state.manifests[request.publishID] = request.manifest
            return (publish, true)
        }
        guard let outcome else { throw SyncCallError(code: 5, message: "blob not found") }
        if outcome.created { await announce(request.documentID) }
        return outcome.publish
    }

    func update(_ publishID: String, _ body: @Sendable (inout [Wiretuner_Publish_V1_Publish]) -> Void) async {
        let document = state.withLock { state -> String? in
            guard let document = state.publishes.first(where: { $0.value.contains { $0.publishID == publishID } })?.key else { return nil }
            body(&state.publishes[document, default: []])
            return document
        }
        if let document { await announce(document) }
    }

    func publish(_ publishID: String) -> (Wiretuner_Publish_V1_Publish, Wiretuner_Publish_V1_PublishManifest)? {
        state.withLock { state in
            for list in state.publishes.values {
                if let publish = list.first(where: { $0.publishID == publishID }) {
                    return (publish, state.manifests[publishID] ?? .init())
                }
            }
            return nil
        }
    }

    private func announce(_ document: String) async {
        var event = Wiretuner_Sync_V1_DocumentEvent()
        event.publishesChanged = Wiretuner_Sync_V1_PublishesChanged()
        await server.announce(event, on: document)
    }
}

/// `SimPublishService` through one client's link: its `BlobTransport` and `PublishTransport`.
public struct SimPublishTransport: BlobTransport, PublishTransport {
    let service: SimPublishService
    let link: NetworkLink

    private func online() throws {
        guard !link.isPartitioned else { throw SyncCallError(code: 14, message: "offline") }
    }

    public func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) async throws -> Wiretuner_Blob_V1_StatResponse {
        try online()
        var response = Wiretuner_Blob_V1_StatResponse()
        response.exists = service.stat(request.sha256)
        return response
    }

    public func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws
        -> Wiretuner_Blob_V1_UploadResponse {
        try online()
        var data = Data()
        for try await chunk in chunks {
            try online()
            data.append(chunk)
        }
        service.store(data)
        var response = Wiretuner_Blob_V1_UploadResponse()
        response.blob.sha256 = header.sha256
        return response
    }

    public func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String) -> AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error> {
        let data = link.isPartitioned ? nil : service.blob(request.sha256)
        return AsyncThrowingStream { continuation in
            guard let data else {
                continuation.finish(throwing: SyncCallError(code: 5, message: "no blob"))
                return
            }
            var chunk = Wiretuner_Blob_V1_DownloadResponse()
            chunk.chunk = data
            continuation.yield(chunk)
            continuation.finish()
        }
    }

    public func createPublish(_ request: Wiretuner_Publish_V1_CreatePublishRequest, token: String) async throws
        -> Wiretuner_Publish_V1_CreatePublishResponse {
        try online()
        var response = Wiretuner_Publish_V1_CreatePublishResponse()
        response.publish = try await service.create(request)
        return response
    }

    public func getPublish(_ request: Wiretuner_Publish_V1_GetPublishRequest, token: String) async throws -> Wiretuner_Publish_V1_GetPublishResponse {
        try online()
        guard let (publish, manifest) = service.publish(request.publishID) else { throw SyncCallError(code: 5, message: "no publish") }
        var response = Wiretuner_Publish_V1_GetPublishResponse()
        response.publish = publish
        response.manifest = manifest
        return response
    }

    public func listPublishes(_ request: Wiretuner_Publish_V1_ListPublishesRequest, token: String) async throws
        -> Wiretuner_Publish_V1_ListPublishesResponse {
        try online()
        var response = Wiretuner_Publish_V1_ListPublishesResponse()
        response.publishes = service.publishes(of: request.documentID)
        return response
    }

    public func setPublishAccess(_ request: Wiretuner_Publish_V1_SetPublishAccessRequest, token: String) async throws
        -> Wiretuner_Publish_V1_SetPublishAccessResponse {
        try online()
        let access = request.access
        let id = request.publishID
        await service.update(id) { list in
            for index in list.indices where list[index].publishID == id { list[index].access = access }
        }
        var response = Wiretuner_Publish_V1_SetPublishAccessResponse()
        response.publish = service.publish(id)?.0 ?? .init()
        return response
    }

    public func deletePublish(_ request: Wiretuner_Publish_V1_DeletePublishRequest, token: String) async throws
        -> Wiretuner_Publish_V1_DeletePublishResponse {
        try online()
        let id = request.publishID
        await service.update(id) { list in list.removeAll { $0.publishID == id } }
        return Wiretuner_Publish_V1_DeletePublishResponse()
    }
}
