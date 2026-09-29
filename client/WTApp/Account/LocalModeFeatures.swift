import AppKit
import WTCRDT
import WTModel
import WTSync

/// A document's content copied into another document on this Mac (Local mode's Duplicate in the
/// Library, D-079): the source's state re-issued as fresh changes, as menu:File[Duplicate] does
/// (`DocumentDuplicate`), in one undo group.
@MainActor
enum LocalDocumentCopy {
    /// Writes `state` into `copy`, then waits until it is stored.
    static func fill(_ copy: WTModel.Document, from state: EngineState) async throws {
        let plan = try DocumentDuplicate.plan(state)
        copy.beginGroup()
        while !plan.isFinished {
            guard try await copy.perform(DuplicateChunk(plan)) != nil else { break }
        }
        copy.endGroup()
        await copy.settle()
    }
}

extension AppDelegate {
    /// Local mode (D-079) over the app: the commands' gate, the sessions and the library follow
    /// it, the popover's *Use Without an Account* and the account's sign-in and sign-out change it.
    func installLocalMode() {
        let localMode = localMode
        let account = account
        let library = library
        let sessions = sessions
        localMode.isSignedIn = { account.isSignedIn }
        commands.gate = { localMode.gate($0) }
        library.isLocal = { localMode.isActive }
        library.copyContent = { [weak self] source, copy in await self?.copyDocumentContent(from: source, to: copy) ?? false }
        library.removeFromThisMac = { [weak self] id in await self?.removeFromThisMac(id) }
        sessions.onUseWithoutAccount = { localMode.useWithoutAccount() }
        versions.isLocal = { localMode.isActive }
        dataMerge.isLocal = { localMode.isActive }
        account.signedInHandlers.append {
            localMode.accountDidChange()
            sessions.signedIn()
        }
        account.signedOutHandlers.append { localMode.accountDidChange() }
        localMode.observe { [weak self] active in self?.localModeChange = self?.localModeDidChange(active) }
    }

    /// Local mode began or ended.  Leaving it (a sign-in), the documents made meanwhile are created
    /// in the personal space first (the library's pending uploads), then every open document's
    /// session connects and the closed stores with changes upload headlessly, as at launch.
    @discardableResult
    func localModeDidChange(_ active: Bool) -> Task<Void, Never> {
        let sessions = sessions
        guard !active else { return sessions.localModeDidChange() }
        let library = library
        let directory = try? storesDirectory()
        return Task {
            await library.refresh()
            await sessions.localModeDidChange().value
            if let connector = sessions.connector, let directory {
                await HeadlessUploads.begin(in: directory, connector: connector, sessions: sessions) { id in
                    library.cache.documents[id]?.name ?? LibraryModel.untitled
                }
            }
        }
    }

    /// Fills the new document `copy` with `source`'s content: an open window's document as it is
    /// on screen, else its store on this Mac.  The copy is written through its own store and
    /// closed; opening it later reads it.
    func copyDocumentContent(from source: String, to copy: String) async -> Bool {
        // The windows' opener: it lets go of whatever holds a store first.
        let opener = documents.environment.openModel
        do {
            let state: EngineState
            if let handle = documents.document(id: source), await handle.openedModel() != nil {
                await handle.settle()
                state = handle.state
            } else {
                let model = try await opener(source)
                state = model.state
                await DocumentOpener.close(model.backend)
            }
            let target = try await opener(copy)
            try await LocalDocumentCopy.fill(target, from: state)
            await DocumentOpener.close(target.backend)
            return true
        } catch {
            DocumentHandle.logger.error("copying \(source, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Local mode's *Delete Permanently*: the document's windows close, whatever holds its store
    /// lets go, the store is deleted and Spotlight forgets it.
    func removeFromThisMac(_ id: String) async {
        documents.close(id)
        await sessions.released(id)
        if let url = localCopyRemoval.storeURL(id), LocalCopies.exists(at: url) {
            do {
                try await LocalStore.open(documentID: id, at: url).delete()
            } catch {
                DocumentHandle.logger.error("deleting \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        await spotlight.remove(id)
    }
}
