import Foundation
import WTCRDT
import WTModel

/// A template's state for a new document (templates.adoc, "Offline behavior": "team templates are
/// cached the first time you use them"; DOC-029): read from the template's local store when this
/// Mac has one, else fetched from the server at head and written into a local store, so the next
/// use -- offline too -- reads it from there.
public enum TemplateDownload {
    /// Whether a local store exists at `url`.
    public static func isCached(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The merged state of the template `documentID`: from its store at `url` when cached, else
    /// through `transport` at the server's head, cached at `url` on the way.
    public static func state(documentID: String, at url: URL, transport: (any SyncTransport)?, token: @Sendable () async throws -> String,
                             options: LocalStore.Options = LocalStore.Options()) async throws -> EngineState {
        if isCached(at: url) { return try await SymbolSources.cachedState(documentID: documentID, at: url, options: options) }
        guard let transport else { throw Failure.notCached }
        let head = try await SymbolSources.cloudHead(documentID: documentID, transport: transport, token: try await token(), schema: options.schema)
        let store = try await LocalStore.open(documentID: documentID, at: url, options: options)
        do {
            try await store.installSnapshot(head.state, serverSeq: head.serverSeq)
            try await store.close()
        } catch {
            try? await store.close()
            throw error
        }
        return head.state
    }

    public enum Failure: Error, Hashable {
        /// Not on this Mac, and there is no connection to fetch it.
        case notCached
    }
}
