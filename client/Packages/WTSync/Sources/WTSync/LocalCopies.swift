import Foundation

/// *Remove Local Copy* (saving.adoc, "Keeping a copy on this Mac"; IO-035): a document's local store
/// is deleted only once everything in it has reached the cloud -- no unacknowledged change (of this
/// replica or a retired one), no salvaged change waiting to be re-issued, no image waiting to upload
/// and no queued call.  The caller closes the store first (the document's windows and sessions).
public enum LocalCopies {
    /// What stands in the way of removing a copy.
    public struct Waiting: Equatable, Sendable {
        public var changes = 0
        public var salvaged = 0
        public var blobs = 0
        public var calls = 0

        public init(changes: Int = 0, salvaged: Int = 0, blobs: Int = 0, calls: Int = 0) {
            self.changes = changes
            self.salvaged = salvaged
            self.blobs = blobs
            self.calls = calls
        }

        public var isEmpty: Bool { changes == 0 && salvaged == 0 && blobs == 0 && calls == 0 }

        /// "3 changes and 1 image have not reached the cloud yet."
        public var message: String {
            guard !isEmpty else { return "Everything has reached the cloud." }
            var parts: [String] = []
            let changes = changes + salvaged
            if changes > 0 { parts.append(changes == 1 ? "1 change" : "\(changes) changes") }
            if blobs > 0 { parts.append(blobs == 1 ? "1 image" : "\(blobs) images") }
            if calls > 0 { parts.append(calls == 1 ? "1 pending action" : "\(calls) pending actions") }
            let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
            return list + (changes + blobs + calls == 1 ? " has" : " have") + " not reached the cloud yet."
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The copy was deleted.
        case removed
        /// This Mac holds no copy.
        case notOnThisMac
        /// Something has not reached the cloud; nothing was deleted.
        case waiting(Waiting)
    }

    /// Whether a local store exists at `url`.
    public static func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// What the store at `url` still holds for the cloud; empty when it can go.
    public static func waiting(documentID: String, at url: URL, options: LocalStore.Options = LocalStore.Options()) async throws -> Waiting {
        try await withStore(documentID, at: url, options: options) { store in
            let waiting = try await store.waiting()
            try await store.close()
            return waiting
        }
    }

    /// Deletes the store at `url` (its directory) when nothing waits for the cloud.
    public static func remove(documentID: String, at url: URL, options: LocalStore.Options = LocalStore.Options()) async throws -> Outcome {
        guard exists(at: url) else { return .notOnThisMac }
        return try await withStore(documentID, at: url, options: options) { store in
            let waiting = try await store.waiting()
            guard waiting.isEmpty else {
                try await store.close()
                return .waiting(waiting)
            }
            try await store.delete()
            return .removed
        }
    }

    /// Runs `body` over the store at `url`, which `body` closes (or deletes); a failure closes it.
    private static func withStore<Value: Sendable>(_ documentID: String, at url: URL, options: LocalStore.Options,
                                                   _ body: (LocalStore) async throws -> Value) async throws -> Value {
        let store = try await LocalStore.open(documentID: documentID, at: url, options: options)
        do {
            return try await body(store)
        } catch {
            try? await store.close()
            throw error
        }
    }
}

extension LocalStore {
    /// What the store holds that has not reached the cloud.
    func waiting() throws -> LocalCopies.Waiting {
        LocalCopies.Waiting(changes: try unsentChangeCount(), salvaged: try pendingSalvageCount(), blobs: try pendingBlobCount(), calls: try pendingCallCount())
    }
}
