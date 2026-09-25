import Foundation
import WTCRDT
import WTModel
import WTSync

/// How a document's model is opened (client.adoc, "Concurrency"): through its `WTSync.LocalStore`
/// in the app, a `WTModel.MemoryBackend` in tests and previews.
@MainActor
enum DocumentOpener {
    /// A document id's model, opened from its local store at the default location with the
    /// *Undo levels* preference.
    static func localStore(
        undoLevels: @escaping @MainActor () -> Int, location: @escaping @Sendable (String) throws -> URL = defaultLocation
    ) -> @MainActor (String) async throws -> WTModel.Document {
        { id in
            let store = try await LocalStore.open(documentID: id, at: location(id))
            return await WTModel.Document(backend: store, undoLevels: undoLevels())
        }
    }

    /// Where a document's store lives: `LocalStore.defaultURL(documentID:)`.
    nonisolated static let defaultLocation: @Sendable (String) throws -> URL = { try LocalStore.defaultURL(documentID: $0) }

    /// The opener a launch uses: local stores, except in test launches, which keep memory
    /// documents so nothing persists between runs.
    static func opener(
        for launch: LaunchEnvironment, preferences: PreferenceStore, location: @escaping @Sendable (String) throws -> URL = defaultLocation
    ) -> @MainActor (String) async throws -> WTModel.Document {
        launch.isTesting ? memory : localStore(undoLevels: { preferences[PreferenceCatalog.Sync.undoLevels] }, location: location)
    }

    /// A memory document (nothing persists) writing as a fresh random replica: a new document,
    /// so it starts with the template (the default swatches, `DocumentTemplate`) and its first
    /// page (`ReplacePageRects.newDocument`).
    static func memoryDocument(undoLevels: Int = WTModel.Document.defaultUndoLevels) -> WTModel.Document {
        var core = DocumentTemplate.core(replica: UInt64.random(in: 1...UInt64.max))
        _ = try? core.perform(ReplacePageRects.newDocument, recording: DocumentCore.Recording(limit: 1, now: Date()))
        return WTModel.Document(memory: core, undoLevels: undoLevels)
    }

    /// Writes a new document's template as its first change (creating-opening.adoc; DOC-019's
    /// `CreateDocument`, "Created": one Letter page centred on the pasteboard, then the defaults of
    /// swatches.adoc and the rest of `DocumentTemplate`): a local store opened for a document
    /// created on this Mac.  Not an undo step; nothing is written on a document that already has
    /// content.
    static func applyTemplate(to document: WTModel.Document) async {
        _ = try? await document.perform(CreateDocument(.builtIn))
    }

    /// The opener that makes memory documents.
    static let memory: @MainActor (String) async throws -> WTModel.Document = { _ in memoryDocument() }

    /// Closes `backend` if it is a local store (writes the snapshot, releases the file).
    static func close(_ backend: any DocumentBackend) async {
        guard let store = backend as? LocalStore else { return }
        do {
            try await store.close()
        } catch {
            DocumentHandle.logger.error("closing the local store failed: \(String(describing: error), privacy: .public)")
        }
    }
}
