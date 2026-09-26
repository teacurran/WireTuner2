import Foundation
import WTCRDT
import WTModel
import WTProto

/// Where *Import…* in the Library panel reads symbols from (library.adoc, "Offline behavior" and
/// "Client": `WTSync` reads other documents' stores or snapshots for import; LIB-013): a document
/// cached on this Mac is read from its local store, offline too; any other cloud document from the
/// server at head (its newest snapshot, then the changes after it).  A symbol library file is read
/// by `SymbolPackage(fileData:)`; exporting to one fills the package's asset bytes from the blob
/// cache here.
public enum SymbolSources {
    /// Why a document's symbols could not be read.
    public enum Failure: Error, Hashable {
        /// The server's changes skipped a seq.
        case gap(expected: UInt64, got: UInt64)
    }

    /// The merged state of the document cached in the local store at `url`.
    public static func cachedState(documentID: String, at url: URL, options: LocalStore.Options = LocalStore.Options()) async throws -> EngineState {
        let store = try await LocalStore.open(documentID: documentID, at: url, options: options)
        let state = await store.read { $0 }
        try await store.close()
        return state
    }

    /// The state of `documentID` at the server's head: the newest snapshot, then every change after
    /// it (all of them when the document has no snapshot).
    public static func cloudState(documentID: String, transport: any SyncTransport, token: String, schema: Schema = .generated) async throws
        -> EngineState {
        var state = EngineState(schema: schema)
        var applied: UInt64 = 0
        var snapshot = Wiretuner_Sync_V1_FetchSnapshotRequest()
        snapshot.documentID = documentID
        do {
            var frames: [Wiretuner_Doc_V1_SnapshotFrame] = []
            for try await response in transport.fetchSnapshot(snapshot, token: token) {
                frames.append(response.frame)
            }
            let decoded = try SnapshotDownload.state(frames, schema: schema)
            state = decoded.state
            applied = decoded.serverSeq
        } catch let error as SyncCallError where error.reason == .historyUnavailable {
            // No snapshot yet: the log from the start.
        }
        var request = Wiretuner_Sync_V1_FetchChangesRequest()
        request.documentID = documentID
        request.afterServerSeq = applied
        for try await response in transport.fetchChanges(request, token: token) {
            for change in response.changes where change.serverSeq > applied {
                guard change.serverSeq == applied + 1 else { throw Failure.gap(expected: applied + 1, got: change.serverSeq) }
                state.apply(change.change, serverSeq: change.serverSeq)
                applied = change.serverSeq
            }
        }
        return state
    }

    /// The package of `symbols` (every live symbol when nil) in `state`; with `cache`, the bytes of
    /// the assets it needs that are cached here, as a symbol library file carries them.
    public static func package(of state: EngineState, symbols: [OpID]? = nil, cache: BlobCache? = nil) -> SymbolPackage {
        var package = SymbolPackage(symbols: symbols ?? Symbols.symbols(in: state), from: state)
        if let cache {
            for hash in package.assetHashes {
                if let data = try? Data(contentsOf: cache.url(for: hash)) { package.blobs[hash] = data }
            }
        }
        return package
    }

    /// Puts a symbol library file's asset bytes into `cache`, so the imported assets are available
    /// here and their uploads can be queued; returns the hashes stored.
    @discardableResult
    public static func storeBlobs(of package: SymbolPackage, in cache: BlobCache) throws -> [String] {
        try package.blobs.keys.sorted().compactMap { hash in
            let stored = try cache.insert(package.blobs[hash]!)
            return stored == hash ? stored : nil
        }
    }
}
