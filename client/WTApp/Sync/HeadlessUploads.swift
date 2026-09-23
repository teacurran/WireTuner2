import Foundation
import OSLog
import WTModel
import WTSync

/// One local store uploading without a window (saving.adoc, "Offline behavior", *Background
/// upload*): opened at launch because its outbox or blob queue is not empty, synced through a
/// `SyncClient` whose sink is the store itself, and closed once drained -- or parked when the
/// session needs the user (a review, a sign-in, an error), to be picked up when the document is
/// opened.
@MainActor
final class HeadlessUpload {
    let documentID: String
    let title: String
    let store: LocalStore
    private let connection: SyncConnection
    private(set) var state: SyncState = .opening
    private var feed: Task<Void, Never>?
    private(set) var isStopped = false
    var onFinish: @MainActor (String) -> Void = { _ in }
    var onChange: @MainActor () -> Void = {}

    init(documentID: String, title: String, store: LocalStore, connection: SyncConnection) {
        self.documentID = documentID
        self.title = title
        self.store = store
        self.connection = connection
    }

    /// Starts the client and follows its state until the upload is done.
    func start() async {
        let states = await connection.client.states()
        feed = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.state = state
                self.onChange()
                if Self.isDone(state) {
                    await self.stop()
                    return
                }
            }
        }
        await connection.client.start()
    }

    /// Whether the headless session is over: drained, or parked on something only a window can
    /// settle.
    static func isDone(_ state: SyncState) -> Bool {
        switch state {
        case .saved, .needsReview, .needsSignIn, .error, .readOnly: true
        default: false
        }
    }

    /// Stops the client, closes the transport and the store (idempotent).
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        feed?.cancel()
        await connection.client.stop()
        await connection.close()
        try? await store.close()
        onFinish(documentID)
    }
}

/// Finds the local stores that still have work to upload and starts their headless uploads, before
/// any window opens (IO-007).
@MainActor
enum HeadlessUploads {
    static let logger = Logger(subsystem: "com.villagecompute.wiretuner", category: "sync")

    /// Where every document's store lives: the parent of `LocalStore.defaultURL`'s folders.
    nonisolated static func defaultDirectory() throws -> URL {
        try LocalStore.defaultURL(documentID: "_").deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The document ids with a store under `directory` (`<id>/store.sqlite`).
    nonisolated static func storedDocuments(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: directory.appending(components: $0, "store.sqlite").path) }.sorted()
    }

    /// Whether `store` has anything to upload and no review holding it.
    static func needsUpload(_ store: LocalStore) async -> Bool {
        do {
            guard try await store.reviewHold() == nil else { return false }
            let unsent = try await store.hasUnsentChanges()
            let blobs = try await store.pendingBlobCount()
            return unsent || blobs > 0
        } catch {
            return false
        }
    }

    /// Opens each store under `directory`, starts an upload for those with work, and closes the
    /// rest; returns the uploads started (already added to `sessions`).
    @discardableResult
    static func begin(in directory: URL, connector: any SyncConnecting, sessions: DocumentSessions,
                      title: @MainActor (String) -> String) async -> [HeadlessUpload] {
        var started: [HeadlessUpload] = []
        for id in storedDocuments(in: directory) where sessions.sessions[id] == nil {
            do {
                let store = try await LocalStore.open(documentID: id, at: directory.appending(components: id, "store.sqlite"))
                guard await needsUpload(store) else {
                    try await store.close()
                    continue
                }
                let connection = try connector.connect(store: store, sink: store, presence: nil)
                let upload = HeadlessUpload(documentID: id, title: title(id), store: store, connection: connection)
                sessions.add(upload)
                await upload.start()
                started.append(upload)
            } catch {
                logger.error("headless upload of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return started
    }
}
