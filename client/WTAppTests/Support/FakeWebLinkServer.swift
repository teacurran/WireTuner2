import CryptoKit
import Foundation
import WTProto
import WTSync
@testable import WireTuner

/// Blob and Publish services in memory, for the web-link sheets (the WTSync tests' fake, trimmed).
final class FakeWebLinkServer: BlobTransport, PublishTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var blobs: [Data: Data] = [:]
    private(set) var publishes: [Wiretuner_Publish_V1_Publish] = []
    private(set) var manifests: [String: Wiretuner_Publish_V1_PublishManifest] = [:]
    var offline = false

    private func online() throws {
        if lock.withLock({ offline }) { throw SyncCallError(code: 14, message: "offline") }
    }

    func stat(_ request: Wiretuner_Blob_V1_StatRequest, token: String) async throws -> Wiretuner_Blob_V1_StatResponse {
        try online()
        return lock.withLock { .with { $0.exists = blobs[request.sha256] != nil } }
    }

    func upload(_ header: Wiretuner_Blob_V1_UploadHeader, chunks: AsyncThrowingStream<Data, any Error>, token: String) async throws
        -> Wiretuner_Blob_V1_UploadResponse {
        try online()
        var data = Data()
        for try await chunk in chunks { data.append(chunk) }
        lock.withLock { blobs[Data(SHA256.hash(data: data))] = data }
        return .with { $0.blob.sha256 = header.sha256 }
    }

    func download(_ request: Wiretuner_Blob_V1_DownloadRequest, token: String) -> AsyncThrowingStream<Wiretuner_Blob_V1_DownloadResponse, any Error> {
        let data = lock.withLock { blobs[request.sha256] ?? Data() }
        return AsyncThrowingStream { continuation in
            continuation.yield(.with { $0.chunk = data })
            continuation.finish()
        }
    }

    func createPublish(_ request: Wiretuner_Publish_V1_CreatePublishRequest, token: String) async throws -> Wiretuner_Publish_V1_CreatePublishResponse {
        try online()
        return lock.withLock {
            for index in publishes.indices { publishes[index].current = false }
            let publish = Wiretuner_Publish_V1_Publish.with {
                $0.publishID = request.publishID
                $0.documentID = request.documentID
                $0.serverSeq = request.serverSeq
                $0.settingName = request.settingName
                $0.access = request.access == .unspecified ? .members : request.access
                $0.url = "https://pub.example/d/\(request.documentID)/"
                $0.current = true
                $0.fileCount = UInt32(request.manifest.files.count)
            }
            publishes.insert(publish, at: 0)
            manifests[request.publishID] = request.manifest
            return .with { $0.publish = publish }
        }
    }

    func getPublish(_ request: Wiretuner_Publish_V1_GetPublishRequest, token: String) async throws -> Wiretuner_Publish_V1_GetPublishResponse {
        try online()
        return lock.withLock {
            .with {
                $0.publish = publishes.first { $0.publishID == request.publishID } ?? .init()
                $0.manifest = manifests[request.publishID] ?? .init()
            }
        }
    }

    func listPublishes(_ request: Wiretuner_Publish_V1_ListPublishesRequest, token: String) async throws -> Wiretuner_Publish_V1_ListPublishesResponse {
        try online()
        return lock.withLock { .with { $0.publishes = publishes } }
    }

    func setPublishAccess(_ request: Wiretuner_Publish_V1_SetPublishAccessRequest, token: String) async throws
        -> Wiretuner_Publish_V1_SetPublishAccessResponse {
        try online()
        return lock.withLock {
            guard let index = publishes.firstIndex(where: { $0.publishID == request.publishID }) else { return .init() }
            publishes[index].access = request.access
            return .with { $0.publish = publishes[index] }
        }
    }

    func deletePublish(_ request: Wiretuner_Publish_V1_DeletePublishRequest, token: String) async throws -> Wiretuner_Publish_V1_DeletePublishResponse {
        try online()
        lock.withLock { publishes.removeAll { $0.publishID == request.publishID } }
        return .init()
    }
}

/// Web-link services over `FakeWebLinkServer`.
@MainActor
final class FakeWebLinkServices: WebLinkServices {
    let server = FakeWebLinkServer()
    var isOnline = true
    let events = AsyncStream<SyncEvent>.makeStream()
    private var uploaders: [String: PublishUploader] = [:]
    private var models: [String: PublishedLinks] = [:]

    func uploader(for document: DocumentHandle) -> PublishUploader? {
        if let existing = uploaders[document.id] { return existing }
        let made = PublishUploader(documentID: document.id, blobs: server, publishes: server) { "token" }
        uploaders[document.id] = made
        return made
    }

    func links(for document: DocumentHandle) -> PublishedLinks? {
        if let existing = models[document.id] { return existing }
        let made = PublishedLinks(documentID: document.id, transport: server) { "token" }
        models[document.id] = made
        return made
    }

    func blobs(for document: DocumentHandle) -> (any BlobTransport)? { server }
    func events(for document: DocumentHandle) -> AsyncStream<SyncEvent>? { events.stream }
    func serverSeq(of document: DocumentHandle) async -> UInt64 { 7 }
}

/// A preferences service in memory: the stored map, newest `updated_at_ms` per key.
final class FakePreferencesServer: PreferencesTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stored: [String: Wiretuner_Account_V1_PreferenceValue] = [:]
    private(set) var sets = 0
    var failing = false

    func put(_ id: String, _ value: Wiretuner_Account_V1_PreferenceValue) {
        lock.withLock { stored[id] = value }
    }

    func getPreferences(_ request: Wiretuner_Account_V1_GetPreferencesRequest, token: String) async throws -> Wiretuner_Account_V1_GetPreferencesResponse {
        if lock.withLock({ failing }) { throw SyncCallError(code: 14, message: "offline") }
        return lock.withLock { .with { $0.preferences.values = stored } }
    }

    func setPreferences(_ request: Wiretuner_Account_V1_SetPreferencesRequest, token: String) async throws -> Wiretuner_Account_V1_SetPreferencesResponse {
        if lock.withLock({ failing }) { throw SyncCallError(code: 14, message: "offline") }
        return lock.withLock {
            sets += 1
            for (id, value) in request.changes.values where (stored[id]?.updatedAtMs ?? .min) <= value.updatedAtMs {
                stored[id] = value
            }
            return .with { $0.preferences.values = stored }
        }
    }
}
