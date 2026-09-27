import Foundation
import WTSync

/// menu:File[Save Version…] for one document (saving.adoc, "Saving a version"; IO-003): the
/// queue itself -- named at once with everything acknowledged, else a `NameVersion` waiting in the
/// store's `pending_calls` until its last change is acknowledged -- is `WTSync.VersionQueue`
/// (COLLAB-024), so the simulator drives the same code.
typealias VersionSaving = VersionQueue

extension VersionQueue {
    /// The versions of the document `document`'s local store keeps.
    static func localStore(of document: DocumentHandle) -> (storage: Storage, head: @MainActor () async -> VersionHead?) {
        let store: @MainActor () async -> LocalStore? = { [weak document] in await document?.openedModel()?.backend as? LocalStore }
        return (
            Storage.localStore(store),
            { guard let store = await store() else { return nil }; return try? await VersionHead.of(store) }
        )
    }
}
